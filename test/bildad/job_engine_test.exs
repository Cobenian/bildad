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

  defp enqueue(config, context \\ %{}, opts \\ []) do
    template =
      Repo.insert!(%JobTemplate{
        name: "Blocking",
        code: "TEST_#{System.unique_integer([:positive])}",
        active: true,
        display_order: 1,
        job_module_name: Atom.to_string(TestJobs.Blocking),
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
