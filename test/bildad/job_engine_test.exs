defmodule Bildad.Job.JobEngineTest do
  # Not async: the jobs run in their own processes against a shared database.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Bildad.Job.{JobConfig, JobEngine, JobQueueEntry, JobRun, JobTemplate}
  alias Bildad.TestJobs
  alias Bildad.TestRepo, as: Repo

  setup do
    # Deleting the templates cascades to their queue entries and job runs.
    Repo.delete_all(JobTemplate)
    Process.register(self(), :bildad_test)
    %{config: JobConfig.new(Repo)}
  end

  describe "claiming a queue entry" do
    test "concurrent run_a_job calls on one entry run it exactly once", %{config: config} do
      entry = enqueue(config)

      results =
        1..10
        |> Enum.map(fn _ -> Task.async(fn -> JobEngine.run_a_job(config, entry) end) end)
        |> Task.await_many(10_000)

      assert_receive {:started, worker}
      refute_receive {:started, _}, 200

      assert [{:ok, job_run}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert Enum.count(results, &(&1 == {:error, :job_not_available})) == 9
      assert length(runs_for(entry)) == 1

      send(worker, :finish)
      assert await_done(job_run).result == "SUCCEEDED"
    end

    test "a stale struct for an entry that is already running does not run it again",
         %{config: config} do
      entry = enqueue(config)

      {:ok, job_run} = JobEngine.run_a_job(config, entry)
      assert_receive {:started, worker}

      # `entry` is the struct from before the job started, as a caller holding an old copy
      # would have it.
      assert {:error, :job_not_available} = JobEngine.run_a_job(config, entry)
      refute_receive {:started, _}, 200
      assert length(runs_for(entry)) == 1

      send(worker, :finish)
      assert await_done(job_run).result == "SUCCEEDED"
    end
  end

  describe "a job context that fails the template's schema" do
    test "is not launched, is recorded as failed once and leaves the queue", %{config: config} do
      entry = enqueue(config, %{"n" => "not an integer"}, max_retries: 3)

      assert {:error, {:invalid_job_context, job_run}} = JobEngine.run_a_job(config, entry)

      refute_receive {:started, _}, 200

      job_run = Repo.get!(JobRun, job_run.id)
      assert job_run.status == "DONE"
      assert job_run.result == "FAILED"
      assert job_run.reason =~ "Invalid job context"
      assert job_run.ended_at

      assert is_nil(Repo.get(JobQueueEntry, entry.id)),
             "the same context fails every time, so it is not re-queued whatever max_retries is"

      assert length(runs_for(entry)) == 1
      assert JobEngine.run_job_engine(config).start == []
      refute_receive {:started, _}, 200
    end
  end

  describe "job run expiry" do
    test "a launched run expires 2 days after it starts", %{config: config} do
      {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.Instant))
      await_done(job_run)

      job_run = Repo.get!(JobRun, job_run.id)
      assert NaiveDateTime.diff(job_run.expires_at, job_run.started_at, :day) == 2
    end

    test "a run whose context fails the schema also expires 2 days after it starts", %{
      config: config
    } do
      entry = enqueue(config, %{"n" => "not an integer"})
      assert {:error, {:invalid_job_context, job_run}} = JobEngine.run_a_job(config, entry)

      job_run = Repo.get!(JobRun, job_run.id)
      assert NaiveDateTime.diff(job_run.expires_at, job_run.started_at, :day) == 2
    end

    test "job_run_expiry_in_days in the config is honoured", %{config: config} do
      config = %{config | job_run_expiry_in_days: 5}
      {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.Instant))
      await_done(job_run)

      job_run = Repo.get!(JobRun, job_run.id)
      assert NaiveDateTime.diff(job_run.expires_at, job_run.started_at, :day) == 5
    end
  end

  describe "launching a job process" do
    # A guard rather than a reproduction: the old race was a window of microseconds.
    test "a job that finishes at once is launched every time", %{config: config} do
      job_runs =
        for _ <- 1..50 do
          assert {:ok, job_run} =
                   JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.Instant))

          job_run
        end

      assert Enum.all?(job_runs, &(await_done(&1).result == "SUCCEEDED"))

      assert {:messages, []} = Process.info(self(), :messages),
             "the launch leaves nothing behind in the caller's mailbox"
    end

    test "the job process is registered under its name before the job starts",
         %{config: config} do
      entry = enqueue(config, %{}, job: TestJobs.ReportsRegistration)

      {:ok, job_run} = JobEngine.run_a_job(config, entry)

      assert_receive {:registered_as, names}
      assert names == [job_run.job_process_name]
      assert await_done(job_run).result == "SUCCEEDED"
    end

    test "a process that cannot register does not run the job and fails the run",
         %{config: config} do
      entry = enqueue(config)
      job_run = Repo.insert!(running_job_run(entry))

      # The name is taken, so the new process cannot register under it.
      {:ok, _} = Registry.register(Bildad.JobRegistry, job_run.job_process_name, nil)

      assert {:error, {:not_launched, _reason}} = JobEngine.launch_job_process(config, job_run)
      refute_receive {:started, _}, 200

      assert %JobRun{status: "DONE", result: "FAILED", reason: reason} =
               Repo.get!(JobRun, job_run.id)

      assert reason =~ "not_launched"
      assert {:messages, []} = Process.info(self(), :messages)
    end

    test "does not create an atom per job run", %{config: config} do
      run_instant_jobs(config, 5)
      atoms_before = :erlang.system_info(:atom_count)
      run_instant_jobs(config, 50)

      assert :erlang.system_info(:atom_count) - atoms_before < 5
    end

    test "a running job can be found by name and killed", %{config: config} do
      entry = enqueue(config)

      {:ok, job_run} = JobEngine.run_a_job(config, entry)
      assert_receive {:started, worker}

      assert JobEngine.find_elixir_process(job_run) == worker

      JobEngine.kill_a_job(config, job_run)
      await_dead(worker)

      assert %JobRun{status: "DONE", result: "FAILED", reason: "Timeout"} =
               Repo.get!(JobRun, job_run.id)

      assert is_nil(JobEngine.find_elixir_process(job_run))
    end
  end

  # A RUNNING job run for the entry, as run_a_job leaves it just before the launch.
  defp running_job_run(entry) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %JobRun{
      job_queue_entry_id: entry.id,
      job_run_identifier: entry.job_run_identifier,
      job_template_id: entry.job_template_id,
      retry: 0,
      job_process_name: Ecto.UUID.generate(),
      status: "RUNNING",
      started_at: now,
      timeout_at: NaiveDateTime.add(now, 5, :minute),
      expires_at: NaiveDateTime.add(now, 2, :day),
      job_context: %{}
    }
  end

  defp run_instant_jobs(config, count) do
    for _ <- 1..count do
      {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.Instant))
      await_done(job_run)
    end
  end

  defp enqueue(config, context \\ %{}, opts \\ []) do
    template =
      Repo.insert!(%JobTemplate{
        name: "Test job",
        code: "TEST_#{System.unique_integer([:positive])}",
        active: true,
        display_order: 1,
        job_module_name: Atom.to_string(Keyword.get(opts, :job, TestJobs.Blocking)),
        default_timeout_in_minutes: 5,
        default_max_retries: Keyword.get(opts, :max_retries, 0),
        job_context_schema: %{
          "type" => "object",
          "properties" => %{"n" => %{"type" => "integer"}}
        }
      })

    {:ok, entry} = JobEngine.enqueue_job(config, template, context)
    entry
  end

  defp runs_for(entry) do
    Repo.all(from(r in JobRun, where: r.job_run_identifier == ^entry.job_run_identifier))
  end

  # Waits for the run to be finished and for its process to be gone, so nothing from this
  # test is still using the database when the next one starts.
  defp await_done(job_run, tries \\ 250)

  defp await_done(job_run, 0), do: flunk("job run #{job_run.id} did not finish")

  defp await_done(job_run, tries) do
    case Repo.get!(JobRun, job_run.id) do
      %JobRun{status: "DONE"} = done ->
        if pid = JobEngine.find_elixir_process(job_run), do: await_dead(pid)
        done

      _ ->
        Process.sleep(20)
        await_done(job_run, tries - 1)
    end
  end

  defp await_dead(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5_000 -> flunk("process #{inspect(pid)} did not exit")
    end
  end
end
