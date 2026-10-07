defmodule Bildad.Job.JobEngine do
  @moduledoc """
  This module contains the logic for enqueuing, running, killing and expiring jobs in the Bildad job scheduling framework.
  """

  import Ecto.Query

  alias Bildad.Job.Jobs

  alias Bildad.Job.JobQueueEntry
  alias Bildad.Job.JobRun
  alias Bildad.Job.JobTemplate
  alias Bildad.Job.JobConfig
  alias Bildad.RunDetails.Writer
  alias Bildad.RunLog
  alias Bildad.RunState

  alias ExJsonSchema.Schema
  alias ExJsonSchema.Validator

  require Logger

  # run the engine

  @doc """
  This function is called by the job scheduler to run the job engine.

  This should be called by a single cron job in your environment so that the engine is run on one node at a time.

  THIS FUNCTION MUST NOT BE RUN INSIDE A TRANSACTION. 
  The jobs should run in isolation from each other.
  The queue record should be marked as 'RUNNING' as quickly as possible.
  """
  def run_job_engine(job_config) do
    expire_resp_data = do_expire_jobs(job_config)
    start_resp_data = do_start_jobs(job_config)
    prune_run_logs(job_config)

    %{
      start: start_resp_data,
      expire: expire_resp_data
    }
  end

  @doc """
  Utility function go get the number of successful jobs and the number of jobs that failed.
  """
  def get_counts(jobs) do
    ok_count =
      Enum.count(jobs, fn
        {:ok, _} -> true
        _ -> false
      end)

    error_count =
      Enum.count(jobs, fn
        {:error, _} -> true
        _ -> false
      end)

    %{ok_count: ok_count, error_count: error_count}
  end

  # Removes saved run logs past their retention, one batch per engine run, whenever run
  # details are on (also after the run log itself has been turned off). Never fails the
  # engine run.
  defp prune_run_logs(job_config) do
    if Bildad.Config.run_details?() do
      try do
        RunLog.prune(job_config)
      rescue
        e -> log_prune_error(e)
      end
    end
  end

  # At most once a minute per node, so a missing table does not log on every engine run.
  defp log_prune_error(e) do
    now = System.monotonic_time(:millisecond)
    last = :persistent_term.get({__MODULE__, :prune_error_logged_at}, nil)

    if last == nil or now - last >= 60_000 do
      :persistent_term.put({__MODULE__, :prune_error_logged_at}, now)

      Logger.error(
        "Could not prune saved run logs (is the job_run_details migration applied?): " <>
          String.slice(Exception.message(e), 0, 500)
      )
    end
  end

  # Internal function that gets jobs in the queue that are available to run (not already running) and runs them
  defp do_start_jobs(job_config) do
    job_config
    |> Jobs.list_jobs_to_run_in_the_queue(0, job_config.job_engine_batch_size)
    |> Enum.map(fn job_in_the_queue ->
      try do
        run_a_job(job_config, job_in_the_queue)
      rescue
        e ->
          Logger.warning(
            "Error running job in the queue: #{inspect(job_in_the_queue.id)} with error: #{inspect(e)}"
          )

          Logger.error(Exception.format_stacktrace())

          {:error, e}
      end
    end)
  end

  # Internal function for expiring jobs that can't be killed because they are no longer running on any node.
  defp do_expire_jobs(job_config) do
    job_config
    |> Jobs.list_expired_jobs()
    |> Enum.map(fn job_run ->
      try do
        expire_a_job(job_config, job_run)
      rescue
        e ->
          Logger.warning(
            "Error expiring job run: #{inspect(job_run.id)} with error: #{inspect(e)}"
          )

          {:error, e}
      end
    end)
  end

  # enqueue a job

  @doc """
  Adds a job to the queue. The order it will be run in will be based on priority and resource availability.

  Each message contains a `job_context` which is a map of data that will be passed to the job module when it is run.
  This job context must conform to the schema defined in the job template.
  """
  def enqueue_job(
        %JobConfig{} = job_config,
        %JobTemplate{} = job_template,
        job_context,
        opts \\ %{}
      ) do
    job_run_identifier = Map.get(opts, :job_run_identifier, Ecto.UUID.generate())

    %JobQueueEntry{}
    |> JobQueueEntry.changeset(%{
      job_template_id: job_template.id,
      job_run_identifier: job_run_identifier,
      status: Map.get(opts, :status),
      priority: Map.get(opts, :priority),
      timeout_in_minutes:
        Map.get(opts, :timeout_in_minutes, job_template.default_timeout_in_minutes),
      max_retries: Map.get(opts, :max_retries, job_template.default_max_retries),
      job_context: job_context
    })
    |> job_config.repo.insert()
  end

  @doc """
  Enqueues a job and triggers the job engine to run immediately.

  If there are other jobs ahead of this one in the queue that are higher priority, they will be run first.

  This is the preferred over `enqueue_and_run_job` as it respects the priority of other jobs in the queue.

  TODO: This should make the same API call that the cron job makes and it should check to see if the job engine is already running before starting it.
  """
  def enqueue_job_and_trigger_engine(
        %JobConfig{} = job_config,
        %JobTemplate{} = job_template,
        job_context,
        opts \\ %{}
      ) do
    enqueue_job(job_config, job_template, job_context, opts)
    |> case do
      {:ok, job_queue_entry} ->
        {:ok, %{job_queue_entry: job_queue_entry, job_engine_results: run_job_engine(job_config)}}

      {:error, e} ->
        {:error, e}
    end
  end

  @doc """
  Enqueues a job and runs it immediately. 

  This should be used sparingly as it bypasses the priority of other jobs in the queue.
  """
  def enqueue_and_run_job(
        %JobConfig{} = job_config,
        %JobTemplate{} = job_template,
        job_context,
        opts \\ %{}
      ) do
    enqueue_job(job_config, job_template, job_context, opts)
    |> case do
      {:ok, job_queue_entry} ->
        run_a_job(job_config, job_queue_entry)

      {:error, e} ->
        {:error, e}
    end
  end

  # run a job

  @doc """
  This function is called by the job scheduler to run a job.

  The queue entry is first claimed: it is moved from available to running only if it is
  still available, so when two callers try to run the same entry only one of them runs it.
  The other gets `{:error, :job_not_available}` and nothing is launched.

  If the job context fails the template's schema, the job is not launched. One failed job
  run is recorded and the entry is removed from the queue, since the same context would fail
  on every retry. Returns `{:error, {:invalid_job_context, job_run}}`.
  """
  def run_a_job(%JobConfig{} = job_config, %JobQueueEntry{} = job_queue_entry) do
    job_config.repo.transaction(fn ->
      case claim_job_queue_entry(job_config, job_queue_entry) do
        nil -> job_config.repo.rollback(:job_not_available)
        claimed_entry -> start_job_run(job_config, claimed_entry)
      end
    end)
    |> case do
      {:ok, {:launch, job_run}} ->
        launch_job_process(job_config, job_run)

      {:ok, {:invalid_job_context, job_run}} ->
        {:error, {:invalid_job_context, job_run}}

      {:error, e} ->
        {:error, e}
    end
  end

  # Moves the entry from available to running, only if it is still available. The update
  # locks the row and checks the status against the latest committed version, so of two
  # concurrent callers only one changes a row. Returns the freshly read entry, or nil when
  # this caller did not claim it.
  defp claim_job_queue_entry(%JobConfig{} = job_config, %JobQueueEntry{id: id}) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    from(e in JobQueueEntry,
      where: e.id == ^id and e.status == ^job_config.queue_status_available
    )
    |> job_config.repo.update_all(set: [status: job_config.queue_status_running, updated_at: now])
    |> case do
      {1, _} -> job_config.repo.get!(JobQueueEntry, id)
      {_, _} -> nil
    end
  end

  defp start_job_run(%JobConfig{} = job_config, %JobQueueEntry{} = job_queue_entry) do
    job_template = job_config.repo.get(JobTemplate, job_queue_entry.job_template_id)
    now = DateTime.utc_now()

    job_run_attrs = %{
      job_queue_entry_id: job_queue_entry.id,
      job_run_identifier: job_queue_entry.job_run_identifier,
      job_template_id: job_template.id,
      retry: get_retry_count(job_config, job_queue_entry),
      job_process_name: Ecto.UUID.generate(),
      started_at: now,
      timeout_at: NaiveDateTime.add(now, job_queue_entry.timeout_in_minutes, :minute),
      expires_at: NaiveDateTime.add(now, job_config.job_run_expiry_in_days, :day),
      job_context: job_queue_entry.job_context
    }

    case validate_job_context(job_template.job_context_schema, job_queue_entry.job_context) do
      :ok ->
        job_run =
          %JobRun{}
          |> JobRun.changeset(Map.put(job_run_attrs, :status, job_config.job_run_status_running))
          |> job_config.repo.insert!()

        job_queue_entry
        |> JobQueueEntry.changeset(%{current_job_run_id: job_run.id})
        |> job_config.repo.update!()

        {:launch, job_run}

      {:error, failures} ->
        failures_str =
          """
          Invalid job context. Failed schema validation:

          #{for {text, location} <- failures do
            "#{text} (at: #{location})"
          end}
          """

        Logger.warning(
          "Not running job #{job_queue_entry.job_run_identifier} and removing it from the queue: " <>
            String.trim(failures_str)
        )

        job_run =
          %JobRun{}
          |> JobRun.changeset(
            Map.merge(job_run_attrs, %{
              ended_at: now,
              status: job_config.job_run_status_done,
              result: job_config.job_run_result_failed,
              reason: truncate_reason(failures_str)
            })
          )
          |> job_config.repo.insert!()

        job_config.repo.delete!(job_queue_entry)

        {:invalid_job_context, job_run}
    end
  end

  # The longest failure reason `job_runs.reason` holds. The column is a `varchar(255)`
  # (`:string` in the migration), which counts characters on both MySQL and Postgres.
  @reason_max_length 255

  # Cuts a failure reason to fit `job_runs.reason`. Every reason Bildad writes goes through
  # here, so no write can fail on the reason's length. The column limit counts code points,
  # not graphemes (one grapheme can be several code points), so code points are counted.
  defp truncate_reason(reason) when is_binary(reason) do
    reason
    |> Bildad.Text.cut_bytes(@reason_max_length * 4)
    |> Bildad.Text.sanitize()
    |> Bildad.Text.cut_chars(@reason_max_length)
  end

  # remove a job from the queue
  @doc """
  Removes a job from the queue. This is typically called when a job is completed or when a user wishes to no longer run the job.
  """
  def remove_job_from_queue(%JobConfig{} = job_config, %JobQueueEntry{} = job_queue_entry) do
    job_config.repo.transaction(fn ->
      job_queue_entry
      |> job_config.repo.delete!()
    end)
  end

  @doc """
  This function is called by the job scheduler to stop a job that is currently running.
  This ONLY updates the record in the database, it does NOT stop the elixir process.
  To stop the Elixir process if it is still running then `kill_a_job` should be called.
  """
  def stop_job_in_queue(%JobConfig{} = job_config, %JobQueueEntry{} = job_queue_entry) do
    job_config.repo.transaction(fn ->
      running_status = job_config.job_run_status_running

      job_queue_entry
      |> job_config.repo.preload(:current_job_run)
      |> case do
        # Bind the PRELOADED entry — using the original `job_queue_entry` here
        # reads an unloaded :current_job_run and crashes JobRun.changeset with
        # `Ecto.Association.NotLoaded.__changeset__/0 is undefined`.
        %JobQueueEntry{current_job_run: %JobRun{status: ^running_status}} = entry ->
          entry
          |> JobQueueEntry.changeset(%{
            status: job_config.queue_status_available
          })
          |> job_config.repo.update!()

          entry.current_job_run
          |> JobRun.changeset(%{
            status: job_config.job_run_status_done,
            result: job_config.job_run_result_failed,
            reason: "Stopped",
            ended_at: DateTime.utc_now()
          })
          |> job_config.repo.update!()

        _ ->
          # the job is not running
          nil
      end
    end)
    |> tap(fn
      {:ok, %JobRun{} = job_run} -> Bildad.Telemetry.run_event(:stopped, job_run)
      _ -> :ok
    end)
  end

  # kill a job
  @doc """
  If the Elixir process is running on this node then it kills the process and updates the database record.

  If not, nothing happens on this node. The other nodes should being runnig this function as well and the
  process will be stopped on one of them.
  If the process is not running on any node the job will eventually expire when the expiration time is reached.
  The `expire_a_job` function should be called to handle that case. (This is done by the job engine.)
  """
  def kill_a_job(%JobConfig{} = job_config, %JobRun{} = job_run) do
    case find_elixir_process(job_run) do
      nil ->
        # the process isn't running on this cluster node
        # either it's running on another node or it's already finished (in which case we will have to wait for the job expiration)
        nil

      process_pid ->
        # Its kept log lines (with the run log on) are read before the kill and saved after.
        run_log = RunLog.read_buffer(process_pid)
        try_to_kill_process(process_pid)

        job_config.repo.transaction(fn ->
          job_run =
            job_run
            |> JobRun.changeset(%{
              status: job_config.job_run_status_done,
              result: job_config.job_run_result_failed,
              reason: "Timeout",
              ended_at: DateTime.utc_now()
            })
            |> job_config.repo.update!()
            |> job_config.repo.preload(:job_queue_entry)

          if job_run.job_queue_entry != nil do
            if job_run.retry + 1 > job_run.job_queue_entry.max_retries do
              # out of retries, delete the job from the queue
              Logger.warning(
                "Unable to process job after max retries: #{job_run.job_run_identifier}, removing it from the queue."
              )

              job_config.repo.delete!(job_run.job_queue_entry)
            else
              job_run.job_queue_entry
              |> JobQueueEntry.changeset(%{
                status: job_config.queue_status_available
              })
              |> job_config.repo.update!()
            end
          else
            # the job queue entry has already been deleted
          end

          job_run
        end)
        |> tap(fn
          {:ok, %JobRun{} = job_run} ->
            if run_log, do: RunLog.save(job_config.repo, job_run.id, run_log)
            Bildad.Telemetry.run_event(:killed, job_run)

          _ ->
            :ok
        end)
    end
  end

  # expire a job
  @doc """
  Used when a job is not running on any node and the expiration time has been reached.
  """
  def expire_a_job(%JobConfig{} = job_config, %JobRun{} = job_run) do
    job_config.repo.transaction(fn ->
      job_run =
        job_run
        |> JobRun.changeset(%{
          status: job_config.job_run_status_done,
          result: job_config.job_run_result_failed,
          reason: "Expired",
          ended_at: DateTime.utc_now()
        })
        |> job_config.repo.update!()
        |> job_config.repo.preload(:job_queue_entry)

      if job_run.job_queue_entry != nil do
        if job_run.retry + 1 > job_run.job_queue_entry.max_retries do
          Logger.warning(
            "Unable to process job after max retries: #{job_run.job_run_identifier}, removing it from the queue."
          )

          job_config.repo.delete!(job_run.job_queue_entry)
        else
          job_run.job_queue_entry
          |> JobQueueEntry.changeset(%{
            status: job_config.queue_status_available
          })
          |> job_config.repo.update!()
        end
      else
        # the job queue entry has already been deleted
      end

      job_run
    end)
    |> tap(fn
      {:ok, %JobRun{} = job_run} -> Bildad.Telemetry.run_event(:expired, job_run)
      _ -> :ok
    end)
  end

  # fail a job

  @doc """
  Jobs that come to completion and are not successful are marked as failed.
  """
  def fail_a_job(%JobConfig{} = job_config, %JobRun{} = job_run, error_message) do
    job_config.repo.transaction(fn ->
      error_message_str = truncate_reason(inspect(error_message))

      job_run =
        job_run
        |> JobRun.changeset(%{
          status: job_config.job_run_status_done,
          result: job_config.job_run_result_failed,
          reason: error_message_str,
          ended_at: DateTime.utc_now()
        })
        |> job_config.repo.update!()
        |> job_config.repo.preload(:job_queue_entry)

      if job_run.job_queue_entry != nil do
        if job_run.retry + 1 > job_run.job_queue_entry.max_retries do
          Logger.warning(
            "Unable to process job after max retries: #{job_run.job_run_identifier}, removing it from the queue."
          )

          job_config.repo.delete!(job_run.job_queue_entry)
        else
          job_run.job_queue_entry
          |> JobQueueEntry.changeset(%{
            status: job_config.queue_status_available
          })
          |> job_config.repo.update!()
        end
      else
        # the job queue entry has already been deleted
      end

      job_run
    end)
  end

  # finish a job
  @doc """
  Used to mark a job as completed successfully.
  """
  def complete_a_job(%JobConfig{} = job_config, %JobRun{} = job_run) do
    job_config.repo.transaction(fn ->
      job_run =
        job_run
        |> JobRun.changeset(%{
          status: job_config.job_run_status_done,
          result: job_config.job_run_result_succeeded,
          ended_at: DateTime.utc_now()
        })
        |> job_config.repo.update!()
        |> job_config.repo.preload(:job_queue_entry)

      if job_run.job_queue_entry != nil do
        Logger.info(
          "Job completed successfully: #{job_run.job_run_identifier}. Removing it from the queue."
        )

        job_config.repo.delete!(job_run.job_queue_entry)
      end

      job_run
    end)
  end

  @doc """
  The queue entry points to the current run which has its retry count.
  This function increments that number by one OR it returns 0 if there is not a currently running job (which is
  the initial state of an enqueued job).
  """
  def get_retry_count(%JobConfig{} = job_config, %JobQueueEntry{} = job_queue_entry) do
    case job_queue_entry.current_job_run_id do
      nil ->
        0

      job_run_id ->
        job_config.repo.get(JobRun, job_run_id).retry + 1
    end
  end

  @doc """
  Each job has a schema that defines the shape of the data that will be passed to the job module when it is run.
  """
  def validate_job_context(job_context_schema, job_context) do
    Schema.resolve(job_context_schema)
    |> case do
      nil ->
        {:error, [{"Invalid job schema definition.", "schema"}]}

      schema ->
        Validator.validate(schema, job_context)
    end
  end

  # How long the launcher waits for a new job process to register itself. Registering is the
  # process's first action and does not block, so this is only reached if the node is badly
  # overloaded.
  @registration_timeout_ms 5_000

  @doc """
  Launches the Elixir process for the job passing it the job context.

  The process registers itself in `Bildad.JobRegistry` under the job run's
  `job_process_name`, before it runs the job, and this function waits for that. So a job
  that finishes at once cannot make the launch fail, and the name is a string key: no atom
  is created per job run. The registry is local to the node, like the process.

  Returns `{:ok, job_run}` once the process is registered.

  If the process ends before it registers, the job has not run: the job run is failed and
  `{:error, {:not_launched, reason}}` is returned. If it has not registered within
  #{@registration_timeout_ms} ms, `{:error, :registration_timeout}` is returned and the
  process is left alone: if it goes on to run the job it records the outcome as usual, and
  otherwise the job run stays RUNNING until the job engine expires it (`expires_at`).

  The registry links to the processes registered in it, so a job process stops if Bildad's
  application (and so the registry) stops.
  """
  def launch_job_process(%JobConfig{} = job_config, %JobRun{} = job_run) do
    Logger.info("time to launch a job process for #{job_run.job_run_identifier}")

    job_run =
      job_run
      |> job_config.repo.preload(
        job_template: [],
        job_queue_entry: [
          current_job_run: []
        ]
      )

    # launch the process
    process_name = job_run.job_process_name
    process_module = job_run.job_template.job_module_name
    process_module_atom = String.to_atom(process_module)
    run_state = RunState.new(job_config, job_run)

    # The process acknowledges its registration through an alias, so an acknowledgement
    # that arrives after this function has given up is dropped instead of being left in the
    # caller's mailbox.
    registered = Process.alias()

    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, _owner} = Registry.register(Bildad.JobRegistry, process_name, run_state)
        send(registered, {registered, :registered})
        run_job_process(job_config, job_run, run_state, process_module_atom)
      end)

    # The acknowledgement is sent before the job starts, so it arrives before the :DOWN of a
    # job that finishes at once. A :DOWN first means the process ended before it registered,
    # so the job did not run.
    result =
      receive do
        {^registered, :registered} ->
          {:ok, job_run}

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          Logger.error(
            "Job process for #{job_run.job_run_identifier} ended before it registered: #{inspect(reason)}"
          )

          fail_a_job(job_config, job_run, {:not_launched, reason})
          {:error, {:not_launched, reason}}
      after
        @registration_timeout_ms ->
          Logger.error(
            "Job process for #{job_run.job_run_identifier} did not register within #{@registration_timeout_ms} ms"
          )

          {:error, :registration_timeout}
      end

    Process.unalias(registered)
    Process.demonitor(monitor, [:flush])

    # An acknowledgement sent just before the alias was removed is already in the mailbox.
    receive do
      {^registered, :registered} -> {:ok, job_run}
    after
      0 -> result
    end
  end

  # The body of a job process, once it is registered.
  defp run_job_process(job_config, job_run, run_state, process_module_atom) do
    RunState.put(run_state)
    Writer.run_started(run_state)

    Logger.info("running job in process #{inspect(self())}")

    # The context's keys only: its values can be personal data.
    Logger.info(
      "running job process #{process_module_atom} for context with keys: " <>
        context_keys(job_run.job_context)
    )

    # After the launch line, so it is never kept.
    RunLog.start_capture(run_state)

    start_time = System.monotonic_time()

    :telemetry.execute(
      [:bildad, :job, :start],
      %{system_time: System.system_time(), monotonic_time: start_time},
      run_state.identity
    )

    # `ending` says how run_job/1 ended: it returned, or it raised, exited or threw.
    {outcome, ending} =
      try do
        apply(process_module_atom, :run_job, [job_run.job_context])
        |> case do
          {:ok, _} ->
            {:succeeded, :returned}

          {:error, e} ->
            Logger.error("Error running job: #{inspect(e)}")

            case Process.info(self(), :current_stacktrace) do
              {:current_stacktrace, stacktrace} ->
                Logger.error(Exception.format_stacktrace(stacktrace))

              _ ->
                Logger.error("(stacktrace unavailable)")
            end

            {{:failed, e}, :returned}
        end
      rescue
        e ->
          Logger.error("Error running job: #{inspect(e)}")
          Logger.error(Exception.format_stacktrace(__STACKTRACE__))
          {{:failed, e}, {:error, e, __STACKTRACE__}}
      catch
        kind, reason ->
          Logger.error("Job ended with #{kind}: #{inspect(reason, limit: 50)}")
          Logger.error(Exception.format_stacktrace(__STACKTRACE__))
          {{:failed, {kind, reason}}, {kind, reason, __STACKTRACE__}}
      end

    record_outcome(job_config, job_run, outcome)
    Writer.run_finished(run_state)
    RunLog.finish_capture(run_state, outcome != :succeeded)
    emit_end(run_state, start_time, outcome, ending)

    # After an exit or a throw the process still ends abnormally, as it did before the
    # run was recorded, so processes the job linked to (a `Task.async`, say) stop with it.
    case ending do
      {:exit, reason, _stacktrace} -> exit(reason)
      {:throw, value, _stacktrace} -> exit({:nocatch, value})
      _ -> :ok
    end
  end

  defp emit_end(run_state, start_time, outcome, ending) do
    stop_time = System.monotonic_time()
    measurements = %{duration: stop_time - start_time, monotonic_time: stop_time}

    case {outcome, ending} do
      {_, {kind, reason, stacktrace}} ->
        :telemetry.execute(
          [:bildad, :job, :exception],
          measurements,
          Map.merge(run_state.identity, %{kind: kind, reason: reason, stacktrace: stacktrace})
        )

      {:succeeded, :returned} ->
        :telemetry.execute(
          [:bildad, :job, :stop],
          measurements,
          Map.merge(run_state.identity, %{result: :succeeded, error: nil})
        )

      {{:failed, error}, :returned} ->
        :telemetry.execute(
          [:bildad, :job, :stop],
          measurements,
          Map.merge(run_state.identity, %{result: :failed, error: error})
        )
    end
  end

  defp context_keys(context) when is_map(context) do
    context |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() |> inspect()
  end

  defp context_keys(_context), do: "(not a map)"

  # Records how the job ended, with one attempt at the database write. If that fails (the
  # database is unavailable, say) it is only logged: the process ends and the run stays
  # RUNNING until it expires, when the job engine fails it and re-queues or removes the
  # entry. Nothing is retried, so a failing system is not made busier.
  defp record_outcome(%JobConfig{} = job_config, %JobRun{} = job_run, outcome) do
    case outcome do
      :succeeded -> complete_a_job(job_config, job_run)
      {:failed, reason} -> fail_a_job(job_config, job_run, reason)
    end
  catch
    kind, reason ->
      Logger.error(
        "Could not record the outcome of job run #{job_run.job_run_identifier} " <>
          "(#{outcome_tag(outcome)}): #{inspect(kind)} #{inspect(reason, limit: 50)}. " <>
          "It stays RUNNING until it expires at #{job_run.expires_at}."
      )
  end

  defp outcome_tag(:succeeded), do: "succeeded"
  defp outcome_tag({:failed, _reason}), do: "failed"

  @doc """
  Locates the Elixir process by the job identifier.
  If the process is not running or is running on another node then nil is returned.
  """
  def find_elixir_process(%JobRun{} = job_run) do
    # A process is removed from the registry shortly after it ends, not at once, so check
    # that it is still alive.
    case Registry.lookup(Bildad.JobRegistry, job_run.job_process_name) do
      [{process_pid, _value}] -> if Process.alive?(process_pid), do: process_pid
      [] -> nil
    end
  end

  @doc """
  Tries to kill the process by sending an exit signal.
  """
  def try_to_kill_process(process_pid) do
    # try to kill the process
    Process.exit(process_pid, :kill)
  end
end
