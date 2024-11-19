defmodule Bildad.Job.JobRun do
  @moduledoc """
  Database table for job runs. This includes active and completed job runs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Bildad.Job.JobTemplate
  alias Bildad.Job.JobQueueEntry

  schema "job_runs" do
    field(:job_run_identifier, :string)
    field(:retry, :integer)
    field(:job_process_name, :string)

    field(:started_at, :naive_datetime)
    field(:timeout_at, :naive_datetime)
    field(:expires_at, :naive_datetime)
    field(:ended_at, :naive_datetime)

    field(:status, :string)
    field(:result, :string)
    field(:reason, :string)

    field(:job_context, :map)

    belongs_to(:job_template, JobTemplate)
    belongs_to(:job_queue_entry, JobQueueEntry)

    timestamps()
  end

  def changeset(job_run, attrs \\ %{}) do
    job_run
    |> cast(attrs, [
      :job_run_identifier,
      :job_template_id,
      :retry,
      :job_process_name,
      :started_at,
      :timeout_at,
      :expires_at,
      :ended_at,
      :status,
      :result,
      :reason,
      :job_context,
      :job_queue_entry_id
    ])
    |> validate_required([
      :job_run_identifier,
      :job_template_id,
      :retry,
      :job_process_name,
      :started_at,
      :timeout_at,
      :expires_at,
      :status,
      :job_context
    ])
    |> unique_constraint(:job_process_name)
  end
end
