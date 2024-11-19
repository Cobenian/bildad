defmodule Bildad.Job.JobConfig do
  @moduledoc """
  Configuration for the Bildad job scheduling framework.
  """

  @enforce_keys [:repo]
  defstruct [
    :repo,
    default_page_size: 25,
    # immutable values
    queue_status_running: "RUNNING",
    queue_status_available: "AVAILABLE",
    job_run_status_running: "RUNNING",
    job_run_status_done: "DONE",
    job_run_result_succeeded: "SUCCEEDED",
    job_run_result_failed: "FAILED"
  ]

  @doc """
  Creates a new JobConfig struct for the provided database repository.

  Prefer this function over directly creating the struct as the struct internals may change over time.
  """
  def new(repo, default_page_size \\ 25) do
    %__MODULE__{repo: repo, default_page_size: default_page_size}
  end
end
