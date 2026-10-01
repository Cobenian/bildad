defmodule Bildad.RunLogTest do
  use Bildad.JobCase, async: false

  alias Bildad.RunLog

  defmodule LoggingRedactor do
    @moduledoc false
    require Logger

    def redact(message, _level) do
      Logger.warning("redacting a line")
      message
    end
  end

  defmodule DropAll do
    @moduledoc false
    def redact(_message, _level), do: :drop
  end

  defmodule Redactor do
    @moduledoc false
    def redact("line 2", _level), do: :drop
    def redact("line 3", _level), do: raise("redactor bug")
    def redact("line 4", _level), do: :not_a_binary
    def redact(message, _level), do: String.replace(message, "1", "[redacted]")
  end

  setup do
    put_bildad_env(:run_details, true)
    enable(enabled: true)
    :ok
  end

  defp enable(settings) do
    put_bildad_env(:run_log, settings)
    RunLog.detach()
    :ok = RunLog.attach()
    on_exit(fn -> RunLog.detach() end)
  end

  defp run(config, job, context \\ %{}) do
    {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config, context, job: job))
    await_done(job_run)
  end

  test "a failed run saves the lines its own process logged", %{config: config} do
    job_run = run(config, TestJobs.LogsThenFails)

    assert %{lines: lines, saved_at: %NaiveDateTime{}, dropped: 0} =
             RunLog.get(config, job_run.id)

    messages = Enum.map(lines, &(&1 |> String.split("] ", parts: 2) |> List.last()))
    assert Enum.take(messages, 3) == ["line 1", "line 2", "line 3"]
    assert "Error running job: :failed_on_purpose" in messages

    assert Enum.all?(lines, &(&1 =~ ~r/^\d{4}-\d\d-\d\dT\S+ \[(info|warning|error)\] /))
    assert Enum.any?(lines, &(&1 =~ ~r/\[error\] .*\n/s)), "a multi-line message is one line"
    refute Enum.any?(lines, &(&1 =~ "a debug line")), "below the level"
    refute Enum.any?(lines, &(&1 =~ "from a task")), "tasks are not captured"
    refute Enum.any?(lines, &(&1 =~ "context")), "the launch line is never kept"
  end

  test "a succeeded run saves nothing", %{config: config} do
    job_run = run(config, TestJobs.LogsThenSucceeds)
    assert RunLog.get(config, job_run.id) == nil
  end

  test "a run killed by the JobKiller saves its lines", %{config: config} do
    {:ok, job_run} =
      JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.LogsThenWaits))

    assert_receive {:started, worker}

    assert {:ok, [line]} = RunLog.tail(job_run.job_process_name)
    assert line =~ "[warning] working on it"

    JobEngine.kill_a_job(config, job_run)
    await_dead(worker)

    assert %{lines: [^line]} = RunLog.get(config, job_run.id)
  end

  test "an application stopping a job saves its lines with persist_local", %{config: config} do
    {:ok, job_run} =
      JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.LogsThenWaits))

    assert_receive {:started, worker}

    assert :ok = RunLog.persist_local(config, job_run)
    Process.exit(worker, :kill)
    await_dead(worker)

    assert %{lines: [line]} = RunLog.get(config, job_run.id)
    assert line =~ "working on it"
    assert RunLog.persist_local(config, job_run) == {:error, :not_running}
  end

  test "keeps at most max_lines, the newest, and counts the dropped", %{config: config} do
    enable(enabled: true, max_lines: 5)
    job_run = run(config, TestJobs.LogsThenFails, %{"n" => 20})

    assert %{lines: lines, dropped: dropped} = RunLog.get(config, job_run.id)
    assert length(lines) == 5
    assert dropped > 15
    assert Enum.any?(lines, &(&1 =~ "Error running job")), "the newest lines are kept"
  end

  test "cuts each line to max_line_bytes", %{config: config} do
    enable(enabled: true, max_line_bytes: 8)
    job_run = run(config, TestJobs.LogsThenFails, %{"n" => 1})

    assert %{lines: [first | _]} = RunLog.get(config, job_run.id)
    assert first |> String.split("] ", parts: 2) |> List.last() == "line 1"

    assert Enum.all?(
             RunLog.get(config, job_run.id).lines,
             &(byte_size(&1 |> String.split("] ", parts: 2) |> List.last()) <= 8)
           )
  end

  test "the redaction hook can change or drop lines, and fails closed", %{config: config} do
    enable(enabled: true, redact: {Redactor, :redact, []})
    job_run = run(config, TestJobs.LogsThenFails, %{"n" => 4})

    assert %{lines: lines, dropped: 3} = RunLog.get(config, job_run.id)
    messages = Enum.map(lines, &(&1 |> String.split("] ", parts: 2) |> List.last()))

    assert "line [redacted]" in messages
    refute Enum.any?(messages, &(&1 in ["line 2", "line 3", "line 4"]))
  end

  test "a redaction hook that logs does not recurse", %{config: config} do
    enable(enabled: true, redact: {LoggingRedactor, :redact, []})
    job_run = run(config, TestJobs.LogsThenFails)

    assert job_run.result == "FAILED"
    assert %{lines: lines} = RunLog.get(config, job_run.id)
    assert Enum.any?(lines, &(&1 =~ "line 1"))
    refute Enum.any?(lines, &(&1 =~ "redacting a line"))
  end

  test "a run whose every line was dropped saves nothing", %{config: config} do
    enable(enabled: true, redact: {DropAll, :redact, []})
    job_run = run(config, TestJobs.LogsThenFails)
    assert RunLog.get(config, job_run.id) == nil
  end

  test "with the run log off nothing is captured", %{config: config} do
    put_bildad_env(:run_log, enabled: false)

    {:ok, job_run} =
      JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.LogsThenWaits))

    assert_receive {:started, worker}
    assert RunLog.tail(job_run.job_process_name) == {:error, :not_running}
    send(worker, :finish)
    await_done(job_run)

    job_run = run(config, TestJobs.LogsThenFails)
    assert RunLog.get(config, job_run.id) == nil
  end

  test "with the handler detached nothing is saved", %{config: config} do
    RunLog.detach()
    job_run = run(config, TestJobs.LogsThenFails)
    assert RunLog.get(config, job_run.id) == nil
  end

  describe "retention" do
    test "prune removes only saved lines older than the retention", %{config: config} do
      old = run(config, TestJobs.LogsThenFails)
      recent = run(config, TestJobs.LogsThenFails)

      Repo.update_all(
        from(d in JobRunDetail, where: d.job_run_id == ^old.id),
        set: [log_tail_at: ~N[2020-01-01 00:00:00]]
      )

      assert RunLog.prune(config, retention_days: 14) == 1
      assert RunLog.get(config, old.id) == nil
      assert %{lines: [_ | _]} = RunLog.get(config, recent.id)
      assert RunLog.prune(config, retention_days: 14) == 0

      assert %JobRunDetail{log_tail_at: nil, log_tail_lines: nil, log_tail_dropped: nil} =
               Repo.get_by!(JobRunDetail, job_run_id: old.id)
    end

    test "the job engine prunes, also with the run log turned off", %{config: config} do
      old = run(config, TestJobs.LogsThenFails)

      Repo.update_all(
        from(d in JobRunDetail, where: d.job_run_id == ^old.id),
        set: [log_tail_at: ~N[2020-01-01 00:00:00]]
      )

      put_bildad_env(:run_log, enabled: false)
      JobEngine.run_job_engine(config)
      assert RunLog.get(config, old.id) == nil
    end
  end
end
