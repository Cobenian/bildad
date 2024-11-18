defmodule Bildad.Job.JobTemplate do
  use Ecto.Schema
  import Ecto.Changeset

  schema "job_templates" do
    field(:name, :string)
    field(:code, :string)
    field(:active, :boolean)
    field(:display_order, :integer)
    field(:job_module_name, :string)
    field(:default_timeout_in_minutes, :integer)
    field(:default_max_retries, :integer)
    field(:job_context_schema, :map)

    timestamps()
  end

  def changeset(job_template, attrs \\ %{}) do
    job_template
    |> cast(attrs, [
      :name,
      :code,
      :active,
      :display_order,
      :job_module_name,
      :default_timeout_in_minutes,
      :default_max_retries,
      :job_context_schema
    ])
    |> validate_required([:name, :code, :job_context_schema, :job_module_name])
    |> unique_constraint(:code)
  end
end
