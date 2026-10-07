defmodule Bildad.RunDetails.Writer do
  @moduledoc false
  # Writes job_run_details for the jobs running on this node, so that no such write ever
  # happens in a job's own process (where it would join the job's transactions, wait for a
  # pool connection, or raise in the job) or in the claim transaction (where a failure would
  # stop the job from starting).
  #
  # Jobs only touch a public ETS table: the latest progress of each run is one row, replaced
  # on every update. Every tick, rows are written and then deleted unless a newer update
  # replaced them meanwhile. Every write is best-effort: errors are logged (at most once a
  # minute), never raised.

  use GenServer

  import Ecto.Query

  require Logger

  alias Bildad.Job.JobRun
  alias Bildad.Job.JobRunDetail

  @table :bildad_run_details_progress
  @error_log_interval_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Asks for the run's details row to be created, recording the node. Never fails."
  def run_started(%Bildad.RunState{run_details?: true} = state) do
    GenServer.cast(__MODULE__, {:run_started, state.repo, state.identity})
  end

  def run_started(_state), do: :ok

  @doc "Stores the latest progress of the run, to be written on the next tick. Never fails."
  def progress(%Bildad.RunState{run_details?: true} = state, fraction, message) do
    :ets.insert(
      @table,
      {state.identity.job_run_id, {state.repo, state.running_status}, fraction, message, now()}
    )

    :ok
  rescue
    ArgumentError -> :ok
  end

  def progress(_state, _fraction, _message), do: :ok

  @doc """
  Writes the run's pending progress at once, without the check that the run is still
  running: called by the job process once its outcome is recorded, so the last update of a
  job that ends before the next tick is not lost. Never fails.
  """
  def run_finished(%Bildad.RunState{run_details?: true} = state) do
    GenServer.cast(__MODULE__, {:run_finished, state.identity.job_run_id})
  end

  def run_finished(_state), do: :ok

  @doc false
  # Writes pending progress now. For tests.
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    schedule_tick()
    {:ok, %{last_error_logged_at: nil}}
  end

  @impl true
  def handle_cast({:run_started, repo, identity}, state) do
    {:noreply, attempt(state, fn -> insert_detail(repo, identity.job_run_id, identity.node) end)}
  end

  def handle_cast({:run_finished, job_run_id}, state) do
    state =
      case :ets.take(@table, job_run_id) do
        [{^job_run_id, {repo, _running}, fraction, message, at}] ->
          attempt(state, fn -> update_progress(repo, job_run_id, nil, fraction, message, at) end)

        _ ->
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, write_progress(state)}

  @impl true
  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, write_progress(state)}
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, Bildad.Config.progress_persist_interval_ms())
  end

  defp write_progress(state) do
    @table
    |> :ets.tab2list()
    |> Enum.reduce(state, fn {job_run_id, {repo, running}, fraction, message, at} = row, state ->
      state =
        attempt(state, fn -> update_progress(repo, job_run_id, running, fraction, message, at) end)

      # Only this exact row: a newer update stored meanwhile is written on the next tick.
      :ets.delete_object(@table, row)
      state
    end)
  end

  defp insert_detail(repo, job_run_id, node, fields \\ []) do
    now = now()

    repo.insert(
      struct(
        JobRunDetail,
        [job_run_id: job_run_id, node: to_string(node), inserted_at: now, updated_at: now] ++
          fields
      ),
      on_conflict: :nothing
    )
  end

  # With a running status, only while the run still has it, so a late tick never touches a
  # finished run. Without (`nil`, when the job itself says it has finished), unconditionally.
  defp update_progress(repo, job_run_id, running, fraction, message, at) do
    fields = [progress: fraction, progress_message: message, progress_at: at]

    {count, _} =
      from(d in JobRunDetail, join: r in JobRun, on: r.id == d.job_run_id)
      |> where([d], d.job_run_id == ^job_run_id)
      |> still_running(running)
      |> repo.update_all(set: [updated_at: at] ++ fields)

    # No row yet (it could not be created when the run started): create it with the
    # progress, if the run qualifies.
    if count == 0 and
         repo.exists?(from(r in JobRun, where: r.id == ^job_run_id) |> run_still_running(running)) do
      insert_detail(repo, job_run_id, node(), fields)
    end
  end

  defp still_running(query, nil), do: query
  defp still_running(query, running), do: where(query, [_d, r], r.status == ^running)

  defp run_still_running(query, nil), do: query
  defp run_still_running(query, running), do: where(query, [r], r.status == ^running)

  defp attempt(state, fun) do
    fun.()
    state
  rescue
    e -> log_error(state, e)
  catch
    kind, reason -> log_error(state, {kind, reason})
  end

  defp log_error(state, error) do
    now = System.monotonic_time(:millisecond)

    if state.last_error_logged_at == nil or
         now - state.last_error_logged_at >= @error_log_interval_ms do
      Logger.error(
        ("Bildad could not write job run details (is the job_run_details migration from " <>
           "`mix bildad.gen.run_details_migration` applied?): " <>
           Exception.format_banner(:error, error))
        |> String.slice(0, 500)
      )

      %{state | last_error_logged_at: now}
    else
      state
    end
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
end
