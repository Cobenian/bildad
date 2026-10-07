# Plan: run observability

> **Status:** Done
> **Roadmap:** [roadmap.md](roadmap.md)

Revised after a five-reviewer design review (concurrency, API design, database, security
and privacy, devil's advocate). The decisions it changed are listed at the end.

## Constraints

1. **Nothing breaks for 0.1.13 users.** Every public function keeps its arity, arguments
   and return values. `run_job/1` is unchanged. An application that upgrades and changes
   nothing gets the P0 fixes; no new table is read or written and no logger handler is
   installed. (One idle process is added; see P1.)
2. **Nodes may not be connected.** Anything visible across nodes goes through the database;
   distribution (`:erpc`) is an optional extra the caller chooses, and Bildad never connects
   nodes on its own.
3. **Job data is sensitive.** Job contexts, failure reasons and log lines can hold personal
   data or secrets. Log retention is opt-in, capped, redacted (failing closed), persisted
   only on failure and pruned. Nothing new puts the job context anywhere.
4. **A job is never slowed down, blocked or failed by observability.** No observability
   write happens inside the job's own database transactions or inside the claim
   transaction; every failure is logged and ignored.
5. **Postgres and MySQL.** Migrations use the Ecto DSL. The suite runs on MySQL only; the
   Postgres path is reviewed, not tested (a gap to close separately).

## Configuration

Node-level settings live in application env (the `JobKiller` builds its own
`JobConfig.new(repo)`, so per-run options cannot travel through `%JobConfig{}`). They are
read once per job launch (and by the logger handler from its own handler config), never on
every progress call or log event.

```elixir
config :bildad,
  # Record node and latest progress in job_run_details, and allow run log persistence.
  # Requires the migration from `mix bildad.gen.run_details_migration`.
  run_details: false,
  progress_interval_ms: 1_000,          # telemetry throttle, per run
  progress_persist_interval_ms: 5_000,  # how often latest progress is written (run_details)
  run_log: [
    enabled: false,          # also requires run_details
    level: :info,
    max_lines: 200,
    max_line_bytes: 1_024,
    redact: nil,             # {Mod, :fun, extra_args}: fun(line, level, extra...) -> line | :drop
    retention_days: 14
  ]
```

## P0: every run ends with an outcome (done)

* `try` in the job process gets `catch kind, reason`; the outcome is computed first and
  written once by `record_outcome/3`; a failed write is logged and the run left to expiry.
  After an exit or throw the process re-exits with the same reason.
* Every failure reason is cut to 255 code points in one private helper.
* Released with phases 1 to 3 as 0.2.0 (it needs no new dependency, config or table).

## P1: live progress (done)

### Identity

The job process stores, before `run_job/1`, a context-free identity map in its process
dictionary and as its `Bildad.JobRegistry` value (which was `nil`):

```elixir
%{job_run_id: 42, job_run_identifier: "…", job_template_id: 7, job_module: MyJob,
  retry: 0, node: :"app@host"}
```

`Bildad.current_job/0` returns it (a stable, documented contract), from the calling process
or, for a `Task` started by the job, from the first `$callers` pid registered in
`Bildad.JobRegistry` on this node; the result is cached in the task's dictionary. `nil`
outside a job. Internal state (throttle `:atomics`, captured config) is kept out of the map.

### API

* `Bildad.progress(fraction, message \\ nil)`: fraction in 0..1 (clamped; anything else is
  treated as indeterminate), message cut to 255 code points. Returns `:ok` or
  `{:error, :not_in_a_job}`. Never raises.
* `Bildad.stream(chunk)`: `:stream` event with a binary chunk (cut to 64 KB on a UTF-8
  boundary). Not throttled, not persisted.

### Throttle

Per run, shared by the job and its tasks, through an `:atomics` reference created at
launch: an update is emitted if `progress_interval_ms` has passed since the last emitted
one (compare-and-swap, so only one caller wins), or if its fraction is 1.0. Updates inside
the interval are dropped, not held: a held update has no timer to send it. Documented.

### Telemetry

| Event | Measurements | Metadata (plus the identity map) |
|-------|--------------|----------------------------------|
| `[:bildad, :job, :start]` | `system_time`, `monotonic_time` | |
| `[:bildad, :job, :stop]` | `duration`, `monotonic_time` | `result: :succeeded \| :failed`, `error` |
| `[:bildad, :job, :exception]` | `duration`, `monotonic_time` | `kind`, `reason`, `stacktrace` |
| `[:bildad, :job, :progress]` | `fraction` (only when known) | `fraction`, `message` |
| `[:bildad, :job, :stream]` | `bytes` | `chunk` |
| `[:bildad, :job, :killed \| :expired \| :stopped]` | `system_time` | run fields only |

* `:stop` / `:exception` are exclusive and emitted after the outcome has been written.
* `:killed`, `:expired`, `:stopped` come from `kill_a_job/2`, `expire_a_job/2` and
  `stop_job_in_queue/2`, so a listener can end a progress bar. A host that kills a job
  process itself emits nothing (documented).
* `error`, `reason` and `stacktrace` are raw terms and can contain job data; they stay
  in the VM unless a handler sends them on (documented).

### Optional PubSub adapter

`Bildad.PubSub` is compiled only when `phoenix_pubsub` is available (optional dependency).
`attach(pubsub, opts)` returns `:ok` or `{:error, :already_exists}`; `opts`: `:id` (handler
id, default `Bildad.PubSub`), `:topic` (fun of identity, default
`"bildad:job:<job_run_id>"`), `:include_errors` (default false). It broadcasts
`{:bildad_job, event, payload}` where the payload has the identity, `fraction`, `message`,
`result`, `kind`, and only with `:include_errors` the raw error terms. The broadcast is
wrapped so a failure never detaches the handler. Cross-node delivery needs connected nodes
or a distributed PubSub adapter; otherwise read persisted progress.

### Persisted progress (only with `run_details`)

* `Bildad.RunDetails.Writer`, a small GenServer started by `Bildad.Application` under its
  own supervisor (so its failures cannot restart `Bildad.JobRegistry`), owns a public ETS
  table of latest-wins slots. The job process (or a task) only does `:ets.insert`.
* At launch the job process asks the writer (cast) to create the run's details row with
  `node`. On every tick (`progress_persist_interval_ms`) the writer writes the dirty slots
  with `update_all` limited to runs still `RUNNING`, inserting the row if missing. Every
  write is in `try`; a missing table is logged once per minute and nothing else happens.
* No write in the claim transaction, none in the job's process, none in the job's
  transactions.
* Read with `Jobs.get_job_run_detail/2` and `Jobs.list_job_run_details/2` (without
  `log_tail`), and `has_one :job_run_detail` on `JobRun`.

## P2: live introspection (done)

* Node: recorded in `job_run_details.node` by the P1 writer at launch.
* `Bildad.Introspect.info(job_process_name)` resolves the name through
  `Bildad.JobRegistry` (never a pid) and returns `{:ok, map}` with exactly
  `current_function`, `current_stacktrace` (module, function, arity, location),
  `memory`, `message_queue_len`, `reductions`, `status`, `node`; or
  `{:error, :not_running}`.
* `Bildad.Introspect.remote_info(node, job_process_name, opts)`: `node` as atom or string
  (string resolved with `String.to_existing_atom/1`, `{:error, :unknown_node}` if no such
  atom); local call when it is this node; otherwise `{:error, :not_distributed}` if this
  node is not alive, `{:error, :noconnection}` unless the node is in `Node.list/0` (no
  implicit connection), then `:erpc.call/5` with `opts[:timeout]` (default 2 s), mapping
  failures to `:noconnection`, `:timeout`, `:unsupported` (remote `undef` on
  `Bildad.Introspect` or no registry). Never raises.
* `Bildad.Introspect.run_info(job_config, job_run)`: node from `job_run_details`
  (`{:error, :no_details}` without a row), then `remote_info/3`.

## P3: run log retention (done)

Simpler than first planned: no buffer process, no ETS.

* `Bildad.RunLog.Handler` is a `:logger` handler with `level:` in its handler config, added
  by `Bildad.Application` when `run_log.enabled` and `run_details` are set, or at runtime
  with `Bildad.RunLog.attach/0`; `detach/0` removes it, and it is removed when the
  application stops.
* `log/2` runs in the logging process. It returns at once unless there is
  a buffer in the logging process's dictionary, which only a job process has. It formats the message only (no
  metadata) with bounded size (`chars_limit`), runs the redaction hook, strips NUL and
  invalid UTF-8, cuts to `max_line_bytes` on a UTF-8 boundary, and appends
  `"<ISO8601> [<level>] <message>"` to a ring buffer of `max_lines` in the **job process's
  own dictionary**. Everything is in `try`; nothing can remove the handler.
* Redaction fails closed: a hook that raises or returns anything but a binary or `:drop`
  drops the line and counts it as dropped.
* The buffer is started after the launch line, so that line is never captured. Tasks are
  not captured (they have no buffer). No Logger metadata is set, so nothing shows in host
  logs. Saved lines are separated by an ASCII record separator plus newline, because a
  message can span several lines.
* Persistence, only from a failed or killed run:
  * the job process, after a failed outcome has been decided, writes the buffer to
    `job_run_details.log_tail` (best-effort, outside any transaction); a succeeded run
    never writes;
  * `kill_a_job/2` (the `JobKiller`) reads the buffer of the local process with
    `Process.info(pid, {:dictionary, key})` before killing it, and persists it;
  * a host that stops a job itself calls `Bildad.RunLog.persist_local(job_config, job_run)`
    before killing the process. Out-of-memory, a node crash, or a kill without that call
    lose the buffer (documented).
* `Bildad.RunLog.tail(job_process_name)` reads the live buffer of a local running job
  (reachable with `:erpc`); `Bildad.RunLog.get(job_config, job_run_id)` reads the persisted
  tail.
* Retention: `Bildad.RunLog.prune(job_config, opts)` selects up to 500 detail ids with a
  `log_tail_at` older than `retention_days`, then nulls all four log columns for them. Called
  by `run_job_engine/1` whenever `run_details` is on (whatever `run_log.enabled` says), one
  batch per tick; also public for hosts.

## Launch logging

The launch line no longer `inspect`s the job context: it logs the context's keys. The
`JobKiller` logs the run's identifier instead of the whole run struct. Changelogged.

## Schema

`job_run_details` (new; `mix bildad.gen.run_details_migration [--migrations-path PATH]`,
which refuses to overwrite an existing one):

| Column | Type | Notes |
|--------|------|-------|
| `id` | default pk | |
| `job_run_id` | `references("job_runs", on_delete: :delete_all)`, unique | |
| `node` | string | |
| `progress` | float, null | 0..1 |
| `progress_message` | string, null | 255 |
| `progress_at` | naive_datetime, null | |
| `log_tail` | `:mediumtext` on MySQL, `:text` otherwise | |
| `log_tail_at` | naive_datetime, null, indexed | nulled with the tail |
| `log_tail_lines`, `log_tail_dropped` | integer, null | |
| timestamps | | |

`job_runs` is not altered. Detail rows go with their runs (cascade).

## Tests (MySQL)

P1: identity in job and task; progress emits telemetry; throttle (burst gives one event,
1.0 always passes); not in a job; start/stop/exception order after the outcome write;
killed/expired/stopped events; writer persists latest progress and node; missing table
does not stop jobs; PubSub adapter payloads. P2: whitelist keys exactly; not running;
remote errors (unknown node, not distributed, local shortcut). P3: failed run persists
lines, succeeded run persists nothing, killed run persists, caps and dropped count, redact
drop and fail-closed, handler not attached captures nothing, prune nulls old tails only,
the launch line is not captured.

## Committee decisions

* Config: node-level application env, read once per launch; not `%JobConfig{}`.
* No observability write in the claim transaction or the job's process; progress goes
  through a node-local writer, under its own supervisor.
* The run log buffer lives in the job process's dictionary instead of a buffer process
  with ETS and monitors. Kills through Bildad keep the log; external kills must call
  `persist_local/2` first.
* Throttle per run with `:atomics`, dropping (not holding) intermediate updates.
* New `:killed`, `:expired`, `:stopped` telemetry events.
* PubSub adapter kept (asked for), with a safe payload and no raw errors by default.
* `:erpc` only to already-connected nodes; no atoms from database strings.
* Redaction fails closed; lines are UTF-8 safe; pruning runs whenever run details are on.
* Out of scope, noted: conditional writes between `kill_a_job/2` and a job's own outcome;
  running the redaction hook over `job_runs.reason`; a Postgres CI job.
