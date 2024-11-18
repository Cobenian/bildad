defmodule Bildad.Job.Jobs do
  import Ecto.Query

  alias Bildad.Job.JobTemplate
  alias Bildad.Job.JobQueueEntry
  alias Bildad.Job.JobRun
  alias Bildad.Job.JobConfig

  # Job Templates

  def list_job_templates(%JobConfig{} = job_config) do
    list_active_job_templates(job_config)
  end

  def list_all_job_templates(%JobConfig{} = job_config) do
    from(j in JobTemplate,
      order_by: [asc: :display_order]
    )
    |> job_config.repo.all()
  end

  def list_active_job_templates(%JobConfig{} = job_config) do
    from(j in JobTemplate,
      where: j.active == true,
      order_by: [asc: :display_order]
    )
    |> job_config.repo.all()
  end

  def list_inactive_job_templates(%JobConfig{} = job_config) do
    from(j in JobTemplate,
      where: j.active == false,
      order_by: [asc: :display_order]
    )
    |> job_config.repo.all()
  end

  def create_job_template(%JobConfig{} = job_config, attrs) do
    %JobTemplate{}
    |> JobTemplate.changeset(attrs)
    |> job_config.repo.insert()
  end

  def update_job_template(%JobConfig{} = job_config, %JobTemplate{} = job_template, attrs) do
    job_template
    |> JobTemplate.changeset(attrs)
    |> job_config.repo.update()
  end

  def delete_job_template(%JobConfig{} = job_config, %JobTemplate{} = job_template) do
    job_config.repo.delete(job_template)
  end

  # Job Queue

  # list jobs to run

  def list_jobs_to_run_in_the_queue(%JobConfig{} = job_config) do
    list_jobs_for_status_in_the_queue(job_config, job_config.queue_status_available)
  end

  def list_jobs_to_run_in_the_queue(%JobConfig{} = job_config, page, limit \\ nil) do
    list_jobs_for_status_in_the_queue(job_config, job_config.queue_status_available, page, limit)
  end

  # list running jobs
  def list_running_jobs_in_the_queue(%JobConfig{} = job_config) do
    list_jobs_for_status_in_the_queue(job_config, job_config.queue_status_running)
  end

  def list_running_jobs_in_the_queue(%JobConfig{} = job_config, page, limit \\ nil) do
    list_jobs_for_status_in_the_queue(job_config, job_config.queue_status_running, page, limit)
  end

  def list_jobs_for_status_in_the_queue(%JobConfig{} = job_config, status) do
    from(e in JobQueueEntry,
      where: e.status == ^status,
      order_by: [asc: e.priority, asc: e.inserted_at]
    )
    |> job_config.repo.all()
  end

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

  def list_all_jobs_in_the_queue(%JobConfig{} = job_config) do
    from(e in JobQueueEntry,
      order_by: [asc: e.priority, asc: e.inserted_at]
    )
    |> job_config.repo.all()
  end

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

  def list_job_runs_to_kill(%JobConfig{} = job_config) do
    from(e in JobRun,
      where: e.status == ^job_config.job_run_status_running,
      where: e.timeout_at < ^DateTime.utc_now()
    )
    |> job_config.repo.all()
  end

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

  def list_expired_jobs(%JobConfig{} = job_config) do
    from(e in JobRun,
      where: e.status == ^job_config.job_run_status_running,
      where: e.expires_at < ^DateTime.utc_now()
    )
    |> job_config.repo.all()
  end

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

  def list_job_runs_for_result(%JobConfig{} = job_config, result) do
    from(e in JobRun,
      where: e.status == ^job_config.job_run_status_done,
      where: e.result == ^result
    )
    |> job_config.repo.all()
  end

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
