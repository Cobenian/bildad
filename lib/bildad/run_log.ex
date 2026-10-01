defmodule Bildad.RunLog do
  @moduledoc """
  Keeps the last log lines of each running job, and saves them with the run when it fails
  or is killed, so the cause of a failure can be read with the run.

  Off by default. To turn it on (it also needs run details and their migration; see
  `Bildad.Config`):

      config :bildad,
        run_details: true,
        run_log: [enabled: true]

  ## What is kept

  * Lines the job's own process logs at `run_log[:level]` (default `:info`) or above, after
    Bildad's launch line, which is never kept. Tasks the job starts are not captured. The
    primary `:logger` level still applies.
  * The message only, never Logger metadata, formatted as
    `"<ISO 8601 time> [<level>] <message>"`. A message can span several lines (a stack
    trace, say).
  * At most `max_lines` lines per run (default 200; the oldest are dropped), each cut to
    `max_line_bytes` (default 1024).
  * Each line first goes through the `redact` hook, if configured: `{module, function,
    extra_args}`, called as `function(message, level, extra_args...)` in the logging
    process. It returns the message to keep or `:drop`. Anything else, or a raise, drops
    the line: the hook fails closed.

  Lines that are dropped (by the hook, or the oldest beyond `max_lines`) are counted.

  ## When it is saved

  The lines live in the job's own process while it runs, and are saved to the run's
  `job_run_details` row only:

  * when the job fails (returns an error, raises, exits or throws), by the job's process;
  * when the `JobKiller` kills the job for running past its timeout (`kill_a_job/2`);
  * when the application stopping a job calls `persist_local/2` before it kills the process.

  A job that succeeds saves nothing. A job process killed in any other way, a node that goes
  down, or a process that runs out of memory loses its lines.

  ## Reading and retention

  `get/2` reads the saved lines of a run, `tail/1` the live lines of a job running on this
  node. Saved lines are removed `retention_days` (default 14) after they were saved, by the
  job engine (`prune/2`), whenever run details are enabled, also after the run log has been
  turned off. They are also deleted with their job run.

  The lines can contain personal data or secrets the job logged. These functions do no
  access control; show the lines only to people allowed to see job logs.
  """

  import Ecto.Query

  require Logger

  alias Bildad.Job.JobConfig
  alias Bildad.Job.JobRun
  alias Bildad.Job.JobRunDetail
  alias Bildad.RunLog.Handler

  @handler_id :bildad_run_log
  @prune_batch_size 500

  # Saved lines are joined with a newline preceded by an ASCII record separator, which the
  # handler removes from messages: a message can span several lines (a stack trace), so a
  # newline alone cannot separate them. The saved text still reads line by line.
  @separator "\u001E\n"

  @doc """
  Adds the logger handler with the current `run_log` settings. Called by Bildad's
  application at start when the run log is enabled; call it to enable the run log at
  runtime. Returns `:ok` or `{:error, reason}`.
  """
  def attach do
    settings = Bildad.Config.run_log()

    config = %{
      max_lines: Keyword.fetch!(settings, :max_lines),
      max_line_bytes: Keyword.fetch!(settings, :max_line_bytes),
      redact: Keyword.fetch!(settings, :redact)
    }

    case :logger.add_handler(@handler_id, Handler, %{
           level: Keyword.fetch!(settings, :level),
           config: config
         }) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      error -> error
    end
  end

  @doc "Removes the logger handler. Jobs already running keep their lines but get no more."
  def detach do
    case :logger.remove_handler(@handler_id) do
      :ok -> :ok
      {:error, {:not_found, _}} -> :ok
      error -> error
    end
  end

  @doc """
  The live lines of the job running on this node under `job_process_name`.
  `{:error, :not_running}` when there is no such job here (or it keeps no lines).
  """
  @spec tail(String.t()) :: {:ok, [String.t()]} | {:error, :not_running}
  def tail(job_process_name) when is_binary(job_process_name) do
    with [{pid, _}] <- Registry.lookup(Bildad.JobRegistry, job_process_name),
         {lines, _count, _dropped} <- read_buffer(pid) do
      {:ok, :queue.to_list(lines)}
    else
      _ -> {:error, :not_running}
    end
  end

  @doc """
  The saved lines of a job run: `%{lines: [...], saved_at: ..., dropped: n}`, or nil when
  none were saved.
  """
  def get(%JobConfig{} = job_config, job_run_id) do
    from(d in JobRunDetail,
      where: d.job_run_id == ^job_run_id and not is_nil(d.log_tail),
      select: %{log_tail: d.log_tail, saved_at: d.log_tail_at, dropped: d.log_tail_dropped}
    )
    |> job_config.repo.one()
    |> case do
      nil ->
        nil

      %{log_tail: tail} = row ->
        %{
          lines: String.split(tail, @separator),
          saved_at: row.saved_at,
          dropped: row.dropped || 0
        }
    end
  end

  @doc """
  Saves the lines of a job running on this node, for an application that stops a job by
  killing its process: call it just before the kill. Returns `:ok`, or
  `{:error, :not_running}` when the job does not run here or keeps no lines.
  """
  def persist_local(%JobConfig{} = job_config, %JobRun{} = job_run) do
    with [{pid, _}] <- Registry.lookup(Bildad.JobRegistry, job_run.job_process_name),
         {_, _, _} = buffer <- read_buffer(pid) do
      save(job_config.repo, job_run.id, buffer)
    else
      _ -> {:error, :not_running}
    end
  end

  @doc """
  Removes saved lines older than `retention_days` (from the options, or the `run_log`
  setting), at most #{@prune_batch_size} runs' worth per call. Returns the number of runs
  whose lines were removed. Called by the job engine on every run when run details are
  enabled.
  """
  def prune(%JobConfig{} = job_config, opts \\ []) do
    days =
      Keyword.get(opts, :retention_days, Keyword.fetch!(Bildad.Config.run_log(), :retention_days))

    cutoff =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-days * 86_400, :second)
      |> NaiveDateTime.truncate(:second)

    ids =
      from(d in JobRunDetail,
        where: d.log_tail_at < ^cutoff,
        select: d.id,
        limit: @prune_batch_size
      )
      |> job_config.repo.all()

    if ids == [] do
      0
    else
      {count, _} =
        from(d in JobRunDetail, where: d.id in ^ids)
        |> job_config.repo.update_all(
          set: [
            log_tail: nil,
            log_tail_at: nil,
            log_tail_lines: nil,
            log_tail_dropped: nil,
            updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
          ]
        )

      count
    end
  end

  # -- used by the job engine --

  @doc false
  # In the job process, before the job runs: start keeping its lines.
  def start_capture(%Bildad.RunState{run_log?: true}) do
    Process.put(Handler.buffer_key(), {:queue.new(), 0, 0})
    :ok
  end

  def start_capture(_run_state), do: :ok

  @doc false
  # In the job process, once the outcome is known: save the lines of a failed run; a
  # succeeded run saves nothing. Best-effort.
  def finish_capture(%Bildad.RunState{run_log?: true} = run_state, failed?) do
    case Process.delete(Handler.buffer_key()) do
      {_, _, _} = buffer when failed? ->
        save(run_state.repo, run_state.identity.job_run_id, buffer)

      _ ->
        :ok
    end
  end

  def finish_capture(_run_state, _failed?), do: :ok

  @doc false
  # The buffer of a job process on this node (for the JobKiller, before it kills it).
  def read_buffer(pid) do
    case :erlang.process_info(pid, {:dictionary, Handler.buffer_key()}) do
      {_, {_, _, _} = buffer} -> buffer
      _ -> nil
    end
  rescue
    # Reading one key of another process's dictionary needs OTP 26.2; before that, read it
    # all (only at a kill or a stop, so rarely).
    ArgumentError -> read_whole_dictionary(pid)
  end

  defp read_whole_dictionary(pid) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {_, {_, _, _} = buffer} <- List.keyfind(dictionary, Handler.buffer_key(), 0) do
      buffer
    else
      _ -> nil
    end
  end

  @doc false
  # Nothing to save: no line was kept (none logged, all dropped, or no handler attached).
  def save(_repo, _job_run_id, {_lines, 0, _dropped}), do: :ok

  def save(repo, job_run_id, {lines, count, dropped}) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    fields = [
      log_tail: lines |> :queue.to_list() |> Enum.join(@separator),
      log_tail_at: now,
      log_tail_lines: count,
      log_tail_dropped: dropped,
      updated_at: now
    ]

    # The row is normally there (created when the run started). If not, create it; if it
    # was created meanwhile, the insert does nothing and the update is tried again.
    with 0 <- update_log(repo, job_run_id, fields) do
      repo.insert(
        %JobRunDetail{job_run_id: job_run_id, node: to_string(node()), inserted_at: now},
        on_conflict: :nothing
      )

      update_log(repo, job_run_id, fields)
    end

    :ok
  rescue
    e ->
      Logger.error("Could not save the log of job run #{job_run_id}: #{Exception.message(e)}")
      {:error, :not_saved}
  end

  defp update_log(repo, job_run_id, fields) do
    {count, _} =
      from(d in JobRunDetail, where: d.job_run_id == ^job_run_id) |> repo.update_all(set: fields)

    count
  end
end
