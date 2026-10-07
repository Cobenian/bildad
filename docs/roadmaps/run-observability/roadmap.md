# Roadmap: run observability

> **Status:** Done

Bildad records *that* a job ran, when, for how long and whether it failed. It cannot say
what a running job is doing now, look inside a running job, or keep the log lines that
explain why a job failed. This roadmap adds those three things without changing how jobs
are scheduled, claimed, retried or queued, and without breaking any application that does
not adopt them.

The detailed design is in [`plan.md`](plan.md).

## Phases

Each phase is independently testable and lands as one or more commits on the same branch.
All four phases are done and are released together as 0.2.0.

| Phase | Delivers | Needs a database change | Opt-in | Status |
|-------|----------|-------------------------|--------|--------|
| P0 | Every run ends with a recorded outcome; every failure reason fits its column | No | No (bug fix) | Done |
| P1 | Live progress: `Bildad.progress/2`, `Bildad.stream/1`, telemetry events, throttling, optional PubSub adapter, optional persisted progress | Optional (`job_run_details`) | Yes | Done |
| P2 | Live introspection: node recorded per run, `Bildad.Introspect` with a fixed whitelist | Optional (`job_run_details`) | Yes | Done |
| P3 | Run log retention: the last ~200 log lines of a failed, killed or stopped run | Optional (`job_run_details`) | Yes | Done |

### P0: every run ends with an outcome (done)

* A job that calls `exit/1` or `throw/1` is caught like an exception: its run is failed and
  its entry re-queued or removed as for any failure. Today the process dies, nothing
  records the outcome, and the run stays `RUNNING` until it expires.
* The outcome is written once. A failed write is logged; it is not followed by a second,
  contradictory write.
* Every failure reason is truncated, in one place, to fit `job_runs.reason`
  (`varchar(255)`), including the schema validation message, which was not truncated at
  all, and the generic one, which was cut to 256.

### P1: live progress (done)

* `Bildad.progress(fraction, message)` and `Bildad.stream(chunk)` are callable from inside a
  job (and from processes it starts with `Task`), without passing any identifier around.
* Telemetry events `[:bildad, :job, :start | :stop | :exception | :progress | :stream]`.
* Progress is throttled per run; `run_job/1` is unchanged.
* Optional `Bildad.PubSub` adapter, compiled only when `phoenix_pubsub` is present.
* Optional persistence of the latest progress in `job_run_details`, written by a
  node-local writer, so a node that is not connected to the job's node can still read it.
* Telemetry events for runs that are killed, expired or stopped.

### P2: live introspection (done)

* With run details on, the node that launched a run is recorded.
* `Bildad.Introspect.info/1` returns a fixed whitelist of process information for a job
  running on the local node. `Bildad.Introspect.remote_info/3` calls it on another node
  and turns every failure (no connection, timeout, node on an older Bildad, run finished)
  into a tagged error instead of an exception. Nothing assumes nodes are connected.

### P3: run log retention (done)

* An opt-in `:logger` handler keeps the last N log lines of each running job in a ring
  buffer held by the job's own process, capped per line and per run.
* The buffer is persisted to `job_run_details` only when the run fails, is killed by the
  `JobKiller`, or is stopped by a host that calls `Bildad.RunLog.persist_local/2` first; it
  is discarded when the run succeeds.
* Lines pass through a redaction hook before they are buffered. Persisted logs are pruned
  after a retention period by the job engine.

### Upgrade path

* `mix bildad.gen.run_details_migration` writes the `job_run_details` migration into an
  existing application. Nothing in 0.2.0 reads or writes that table unless run details are
  enabled in config, so an application that upgrades without running it keeps working.

## Out of scope

* Any change to how jobs are scheduled, claimed, retried or queued.
* Remote control of a running job (stop, pause) beyond what exists.
* Inspecting jobs that have already finished.
* Long-term log storage: the retained log is a small, capped tail.
