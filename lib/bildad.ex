defmodule Bildad do
  @moduledoc """
  This module contains documentation for the Bildad Jobs Framework.

  This framework has a queue (with priority) and it can work across multiple nodes.

  > **NOTE**: THIS FRAMEWORK DOES NOT GUARANTEE EXACTLY ONCE DELIVERY.

  IF YOU ARE LOOKING FOR A JOB SCHEDULING FRAMEWORK THAT GUARAENTEES EXACTLY ONCE DELIVERY, THIS IS NOT IT.
  THIS FRAMEWORK ALSO DOES NOT GUARANTEE THAT A JOB WILL RUN EXACTLY ONE TIME.

  This framework is intended to only for jobs that are Elixir code and that will be running in a group of nodes
  that are NOT connected. 

  ## Database

  Bildad uses the following tables in the database:

  * `Job templates` are the definition of the jobs that are available to run. They contain the name of the Elixir 
  module to run and they contain a json schema to validate the job context when a job is run. Job templates are 
  created by the application and are used to create job queue entries when it is time to run a job.

  * `Job queue entries` are the jobs that should be run. They have a status of available or running. They are 
  created by the application and are run by the job engine. If the job completes successfully the job queue entry is
  deleted. If the job fails it will be retried up to the number of max retries specified in the queue entry. Once
  the maximum number of retries is reached the entry is deleted from the queue.

  * `Job runs` are the occurances of a job that have run or are running. They are created by the job engine when 
  it picks up an entry from the queue and tries to run it. Job runs may be successful or failed. Job runs are
  not deleted from the database when they are done to serve as a history of what has run.

  ## Modules

  The `Bildad.Job.JobConfig` module is responsible for holding the configuration of the job scheduling framework. 
  It holds the module for the database repository and other internal configuration values.

  The `Bildad.Job.Jobs` module is responsible for querying for job templates, job queue entries, and job runs.
  It also has functions for creating, updating, and deleting job templates.

  The `Bildad.Job.JobEngine` module is responsible for running jobs. Jobs are enqueued in the job queue by the application
  and then run by the job engine. This module also expires jobs that have timed out and are not running on any nodes.
  This is meant to be run on a single node at a time (the framework does NOT guarantee this). 
  A load balancer can be used to send requests to balance the load across multiple nodes.

  The `Bildad.Job.JobKiller` module is responsible for killing jobs that have run too long. It runs on each node.
  This module is configured to run under a supervision tree, you do not need to programmatically call it.

  ## Error Handling

  Bildad has built in retries for jobs that fail.

  There are three primary types of error handling in Bildad:

  * Jobs that fail are immediately marked as failed run in the `job_runs` table. If it is the last retry 
  then the job is removed from the queue. If it is not the last retry then the queue entry is updated to 
  be available.
  * Jobs that run past their timeout are killed by the `JobKiller` module ON THE NODE RUNNING THE JOB. 
  The job is marked as failed in the `job_runs` table. If it is not the last retry then the queue entry 
  is updated to be available. If it is the last retry then the job is removed from the queue.
  * Jobs that fail and are no longer running on any node (so they cannot be killed) are marked as failed 
  in the `job_runs` table after the expiration date. 

  ## Progress, introspection and run logs

  A job can report its progress with `progress/2` and stream output with `stream/1`, without
  being passed anything: the job's identity (`current_job/0`) is set up when it is launched.
  Both emit `:telemetry` events (see `Bildad.Telemetry`); `Bildad.PubSub` can broadcast them.

  The optional `job_run_details` table (see `Bildad.Config`) records the node that ran each
  job and its latest progress, so other nodes can read them from the database.
  `Bildad.Introspect` looks inside a running job, and `Bildad.RunLog` keeps the last log
  lines of a run that failed or was killed.

  ## Name
  Why the name Bildad? Bildad is a character from the Bible. He was one of Job's friends.

  See the `README.md` for more information.
  """

  alias Bildad.RunState
  alias Bildad.RunDetails.Writer

  @max_message_length 255
  @max_chunk_bytes 65_536

  @doc """
  The identity of the job the calling process belongs to, or nil outside a job.

  Works in the job's own process and in processes it starts with `Task` (found through
  `$callers`). The map has these keys, all stable:

  * `:job_run_id` - the id of the job run
  * `:job_run_identifier` - the job run identifier, shared by every retry of the job
  * `:job_template_id`, `:job_template_code` - the job template
  * `:job_module` - the module whose `run_job/1` is running
  * `:retry` - the retry number of this run, from 0
  * `:node` - the node running the job

  It never contains the job context.
  """
  @spec current_job() :: map() | nil
  def current_job do
    case RunState.current() do
      %RunState{identity: identity} -> identity
      nil -> nil
    end
  end

  @doc """
  Reports the progress of the running job.

  `fraction` is a number from 0 to 1 (clamped), or nil when the job cannot tell how far it
  is. `message` is a short description of what the job is doing (cut to 255 characters),
  or nil.

  Emits a `[:bildad, :job, :progress]` telemetry event. Events are throttled per run (shared
  by the job and the tasks it starts): an update is sent only if
  `config :bildad, :progress_interval_ms` (default 1000) has passed since the last one sent,
  or if its fraction is 1. Updates inside the interval are dropped, not delayed.

  With run details enabled, the latest update is also written to the run's
  `job_run_details` row, every `progress_persist_interval_ms` (default 5000), by a separate
  process: never in the job's process or its transactions.

  Returns `:ok`, or `{:error, :not_in_a_job}` when called outside a job. Never raises.

      def run_job(%{"ids" => ids}) do
        total = length(ids)

        ids
        |> Enum.with_index(1)
        |> Enum.each(fn {id, n} ->
          process(id)
          Bildad.progress(n / total, "processed \#{n} of \#{total}")
        end)

        {:ok, total}
      end
  """
  @spec progress(number() | nil, String.t() | nil) :: :ok | {:error, :not_in_a_job}
  def progress(fraction, message \\ nil) do
    case RunState.current() do
      nil ->
        {:error, :not_in_a_job}

      %RunState{} = state ->
        fraction = normalize_fraction(fraction)
        message = normalize_message(message)

        Writer.progress(state, fraction, message)

        if RunState.allow_event?(state, fraction == 1.0) do
          measurements = if fraction, do: %{fraction: fraction}, else: %{}

          :telemetry.execute(
            [:bildad, :job, :progress],
            measurements,
            Map.merge(state.identity, %{fraction: fraction, message: message})
          )
        end

        :ok
    end
  end

  @doc """
  Streams a chunk of output from the running job, as a `[:bildad, :job, :stream]` telemetry
  event. The chunk is cut to 64 KB. Not throttled (a stream with missing chunks is
  corrupt) and not saved anywhere.

  Returns `:ok`, or `{:error, :not_in_a_job}` when called outside a job. Never raises.
  """
  @spec stream(iodata()) :: :ok | {:error, :not_in_a_job}
  def stream(chunk) do
    case RunState.current() do
      nil ->
        {:error, :not_in_a_job}

      %RunState{} = state ->
        chunk = chunk |> to_binary() |> Bildad.Text.cut_bytes(@max_chunk_bytes)

        :telemetry.execute(
          [:bildad, :job, :stream],
          %{bytes: byte_size(chunk)},
          Map.put(state.identity, :chunk, chunk)
        )

        :ok
    end
  end

  defp normalize_fraction(f) when is_number(f), do: f |> max(0) |> min(1) |> Kernel./(1)
  defp normalize_fraction(_), do: nil

  defp normalize_message(m) when is_binary(m) do
    m
    |> Bildad.Text.cut_bytes(@max_message_length * 4)
    |> Bildad.Text.sanitize()
    |> Bildad.Text.cut_chars(@max_message_length)
  end

  defp normalize_message(nil), do: nil
  defp normalize_message(m), do: m |> to_binary() |> normalize_message()

  defp to_binary(data) when is_binary(data), do: data

  defp to_binary(data) do
    IO.chardata_to_string(data)
  rescue
    _ -> inspect(data, limit: 50, printable_limit: 1_024)
  end
end
