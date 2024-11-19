defmodule Bildad.Job.JobRuns do
  @moduledoc """
  Manages job runs.
  """

  import Ecto.Query

  alias Bildad.Job.JobRun
  alias Bildad.Job.JobConfig

  @doc """
  Lists all the job runs for the provided job run identifier without pagination.
  """
  def list_job_runs_for_identifier(%JobConfig{} = job_config, job_run_identifier) do
    from(r in JobRun,
      where: r.job_run_identifier == ^job_run_identifier
    )
    |> order_job_runs()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs that are running and have timed out without pagination.
  """
  def list_job_runs_to_kill(%JobConfig{} = job_config) do
    from(r in JobRun,
      where: r.status == ^job_config.job_run_status_running,
      where: r.timeout_at < ^DateTime.utc_now()
    )
    |> order_job_runs()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs that are running and have timed out with pagination (with the default page size if nil provided as the page size).
  """
  def list_job_runs_to_kill(%JobConfig{} = job_config, page, nil) do
    list_job_runs_to_kill(job_config, page, job_config.default_page_size)
  end

  def list_job_runs_to_kill(%JobConfig{} = job_config, page, limit) do
    from(r in JobRun,
      where: r.status == ^job_config.job_run_status_running,
      where: r.timeout_at < ^DateTime.utc_now()
    )
    |> paginate_job_runs(page, limit)
    |> order_job_runs()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs that were running, have not been killed and have expired without pagination.
  """
  def list_expired_jobs(%JobConfig{} = job_config) do
    from(r in JobRun,
      where: r.status == ^job_config.job_run_status_running,
      where: r.expires_at < ^DateTime.utc_now()
    )
    |> order_job_runs()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs that were running, have not been killed and have expired with pagination (with the default page size if nil provided as the page size).
  """
  def list_expired_jobs(%JobConfig{} = job_config, page, nil) do
    list_expired_jobs(job_config, page, job_config.default_page_size)
  end

  def list_expired_jobs(%JobConfig{} = job_config, page, limit) do
    from(r in JobRun,
      where: r.status == ^job_config.job_run_status_running,
      where: r.expires_at < ^DateTime.utc_now()
    )
    |> paginate_job_runs(page, limit)
    |> order_job_runs()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs that have finished with the provided result without pagination.
  """
  def list_job_runs_for_result(%JobConfig{} = job_config, result) do
    from(r in JobRun,
      where: r.status == ^job_config.job_run_status_done,
      where: r.result == ^result
    )
    |> order_job_runs()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the jobs that have finished with the provided result with pagination (with the default page size if nil provided as the page size).
  """
  def list_job_runs_for_result(%JobConfig{} = job_config, result, page, nil) do
    list_job_runs_for_result(job_config, result, page, job_config.default_page_size)
  end

  def list_job_runs_for_result(%JobConfig{} = job_config, result, page, limit) do
    from(r in JobRun,
      where: r.status == ^job_config.job_run_status_done,
      where: r.result == ^result
    )
    |> paginate_job_runs(page, limit)
    |> order_job_runs()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the job runs with pagination.
  """
  def list_all_job_runs(%JobConfig{} = job_config, page, limit) do
    from(r in JobRun)
    |> paginate_job_runs(page, limit)
    |> order_job_runs()
    |> job_config.repo.all()
  end

  @doc """
  Returns the number of job runs. (This is useful for pagination.)
  """
  def get_number_of_job_runs(job_config) do
    from(r in JobRun, select: count(r.id))
    |> job_config.repo.one()
  end

  defp paginate_job_runs(query, page, limit) do
    offset = limit * page

    query
    |> limit(^limit)
    |> offset(^offset)
  end

  defp order_job_runs(query) do
    query
    |> order_by([r], desc: r.inserted_at)
  end
end
