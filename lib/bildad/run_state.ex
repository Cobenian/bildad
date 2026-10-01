defmodule Bildad.RunState do
  @moduledoc false
  # What a running job process knows about itself. Built by the launcher, stored as the
  # process's `Bildad.JobRegistry` value and in its process dictionary, so the job (and
  # tasks it starts) can report progress without passing anything around.
  #
  # Only `identity` is public (see `Bildad.current_job/0`). The rest is internal: the
  # repository for best-effort writes, the settings captured at launch, and the throttle.

  alias Bildad.Job.JobRun

  @key :"$bildad_job"

  @enforce_keys [:identity, :repo, :throttle, :progress_interval_ms, :run_details?]
  defstruct [:identity, :repo, :throttle, :progress_interval_ms, :run_details?, run_log?: false]

  @doc "Builds the state for a job run whose template is preloaded."
  def new(repo, %JobRun{} = job_run) do
    interval = Bildad.Config.progress_interval_ms()
    throttle = :atomics.new(1, signed: true)
    # The first update of a run is always sent.
    :atomics.put(throttle, 1, System.monotonic_time(:millisecond) - interval)

    %__MODULE__{
      identity: %{
        job_run_id: job_run.id,
        job_run_identifier: job_run.job_run_identifier,
        job_template_id: job_run.job_template_id,
        job_template_code: job_run.job_template.code,
        job_module: String.to_atom(job_run.job_template.job_module_name),
        retry: job_run.retry,
        node: node()
      },
      repo: repo,
      throttle: throttle,
      progress_interval_ms: interval,
      run_details?: Bildad.Config.run_details?(),
      run_log?: Bildad.Config.run_log?()
    }
  end

  @doc "Stores the state in the calling process."
  def put(%__MODULE__{} = state), do: Process.put(@key, state)

  @doc """
  The state of the job the calling process belongs to: its own, or for a process started
  by the job with `Task`, the job's (found through `$callers` and cached). nil outside a job.
  """
  def current do
    case Process.get(@key) do
      %__MODULE__{} = state -> state
      _ -> from_callers()
    end
  end

  defp from_callers do
    with callers when is_list(callers) <- Process.get(:"$callers"),
         %__MODULE__{} = state <- Enum.find_value(callers, &registered_state/1) do
      Process.put(@key, state)
      state
    else
      _ -> nil
    end
  end

  defp registered_state(pid) when is_pid(pid) and node(pid) == node() do
    with [name | _] <- Registry.keys(Bildad.JobRegistry, pid),
         [{^pid, %__MODULE__{} = state}] <- Registry.lookup(Bildad.JobRegistry, name) do
      state
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp registered_state(_), do: nil

  @doc """
  True when this update may be sent: the interval has passed since the last one sent for
  the run (whichever process sent it), or `force?` is set. Only one concurrent caller wins.
  """
  def allow_event?(%__MODULE__{throttle: throttle, progress_interval_ms: interval}, force?) do
    now = System.monotonic_time(:millisecond)
    last = :atomics.get(throttle, 1)

    cond do
      force? ->
        :atomics.put(throttle, 1, now)
        true

      now - last >= interval ->
        :atomics.compare_exchange(throttle, 1, last, now) == :ok

      true ->
        false
    end
  end
end
