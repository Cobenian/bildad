defmodule Bildad.Job.JobRunDetails do
  @moduledoc """
  Reads job run details. Returns nothing (rather than raising) for runs without details:
  runs from before run details were enabled, and applications that never enabled them, as
  long as the table exists.

  The saved run log (`log_tail`) is not loaded by these functions; read it with
  `Bildad.RunLog.get/2`.
  """

  import Ecto.Query

  alias Bildad.Job.JobConfig
  alias Bildad.Job.JobRunDetail

  # Keeps each query well below the bind parameter limit of both MySQL and Postgres.
  @chunk_size 1_000

  @doc "The details of one job run, or nil."
  def get_job_run_detail(%JobConfig{} = job_config, job_run_id) do
    job_config.repo.one(from(d in JobRunDetail, where: d.job_run_id == ^job_run_id))
  end

  @doc "The details of the given job runs, as a map of job run id to details."
  def list_job_run_details(%JobConfig{} = job_config, job_run_ids) do
    job_run_ids
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk_size)
    |> Enum.flat_map(fn ids ->
      job_config.repo.all(from(d in JobRunDetail, where: d.job_run_id in ^ids))
    end)
    |> Map.new(&{&1.job_run_id, &1})
  end
end
