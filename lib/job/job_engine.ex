defmodule Bildad.Job.JobEngine do
  @moduledoc """
  This module contains the logic for enqueuing, running, killing and expiring jobs in the Bildad job scheduling framework.
  """

  alias Bildad.Job.Jobs

  alias Bildad.Job.JobQueueEntry
  alias Bildad.Job.JobRun
  alias Bildad.Job.JobTemplate
  alias Bildad.Job.JobConfig

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
  """
  def run_a_job(%JobConfig{} = job_config, %JobQueueEntry{} = job_queue_entry) do
    job_config.repo.transaction(fn ->
      job_template = job_config.repo.get(JobTemplate, job_queue_entry.job_template_id)
      job_process_name = Ecto.UUID.generate()
      now = DateTime.utc_now()

      case validate_job_context(job_template.job_context_schema, job_queue_entry.job_context) do
        :ok ->
          job_run =
            %JobRun{}
            |> JobRun.changeset(%{
              job_queue_entry_id: job_queue_entry.id,
              job_run_identifier: job_queue_entry.job_run_identifier,
              job_template_id: job_template.id,
              retry: get_retry_count(job_config, job_queue_entry),
              job_process_name: job_process_name,
              started_at: now,
              timeout_at: NaiveDateTime.add(now, job_queue_entry.timeout_in_minutes, :minute),
              expires_at: NaiveDateTime.add(now, 30, :day),
              status: job_config.job_run_status_running,
              job_context: job_queue_entry.job_context
            })
            |> job_config.repo.insert!()

          job_queue_entry
          |> JobQueueEntry.changeset(%{
            status: job_config.queue_status_running,
            current_job_run_id: job_run.id
          })
          |> job_config.repo.update!()

          job_run

        {:error, failures} ->
          failures_str =
            """
            Invalid job context. Failed schema validation:

            #{for {text, location} <- failures do
              "#{text} (at: #{location})"
            end}
            """

          job_run =
            %JobRun{}
            |> JobRun.changeset(%{
              job_queue_entry_id: job_queue_entry.id,
              job_run_identifier: job_queue_entry.job_run_identifier,
              job_template_id: job_template.id,
              retry: get_retry_count(job_config, job_queue_entry),
              job_process_name: job_process_name,
              started_at: now,
              timeout_at: NaiveDateTime.add(now, job_queue_entry.timeout_in_minutes, :minute),
              expires_at: NaiveDateTime.add(now, 30, :day),
              ends_at: now,
              status: job_config.job_run_status_done,
              result: job_config.job_run_result_failed,
              reason: failures_str,
              job_context: job_queue_entry.job_context
            })
            |> job_config.repo.insert!()

          job_queue_entry
          |> JobQueueEntry.changeset(%{
            status: job_config.queue_status_available,
            current_job_run_id: job_run.id
          })
          |> job_config.repo.update!()

          job_run
      end
    end)
    |> case do
      {:ok, job_run} ->
        launch_job_process(job_config, job_run)

      {:error, e} ->
        {:error, e}
    end
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
        %JobQueueEntry{current_job_run: %JobRun{status: ^running_status}} ->
          job_queue_entry
          |> JobQueueEntry.changeset(%{
            status: job_config.queue_status_available
          })
          |> job_config.repo.update!()

          job_queue_entry.current_job_run
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
  end

  # fail a job

  @doc """
  Jobs that come to completion and are not successful are marked as failed.
  """
  def fail_a_job(%JobConfig{} = job_config, %JobRun{} = job_run, error_message) do
    job_config.repo.transaction(fn ->
      error_message_str = String.slice("#{inspect(error_message)}", 0, 256)

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

  @doc """
  Launches the Elixir process for the job passing it the job context.
  It registers the process with the job identifier so that it can be found later.
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
    name_atom = String.to_atom(process_name)
    process_module = job_run.job_template.job_module_name
    process_module_atom = String.to_atom(process_module)

    pid =
      Process.spawn(
        fn ->
          Logger.info("running job in process #{inspect(self())}")

          try do
            Logger.info(
              "running job process #{process_module_atom} for context: #{inspect(job_run.job_context)}"
            )

            apply(process_module_atom, :run_job, [job_run.job_context])
            |> case do
              {:ok, _} ->
                complete_a_job(job_config, job_run)

              {:error, e} ->
                Logger.error("Error running job: #{inspect(e)}")
                Logger.error(Exception.format_stacktrace())
                fail_a_job(job_config, job_run, e)
            end
          rescue
            e ->
              Logger.error("Error running job: #{inspect(e)}")
              Logger.error(Exception.format_stacktrace())
              fail_a_job(job_config, job_run, e)
          end
        end,
        []
      )

    if Process.register(pid, name_atom) do
      {:ok, job_run}
    else
      {:error, "Failed to register process: #{inspect(pid)}"}
    end
  end

  @doc """
  Locates the Elixir process by the job identifier.
  If the process is not running or is running on another node then nil is returned.
  """
  def find_elixir_process(%JobRun{} = job_run) do
    # find the process by name
    process_name = job_run.job_process_name
    name_atom = String.to_atom(process_name)

    case Process.whereis(name_atom) do
      nil -> nil
      process_pid -> process_pid
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
