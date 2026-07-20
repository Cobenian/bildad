# Changelog

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