defmodule Bildad.Job.JobRunDetail do
  @moduledoc """
  Optional details of a job run: the node that ran it, its latest progress and, for a run
  that failed or was killed, the last lines it logged.

  The table is created by the migration from `mix bildad.gen.run_details_migration` and is
  only written when `config :bildad, run_details: true` is set (see `Bildad.Config`).
  A row is deleted with its job run.

  `log_tail` can contain personal data or secrets that a job logged. Show it only to people
  allowed to see job logs.
  """

  use Ecto.Schema

  alias Bildad.Job.JobRun

  schema "job_run_details" do
    field(:node, :string)
    field(:progress, :float)
    field(:progress_message, :string)
    field(:progress_at, :naive_datetime)
    field(:log_tail, :string, load_in_query: false)
    field(:log_tail_at, :naive_datetime)
    field(:log_tail_lines, :integer)
    field(:log_tail_dropped, :integer)

    belongs_to(:job_run, JobRun)

    timestamps()
  end
end
