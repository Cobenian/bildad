defmodule Bildad.Job.JobEngine do
  @moduledoc """
  This module contains the logic for enqueuing, running, and managing jobs in the Bildad job scheduling framework.
  """

  alias Bildad.Job.JobQueueEntry
  alias Bildad.Job.JobRun
  alias Bildad.Job.JobTemplate
  alias Bildad.Job.JobConfig

  alias ExJsonSchema.Schema
  alias ExJsonSchema.Validator

  require Logger

  # enqueue a job

  def enqueue_job(
        %JobConfig{} = job_config,
        %JobTemplate{} = job_template,
        job_context,
        opts \\ %{}
      ) do
    job_run_identifier = Ecto.UUID.generate()

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

  # run a job

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
  def remove_job_from_queue(%JobConfig{} = job_config, %JobQueueEntry{} = job_queue_entry) do
    job_config.repo.transaction(fn ->
      job_queue_entry
      |> job_config.repo.delete!()
    end)
  end

  # TODO This is incorrect, it needs to make an api call so that all nodes can be notified to TRY to stop the job
  # since we don't know which one it is running on
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

  def get_retry_count(%JobConfig{} = job_config, %JobQueueEntry{} = job_queue_entry) do
    case job_queue_entry.current_job_run_id do
      nil ->
        0

      job_run_id ->
        job_config.repo.get(JobRun, job_run_id).retry + 1
    end
  end

  def validate_job_context(job_context_schema, job_context) do
    Schema.resolve(job_context_schema)
    |> case do
      nil ->
        {:error, [{"Invalid job schema definition.", "schema"}]}

      schema ->
        Validator.validate(schema, job_context)
    end
  end

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
                fail_a_job(job_config, job_run, e)
            end
          rescue
            e ->
              Logger.error("Error running job: #{inspect(e)}")
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

  def find_elixir_process(%JobRun{} = job_run) do
    # find the process by name
    process_name = job_run.job_process_name
    name_atom = String.to_atom(process_name)

    case Process.whereis(name_atom) do
      nil -> nil
      process_pid -> process_pid
    end
  end

  def try_to_kill_process(process_pid) do
    # try to kill the process
    Process.exit(process_pid, :kill)
  end
end
