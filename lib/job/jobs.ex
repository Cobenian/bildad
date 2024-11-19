defmodule Bildad.Job.Jobs do
  @moduledoc """
  The Jobs module is responsible for managing job templates, job queue entries, and job runs.
  """
  import Ecto.Query

  alias Bildad.Job.JobTemplate
  alias Bildad.Job.JobQueueEntry
  alias Bildad.Job.JobRun
  alias Bildad.Job.JobConfig

  # Job Templates

  @doc """
  Lists all the active job templates without pagination.
  """
  def list_job_templates(%JobConfig{} = job_config) do
    list_active_job_templates(job_config)
  end

  @doc """
  Lists all the active job templates without pagination.
  """
  def list_all_job_templates(%JobConfig{} = job_config) do
    from(j in JobTemplate,
      order_by: [asc: :display_order]
    )
    |> job_config.repo.all()
  end

  @doc """
  Lists all the active job templates without pagination.
  """
  def list_active_job_templates(%JobConfig{} = job_config) do
    from(j in JobTemplate,
      where: j.active == true,
      order_by: [asc: :display_order]
    )
    |> job_config.repo.all()
  end

  @doc """
  Lists all the inactive job templates without pagination.
  """
  def list_inactive_job_templates(%JobConfig{} = job_config) do
    from(j in JobTemplate,
      where: j.active == false,
      order_by: [asc: :display_order]
    )
    |> job_config.repo.all()
  end

  @doc """
  Creates a new job template with the provided attributes.

  Note that the module_name should be a string version of the Elixir module name that will be used to run the job.

  Note that the job_context_schema should be a map that represents the schema of the context that will be passed to the job module. 
  It will be used to validate the context before running the job.
  """
  def create_job_template(%JobConfig{} = job_config, attrs) do
    %JobTemplate{}
    |> JobTemplate.changeset(attrs)
    |> job_config.repo.insert()
  end

  @doc """
  Updates the provided job template with the provided attributes.
  """
  def update_job_template(%JobConfig{} = job_config, %JobTemplate{} = job_template, attrs) do
    job_template
    |> JobTemplate.changeset(attrs)
    |> job_config.repo.update()
  end

  @doc """
  Deletes the provided job template.
  """
  def delete_job_template(%JobConfig{} = job_config, %JobTemplate{} = job_template) do
    job_config.repo.delete(job_template)
  end

  # Job Queue

  # list jobs to run
  @doc """
  Lists all the jobs that are available to run in the queue without pagination.
  """
  def list_jobs_to_run_in_the_queue(%JobConfig{} = job_config) do
    list_jobs_for_status_in_the_queue(job_config, job_config.queue_status_available)
  end

  @doc """
  Lists all the jobs that are available to run in the queue with pagination.
  """
  def list_jobs_to_run_in_the_queue(%JobConfig{} = job_config, page, limit \\ nil) do
    list_jobs_for_status_in_the_queue(job_config, job_config.queue_status_available, page, limit)
  end

  # list running jobs
  @doc """
  Lists all the jobs that are running in the queue without pagination.
  """
  def list_running_jobs_in_the_queue(%JobConfig{} = job_config) do
    list_jobs_for_status_in_the_queue(job_config, job_config.queue_status_running)
  end

  @doc """
  Lists all the jobs that are running in the queue with pagination.
  """
  def list_running_jobs_in_the_queue(%JobConfig{} = job_config, page, limit \\ nil) do
    list_jobs_for_status_in_the_queue(job_config, job_config.queue_status_running, page, limit)
  end

  @doc """
  Lists all the jobs for the given status in the queue without pagination.
  """
  def list_jobs_for_status_in_the_queue(%JobConfig{} = job_config, status) do
    from(e in JobQueueEntry,
      where: e.status == ^status,
      order_by: [asc: e.priority, asc: e.inserted_at]
    )
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs for the given status in the queue with pagination (with the default page size if nil provided for the page size).
  """
  def list_jobs_for_status_in_the_queue(%JobConfig{} = job_config, status, page, nil) do
    list_jobs_for_status_in_the_queue(job_config, status, page, job_config.default_page_size)
  end

  def list_jobs_for_status_in_the_queue(%JobConfig{} = job_config, status, page, limit) do
    offset = limit * page

    from(e in JobQueueEntry,
      where: e.status == ^status,
      order_by: [asc: e.priority, asc: e.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs in the queue without pagination.
  """
  def list_all_jobs_in_the_queue(%JobConfig{} = job_config) do
    from(e in JobQueueEntry,
      order_by: [asc: e.priority, asc: e.inserted_at]
    )
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs in the queue with pagination.
  """
  def list_all_jobs_in_the_queue(%JobConfig{} = job_config, page, limit) do
    offset = limit * page

    from(e in JobQueueEntry,
      order_by: [asc: e.priority, asc: e.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> job_config.repo.all()
  end

  # Job Runs

  # list jobs to kill

  @doc """
  Lists all the jobs that are running and have timed out without pagination.
  """
  def list_job_runs_to_kill(%JobConfig{} = job_config) do
    from(e in JobRun,
      where: e.status == ^job_config.job_run_status_running,
      where: e.timeout_at < ^DateTime.utc_now()
    )
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs that are running and have timed out with pagination (with the default page size if nil provided as the page size).
  """
  def list_job_runs_to_kill(%JobConfig{} = job_config, page, nil) do
    list_job_runs_to_kill(job_config, page, job_config.default_page_size)
  end

  def list_job_runs_to_kill(%JobConfig{} = job_config, page, limit) do
    offset = limit * page

    from(e in JobRun,
      where: e.status == ^job_config.job_run_status_running,
      where: e.timeout_at < ^DateTime.utc_now(),
      limit: ^limit,
      offset: ^offset
    )
    |> job_config.repo.all()
  end

  # list expired jobs

  @doc """
  Lists all the jobs that were running, have not been killed and have expired without pagination.
  """
  def list_expired_jobs(%JobConfig{} = job_config) do
    from(e in JobRun,
      where: e.status == ^job_config.job_run_status_running,
      where: e.expires_at < ^DateTime.utc_now()
    )
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs that were running, have not been killed and have expired with pagination (with the default page size if nil provided as the page size).
  """
  def list_expired_jobs(%JobConfig{} = job_config, page, nil) do
    list_expired_jobs(job_config, page, job_config.default_page_size)
  end

  def list_expired_jobs(%JobConfig{} = job_config, page, limit) do
    offset = limit * page

    from(e in JobRun,
      where: e.status == ^job_config.job_run_status_running,
      where: e.expires_at < ^DateTime.utc_now(),
      limit: ^limit,
      offset: ^offset
    )
    |> job_config.repo.all()
  end

  # list finished jobs

  @doc """
  Lists all the jobs that have finished with the provided result without pagination.
  """
  def list_job_runs_for_result(%JobConfig{} = job_config, result) do
    from(e in JobRun,
      where: e.status == ^job_config.job_run_status_done,
      where: e.result == ^result
    )
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs that have finished with the provided result with pagination (with the default page size if nil provided as the page size).
  """
  def list_job_runs_for_result(%JobConfig{} = job_config, result, page, nil) do
    list_job_runs_for_result(job_config, result, page, job_config.default_page_size)
  end

  def list_job_runs_for_result(%JobConfig{} = job_config, result, page, limit) do
    offset = limit * page

    from(e in JobRun,
      where: e.status == ^job_config.job_run_status_done,
      where: e.result == ^result,
      limit: ^limit,
      offset: ^offset
    )
    |> job_config.repo.all()
  end

  @doc """
  Lists all the job runs with pagination.
  """
  def list_all_job_runs(%JobConfig{} = job_config, page, page_size) do
    offset = page * page_size

    from(e in JobRun,
      limit: ^page_size,
      offset: ^offset,
      order_by: [desc: e.inserted_at]
    )
    |> job_config.repo.all()
  end
end
