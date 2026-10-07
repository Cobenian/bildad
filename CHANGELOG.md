# Changelog

## v0.2.0 (2026-10-07)

Progress reporting, job telemetry and optional run details. Nothing changes for an
application that does not use them, apart from the notes under "Upgrading: breaking and
behaviour changes".

**Upgrading: breaking and behaviour changes.** Read these before upgrading from 0.1.x.

* A job that calls `exit(:normal)` now ends its run as FAILED (it used to stay `RUNNING`
  until the run expired). Any other `exit/1` or `throw/1` is also recorded as FAILED.
* The launch log line lists only the job context's keys, not their values.
* A job process's `Bildad.JobRegistry` value is now a map of Bildad's run state instead of
  `nil`.
* New required dependency: `:telemetry`.
* New optional dependency: `phoenix_pubsub` (only needed for `Bildad.PubSub`).
* `Bildad.Application` starts a new process, `Bildad.RunDetails.Writer`, always. It stays
  idle unless run details are enabled. A host that starts Bildad's processes itself
  (`runtime: false`) must start it to use run details.

The test suite runs on MySQL. PostgreSQL support in the new `job_run_details` migration
template has been reviewed but is not tested in CI.

* **`Bildad.progress(fraction, message)`** reports the progress of a running job, and
  **`Bildad.stream(chunk)`** streams output, from the job's process or a task it starts,
  without passing anything around. **`Bildad.current_job/0`** returns the job's identity
  (run id, identifier, template, module, retry, node; never the context). Progress events are
  throttled per run (`config :bildad, progress_interval_ms: 1_000`); updates inside the
  interval are dropped, a fraction of 1 always passes. `run_job/1` is unchanged.
* **Telemetry events** `[:bildad, :job, :start | :stop | :exception | :progress | :stream]`
  from running jobs, and `[:bildad, :job, :killed | :expired | :stopped]` from
  `kill_a_job/2`, `expire_a_job/2` and `stop_job_in_queue/2`. See `Bildad.Telemetry`.
  Adds a dependency on `:telemetry`.
* **`Bildad.PubSub`** broadcasts those events over `Phoenix.PubSub` when `phoenix_pubsub`
  (a new optional dependency) is present. Error terms are left out unless asked for.
* **Run details (optional).** `mix bildad.gen.run_details_migration` writes a migration for
  a new `job_run_details` table; with `config :bildad, run_details: true` Bildad records the
  node that ran each job and its latest progress there (every
  `progress_persist_interval_ms`, default 5000), from a separate process, never inside the
  job's process or the transaction that claims the job. Read with
  `Jobs.get_job_run_detail/2` and `Jobs.list_job_run_details/2`, or the new
  `JobRun.job_run_detail` association. `job_runs` is not altered.
* **`Bildad.Introspect`** looks inside a running job: `info/1` on its own node, and
  `remote_info/3` / `run_info/2` on another node that is already connected (never connecting
  one, never creating an atom from a stored node name, never raising). Returns only
  `current_function`, `current_stacktrace` (arities, no arguments), `memory`,
  `message_queue_len`, `reductions`, `status` and `node`.
* **`Bildad.RunLog`** (optional, needs run details): a logger handler keeps the last lines
  each running job's own process logs (default 200 lines of up to 1 KB, at `:info` and
  above, message only, through an optional redaction hook that fails closed) and saves them
  with the run when it fails or is killed by the `JobKiller`; an application that stops a
  job itself calls `RunLog.persist_local/2` first. A succeeded run saves nothing. Read with
  `RunLog.get/2` (saved) and `RunLog.tail/1` (live). Saved lines are removed after
  `retention_days` (default 14) by the job engine. Enable with
  `config :bildad, run_details: true, run_log: [enabled: true]`.

Behaviour changes (details):

* The launch log line lists the job context's keys instead of `inspect`ing the whole context,
  and the `JobKiller` logs a run's id and identifier instead of the whole run (both included
  the context, which can hold personal data).
* A job process's `Bildad.JobRegistry` value is now Bildad's run state instead of `nil`.
* `Bildad.Application` also starts `Bildad.RunDetails.Writer`, which stays idle unless run
  details are enabled. A host that starts Bildad's processes itself (`runtime: false`) must
  start it to use run details.

Fixes:

* **A job that exits or throws ends its run as FAILED.** The job process caught exceptions
  only; `exit/1` (a `GenServer.call` timeout, say) or `throw/1` ended the process before the
  run was finished, and the run and its entry stayed `RUNNING` until the run expired. Both
  are now caught like an exception: the run is failed and the entry re-queued, or removed
  once its retries are used up. The process then still ends with the same exit, so processes
  the job linked to stop with it as before. A job that calls `exit(:normal)` is now FAILED
  (it used to stay `RUNNING`).
* **Recording a job's outcome is attempted once.** If the write that completes or fails the
  run raises (the database is unavailable, say), it is logged and the process ends. A failed
  completion is no longer followed by a second write that fails the run. The run is left to
  expiry, as a run whose process vanished is.
* **Every failure reason fits `job_runs.reason`.** Reasons are cut to 255 characters (code
  points) in one place. The schema validation message was not cut at all, and other reasons
  were cut to 256, so on a database in strict mode a long reason made the write that records
  the failure itself fail.

## v0.1.13 (2026-09-30)

Three fixes to launching jobs, a registry for job processes, and a shorter run expiry. No
database changes.

* **A job context that fails the template's schema is no longer launched.** Previously the
  failed run was recorded but the job was launched anyway, so it ran with an invalid
  context and could be recorded as succeeded, and the entry was put back in the queue to
  fail again on every engine run. Now one FAILED job run is recorded (with `ended_at`, which
  was not being set), the job is not launched, and the entry is removed from the queue,
  since the same context fails every time whatever `max_retries` is. `run_a_job/2` returns
  `{:error, {:invalid_job_context, job_run}}`.
* **A queue entry is claimed before it is run.** `run_a_job/2` moves the entry from
  `AVAILABLE` to `RUNNING` with a conditional update and checks that exactly one row changed.
  When two callers try to run the same entry, one runs it and the other gets
  `{:error, :job_not_available}` and nothing is launched. The entry is re-read after the
  claim, so a stale struct from the caller is not used.
* **A job that finishes at once no longer makes the launch fail, and no atom is created per
  job run.** The launcher used to spawn the job process and then register it under an atom
  made from the run's `job_process_name`; if the job had already finished, the registration
  raised. Now the job process registers itself in a `Registry` (`Bildad.JobRegistry`, unique
  keys, local to the node) under the `job_process_name` string as its first action, before it
  runs the job, and `launch_job_process/2` waits for that acknowledgement. If the process ends
  before it registers, the job has not run: the run is failed and
  `{:error, {:not_launched, reason}}` is returned (this replaces
  `{:error, "Failed to register process: ..."}`). If it has not registered within 5 seconds,
  `{:error, :registration_timeout}` is returned and the process is left alone.
  `find_elixir_process/1` (used by `kill_a_job/2` and so the `JobKiller`) looks the process
  up in the registry. The registry links to registered processes, so running jobs stop if
  Bildad's application stops (as they do when the node stops).
* **Upgrading.** Bildad now has an application module that starts `Bildad.JobRegistry`. It
  starts on its own when Bildad is a normal runtime dependency. A host that lists Bildad with
  `runtime: false` or under `included_applications` must start
  `{Registry, keys: :unique, name: Bildad.JobRegistry}` itself. Code that looked a job
  process up with `Process.whereis(String.to_atom(job_process_name))` must use
  `find_elixir_process/1` instead.
* **Run expiry reduced from 30 days to 2 days.** Expiry only cleans up runs whose process
  vanished; running jobs are still bounded by their own timeout. It is set by the new
  `JobConfig` field `job_run_expiry_in_days` (default 2) and counted from each run's start.
* Test suite added (MySQL; see the README).

## v0.1.12 (2026-07-20)

Fix `stop_job_in_queue/2` crashing with `Ecto.Association.NotLoaded.__changeset__/0
is undefined`. The `case` arm referenced the passed-in entry's `:current_job_run`
(unloaded) instead of the internally-preloaded struct; it now binds and uses the
preloaded entry.

## v0.1.11 (2026-02-18)

Fix stacktrace logging issue in `launch_job_process/2`. Updated hex deps.

## v0.1.10 (2025-11-19)

Add function to find all jobs with status `RUNNING` to allow for job resumption/restart post-deployment.

## v0.1.9 (2024-12-16)

Better error logging when a job fails with `{:error, reason}`.

## v0.1.8 (2024-12-07)

Current version. Recommended for use.

## v0.1.7 (2024-11-19)

Minor tweaks as the library is prepared. Not recommended to use this version.

## v0.1.6 (2024-11-19)

Minor tweaks as the library is prepared. Not recommended to use this version.

## v0.1.5 (2024-11-18)

Minor tweaks as the library is prepared. Not recommended to use this version.

## v0.1.4 (2024-11-18)

Minor tweaks as the library is prepared. Not recommended to use this version.

## v0.1.3 (2024-11-18)

Minor tweaks as the library is prepared. Not recommended to use this version.

## v0.1.2 (2024-11-18)

Minor tweaks as the library is prepared. Not recommended to use this version.

## v0.1.1 (2024-11-18)

Minor tweaks as the library is prepared. Not recommended to use this version.

## v0.1.0 (2024-11-18)

Initial release of Bildad.