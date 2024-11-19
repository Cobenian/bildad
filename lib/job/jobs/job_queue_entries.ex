defmodule Bildad.Job.JobQueueEntries do
  @moduledoc """
  Manages job queue entries.
  """

  import Ecto.Query

  alias Bildad.Job.JobQueueEntry
  alias Bildad.Job.JobConfig

  @doc """
  Gets the job queue entry for the provided job run identifier. Returns nil if not found.
  """
  def get_job_queue_entry_for_identifier(%JobConfig{} = job_config, job_run_identifier) do
    from(e in JobQueueEntry,
      where: e.job_run_identifier == ^job_run_identifier
    )
    |> job_config.repo.one()
  end

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
      where: e.status == ^status
    )
    |> order_job_queue_entries()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs for the given status in the queue with pagination (with the default page size if nil provided for the page size).
  """
  def list_jobs_for_status_in_the_queue(%JobConfig{} = job_config, status, page, nil) do
    list_jobs_for_status_in_the_queue(job_config, status, page, job_config.default_page_size)
  end

  def list_jobs_for_status_in_the_queue(%JobConfig{} = job_config, status, page, limit) do
    from(e in JobQueueEntry,
      where: e.status == ^status
    )
    |> paginate_job_queue_entries(page, limit)
    |> order_job_queue_entries()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs in the queue without pagination.
  """
  def list_all_jobs_in_the_queue(%JobConfig{} = job_config) do
    from(e in JobQueueEntry)
    |> order_job_queue_entries()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs in the queue with pagination.
  """
  def list_all_jobs_in_the_queue(%JobConfig{} = job_config, page, limit) do
    from(e in JobQueueEntry)
    |> paginate_job_queue_entries(page, limit)
    |> order_job_queue_entries()
    |> job_config.repo.all()
  end

  defp paginate_job_queue_entries(query, page, limit) do
    offset = limit * page

    query
    |> limit(^limit)
    |> offset(^offset)
  end

  defp order_job_queue_entries(query) do
    query
    |> order_by([e], asc: e.priority, asc: e.inserted_at)
  end
end
