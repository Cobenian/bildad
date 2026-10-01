defmodule Bildad.Telemetry do
  @moduledoc """
  The `:telemetry` events Bildad emits.

  Events from a running job are emitted in the job's own process, so a handler that is slow
  slows the job. Every event's metadata contains the job's identity (see
  `Bildad.current_job/0`); the job context is never included.

  | Event | Measurements | Metadata (besides the identity) |
  |-------|--------------|---------------------------------|
  | `[:bildad, :job, :start]` | `system_time`, `monotonic_time` | |
  | `[:bildad, :job, :stop]` | `duration`, `monotonic_time` | `result` (`:succeeded` or `:failed`), `error` (the term of an `{:error, term}` result, or nil) |
  | `[:bildad, :job, :exception]` | `duration`, `monotonic_time` | `kind` (`:error`, `:exit` or `:throw`), `reason`, `stacktrace` |
  | `[:bildad, :job, :progress]` | `fraction` (only when known) | `fraction` (or nil), `message` (or nil) |
  | `[:bildad, :job, :stream]` | `bytes` | `chunk` |

  `:stop` and `:exception` are exclusive, as with `:telemetry.span/3`, and are emitted after
  the run's outcome has been written, so a handler that reads the run sees it finished.
  `:progress` is throttled per run (see `Bildad.progress/2`).

  Events about a run, emitted where the run is finished by someone other than the job:

  | Event | Measurements | Metadata |
  |-------|--------------|----------|
  | `[:bildad, :job, :killed]` | `system_time` | `job_run_id`, `job_run_identifier`, `retry` |
  | `[:bildad, :job, :expired]` | `system_time` | `job_run_id`, `job_run_identifier`, `retry` |
  | `[:bildad, :job, :stopped]` | `system_time` | `job_run_id`, `job_run_identifier`, `retry` |

  `:killed` comes from `Bildad.Job.JobEngine.kill_a_job/2` (the `JobKiller`), `:expired` from
  `expire_a_job/2` and `:stopped` from `stop_job_in_queue/2`. An application that kills a job
  process itself emits nothing.

  `error`, `reason` and `stacktrace` are raw terms and can contain data the job worked on.
  They stay in the VM unless a handler sends them somewhere.
  """

  alias Bildad.Job.JobRun

  @doc false
  def run_event(event, %JobRun{} = job_run) when event in [:killed, :expired, :stopped] do
    :telemetry.execute(
      [:bildad, :job, event],
      %{system_time: System.system_time()},
      %{
        job_run_id: job_run.id,
        job_run_identifier: job_run.job_run_identifier,
        retry: job_run.retry
      }
    )
  end
end
