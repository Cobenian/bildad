defmodule Bildad.Job.JobTemplates do
  @moduledoc """
  Manages job templates.
  """

  import Ecto.Query

  alias Bildad.Job.JobTemplate
  alias Bildad.Job.JobConfig

  @doc """
  Lists all the active job templates without pagination.
  """
  def list_job_templates(%JobConfig{} = job_config) do
    list_active_job_templates(job_config)
  end

  @doc """
  Lists all the active job templates with pagination (with the default page size if nil provided as the page size).
  """
  def list_job_templates(%JobConfig{} = job_config, page, nil) do
    list_job_templates(job_config, page, job_config.default_page_size)
  end

  def list_job_templates(%JobConfig{} = job_config, page, limit) do
    list_active_job_templates(job_config, page, limit)
  end

  @doc """
  Lists all the active job templates without pagination.
  """
  def list_all_job_templates(%JobConfig{} = job_config) do
    from(j in JobTemplate)
    |> order_job_templates()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the active job templates with pagination (with the default page size if nil provided as the page size).
  """
  def list_all_job_templates(%JobConfig{} = job_config, page, nil) do
    list_all_job_templates(job_config, page, job_config.default_page_size)
  end

  def list_all_job_templates(%JobConfig{} = job_config, page, limit) do
    from(j in JobTemplate)
    |> paginate_job_templates(page, limit)
    |> order_job_templates()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the active job templates without pagination.
  """
  def list_active_job_templates(%JobConfig{} = job_config) do
    from(j in JobTemplate,
      where: j.active == true
    )
    |> order_job_templates()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the active job templates with pagination (with the default page size if nil provided as the page size).
  """
  def list_active_job_templates(%JobConfig{} = job_config, page, nil) do
    list_active_job_templates(job_config, page, job_config.default_page_size)
  end

  def list_active_job_templates(%JobConfig{} = job_config, page, limit) do
    from(j in JobTemplate,
      where: j.active == true
    )
    |> paginate_job_templates(page, limit)
    |> order_job_templates()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the inactive job templates without pagination.
  """
  def list_inactive_job_templates(%JobConfig{} = job_config) do
    from(t in JobTemplate,
      where: t.active == false
    )
    |> order_job_templates()
    |> job_config.repo.all()
  end

  @doc """
  Lists all the inactive job templates with pagination (with the default page size if nil provided as the page size).
  """
  def list_inactive_job_templates(%JobConfig{} = job_config, page, nil) do
    list_inactive_job_templates(job_config, page, job_config.default_page_size)
  end

  def list_inactive_job_templates(%JobConfig{} = job_config, page, limit) do
    from(t in JobTemplate,
      where: t.active == false
    )
    |> paginate_job_templates(page, limit)
    |> order_job_templates()
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

  defp paginate_job_templates(query, page, limit) do
    offset = limit * page

    query
    |> limit(^limit)
    |> offset(^offset)
  end

  defp order_job_templates(query) do
    query
    |> order_by([t], asc: t.display_order)
  end
end
