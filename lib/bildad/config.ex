defmodule Bildad.Config do
  @moduledoc """
  Node-level settings for progress, run details and the run log, read from the `:bildad`
  application environment.

  They are node-level rather than part of `Bildad.Job.JobConfig` because the `JobKiller`
  builds its own `JobConfig` and per-run options could not reach it. They are read once per
  job launch (and by the run log handler when it is attached), never on every progress call
  or log line.

      config :bildad,
        # Record the node and latest progress of each run in job_run_details, and allow the
        # run log to be kept. Requires the migration from
        # `mix bildad.gen.run_details_migration`.
        run_details: false,
        # At most one :progress telemetry event per run per interval (0: no throttle).
        progress_interval_ms: 1_000,
        # How often the latest progress of each run is written (with run_details).
        progress_persist_interval_ms: 5_000,
        run_log: [
          # Keep the last log lines of each running job and save them when it fails.
          # Also requires run_details.
          enabled: false,
          # Lines below this level are not kept.
          level: :info,
          # Lines kept per run; the oldest are dropped first.
          max_lines: 200,
          # Each line is cut to this many bytes.
          max_line_bytes: 1_024,
          # {Module, :function, extra_args}: called as function(line, level, extra_args...)
          # and must return the line to keep or :drop. Anything else, or a raise, drops it.
          redact: nil,
          # Saved run logs older than this are removed by the job engine.
          retention_days: 14
        ]

  Everything is off by default.
  """

  @run_log_defaults [
    enabled: false,
    level: :info,
    max_lines: 200,
    max_line_bytes: 1_024,
    redact: nil,
    retention_days: 14
  ]

  @doc "True when job_run_details rows are written."
  def run_details?, do: Application.get_env(:bildad, :run_details, false) == true

  @doc "Minimum time between two :progress events of one run."
  def progress_interval_ms, do: non_negative(:progress_interval_ms, 1_000)

  @doc "How often the latest progress of each run is written."
  def progress_persist_interval_ms, do: non_negative(:progress_persist_interval_ms, 5_000, 1)

  @doc "The run log settings, with defaults for anything not set."
  def run_log do
    Keyword.merge(@run_log_defaults, Application.get_env(:bildad, :run_log, []))
  end

  @doc "True when the run log is enabled and has somewhere to be saved."
  def run_log? do
    run_details?() and Keyword.fetch!(run_log(), :enabled) == true
  end

  defp non_negative(key, default, min \\ 0) do
    case Application.get_env(:bildad, key, default) do
      n when is_integer(n) and n >= min -> n
      _ -> default
    end
  end
end
