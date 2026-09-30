# Changelog

## v0.1.13 (unreleased)

Two fixes to `run_a_job/2`. No database changes.

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