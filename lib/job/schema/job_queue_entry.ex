defmodule Bildad.Job.JobQueueEntry do
  @moduledoc """
  Database table for the job queue entries.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Bildad.Job.JobTemplate
  alias Bildad.Job.JobRun

  schema "job_queue_entries" do
    field(:job_run_identifier, :string)
    field(:status, :string)
    field(:priority, :integer)
    field(:timeout_in_minutes, :integer)
    field(:max_retries, :integer)
    field(:job_context, :map)

    belongs_to(:current_job_run, JobRun)
    belongs_to(:job_template, JobTemplate)

    timestamps()
  end

  def changeset(job_template, attrs \\ %{}) do
    job_template
    |> cast(attrs, [
      :job_template_id,
      :job_run_identifier,
      :status,
      :priority,
      :timeout_in_minutes,
      :max_retries,
      :current_job_run_id,
      :job_context
    ])
    |> validate_required([:job_template_id, :job_run_identifier, :job_context])
    |> unique_constraint(:job_run_identifier)
  end
end
