defmodule Bildad.ProgressTest do
  use Bildad.JobCase, async: false

  describe "job identity" do
    test "is available in the job and in tasks it starts, without the job context",
         %{config: config} do
      entry = enqueue(config, %{"n" => 1}, job: TestJobs.Progresses)
      {:ok, job_run} = JobEngine.run_a_job(config, entry)

      assert_receive {:current_job, identity}
      assert_receive {:task_current_job, ^identity}
      await_done(job_run)

      assert identity == %{
               job_run_id: job_run.id,
               job_run_identifier: job_run.job_run_identifier,
               job_template_id: job_run.job_template_id,
               job_template_code: Repo.get!(JobTemplate, job_run.job_template_id).code,
               job_module: TestJobs.Progresses,
               retry: 0,
               node: node()
             }
    end

    test "is nil outside a job, and progress and stream say so" do
      assert Bildad.current_job() == nil
      assert Bildad.progress(0.5, "x") == {:error, :not_in_a_job}
      assert Bildad.stream("x") == {:error, :not_in_a_job}
    end
  end

  describe "progress" do
    test "emits telemetry, throttled per run, always passing a fraction of 1",
         %{config: config} do
      put_bildad_env(:progress_interval_ms, 60_000)
      capture_telemetry([:progress])

      {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.Progresses))
      await_done(job_run)

      # 0.1 is the first update of the run and is sent; 0.2, 0.3 and the task's 0.5 fall
      # inside the interval and are dropped; 1.0 always passes.
      assert_received {:telemetry, :progress, %{fraction: 0.1}, %{message: "a"} = first}
      assert first.job_run_id == job_run.id
      assert_received {:telemetry, :progress, %{fraction: 1.0}, %{message: "done"}}
      refute_received {:telemetry, :progress, _, _}
    end

    test "with an interval of 0 every update is sent, including from a task",
         %{config: config} do
      put_bildad_env(:progress_interval_ms, 0)
      capture_telemetry([:progress])

      {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.Progresses))
      await_done(job_run)

      messages =
        for _ <- 1..5 do
          assert_receive {:telemetry, :progress, _, %{message: message}}
          message
        end

      assert messages == ["a", "b", "c", "from a task", "done"]
    end

    test "clamps the fraction, accepts no fraction, cuts the message" do
      capture_telemetry([:progress])

      state = %{
        Bildad.RunState.new(Repo, %JobRun{
          id: 1,
          job_run_identifier: "x",
          job_template_id: 1,
          job_template: %JobTemplate{code: "X", job_module_name: "Elixir.X"},
          retry: 0
        })
        | progress_interval_ms: 0
      }

      Bildad.RunState.put(state)

      assert :ok = Bildad.progress(7, String.duplicate("é", 300))
      assert_received {:telemetry, :progress, %{fraction: 1.0}, %{message: message}}
      assert String.length(message) == 255

      assert :ok = Bildad.progress(nil, nil)
      assert_received {:telemetry, :progress, measurements, %{fraction: nil, message: nil}}
      assert measurements == %{}

      assert :ok = Bildad.progress(-1, :not_a_string)
      assert_received {:telemetry, :progress, %{fraction: 0.0}, %{message: ":not_a_string"}}
    after
      Process.delete(:"$bildad_job")
    end
  end

  test "stream emits each chunk", %{config: config} do
    capture_telemetry([:stream])
    {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.Streams))
    await_done(job_run)

    assert_received {:telemetry, :stream, %{bytes: 5}, %{chunk: "hello", job_run_id: id}}
    assert id == job_run.id
  end

  describe "start, stop and exception events" do
    test "a job that succeeds: start, then stop after the run is recorded", %{config: config} do
      test = self()

      :telemetry.attach(
        "stop-reads-run",
        [:bildad, :job, :stop],
        fn _, _, metadata, _ ->
          send(test, {:status_at_stop, Repo.get!(JobRun, metadata.job_run_id).status})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("stop-reads-run") end)
      capture_telemetry([:start, :stop, :exception])

      {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.Instant))
      await_done(job_run)

      assert_received {:telemetry, :start, %{system_time: _}, %{job_run_id: id}}
      assert id == job_run.id
      assert_received {:telemetry, :stop, %{duration: d}, %{result: :succeeded, error: nil}}
      assert d >= 0
      assert_received {:status_at_stop, "DONE"}
      refute_received {:telemetry, :exception, _, _}
    end

    test "a job that returns an error: stop with the error", %{config: config} do
      capture_telemetry([:stop, :exception])

      {:ok, job_run} =
        JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.ReturnsError))

      await_done(job_run)

      assert_received {:telemetry, :stop, _, %{result: :failed, error: :nope}}
      refute_received {:telemetry, :exception, _, _}
    end

    for {job, kind} <- [
          {TestJobs.Raises, :error},
          {TestJobs.Exits, :exit},
          {TestJobs.Throws, :throw}
        ] do
      @job job
      @kind kind
      test "a job that ends with #{kind}: exception, no stop", %{config: config} do
        capture_telemetry([:stop, :exception])
        {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config, %{}, job: @job))
        await_done(job_run)

        assert_received {:telemetry, :exception, %{duration: _}, %{kind: @kind} = metadata}
        assert is_list(metadata.stacktrace)
        refute_received {:telemetry, :stop, _, _}
      end
    end

    test "metadata never contains the job context", %{config: config} do
      capture_telemetry([:start, :stop])
      entry = enqueue(config, %{"n" => 42}, job: TestJobs.Instant)
      {:ok, job_run} = JobEngine.run_a_job(config, entry)
      await_done(job_run)

      assert_received {:telemetry, :start, _, start}
      assert_received {:telemetry, :stop, _, stop}
      refute Map.has_key?(start, :job_context)
      refute Map.has_key?(stop, :job_context)
    end
  end

  describe "runs finished by someone other than the job" do
    test "a killed run emits :killed", %{config: config} do
      capture_telemetry([:killed])
      {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config))
      assert_receive {:started, worker}

      JobEngine.kill_a_job(config, job_run)
      await_dead(worker)

      assert_received {:telemetry, :killed, _, %{job_run_id: id, retry: 0}}
      assert id == job_run.id
    end

    test "an expired run emits :expired", %{config: config} do
      capture_telemetry([:expired])
      job_run = Repo.insert!(running_job_run(enqueue(config)))

      {:ok, _} = JobEngine.expire_a_job(config, job_run)
      assert_received {:telemetry, :expired, _, %{job_run_id: id}}
      assert id == job_run.id
    end

    test "a stopped run emits :stopped; stopping one not running emits nothing",
         %{config: config} do
      capture_telemetry([:stopped])
      entry = enqueue(config)
      {:ok, job_run} = JobEngine.run_a_job(config, entry)
      assert_receive {:started, worker}

      JobEngine.stop_job_in_queue(config, Repo.get!(JobQueueEntry, entry.id))
      assert_received {:telemetry, :stopped, _, %{job_run_id: id}}
      assert id == job_run.id

      JobEngine.stop_job_in_queue(config, Repo.get!(JobQueueEntry, entry.id))
      refute_received {:telemetry, :stopped, _, _}

      send(worker, :finish)
      await_dead(worker)
    end
  end

  describe "run details" do
    test "are not written unless enabled", %{config: config} do
      {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.Progresses))
      await_done(job_run)
      Bildad.RunDetails.Writer.flush()

      assert Repo.aggregate(JobRunDetail, :count) == 0
    end

    test "record the node and the latest progress of a running job", %{config: config} do
      put_bildad_env(:run_details, true)

      {:ok, job_run} =
        JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.ProgressesThenWaits))

      assert_receive {:started, worker}
      Bildad.RunDetails.Writer.flush()

      detail = Bildad.Job.Jobs.get_job_run_detail(config, job_run.id)
      assert detail.node == to_string(node())
      assert detail.progress == 0.4
      assert detail.progress_message == "scoring"
      assert detail.progress_at

      assert %{} = details = Bildad.Job.Jobs.list_job_run_details(config, [job_run.id, -1])
      assert Map.keys(details) == [job_run.id]

      send(worker, :finish)
      await_done(job_run)
    end

    test "a missing table does not stop jobs", %{config: config} do
      put_bildad_env(:run_details, true)
      Repo.query!("RENAME TABLE job_run_details TO job_run_details_away")
      on_exit(fn -> Repo.query!("RENAME TABLE job_run_details_away TO job_run_details") end)

      {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config, %{}, job: TestJobs.Progresses))
      assert await_done(job_run).result == "SUCCEEDED"
      Bildad.RunDetails.Writer.flush()
      assert Process.whereis(Bildad.RunDetails.Writer)
    end
  end

  describe "Bildad.PubSub" do
    setup do
      start_supervised!({Phoenix.PubSub, name: Bildad.TestPubSub})
      :ok
    end

    test "broadcasts job events without error terms", %{config: config} do
      put_bildad_env(:progress_interval_ms, 60_000)
      :ok = Bildad.PubSub.attach(Bildad.TestPubSub)
      on_exit(fn -> Bildad.PubSub.detach() end)
      assert {:error, :already_exists} = Bildad.PubSub.attach(Bildad.TestPubSub)

      entry = enqueue(config, %{}, job: TestJobs.ReturnsError)
      job_run = Repo.insert!(running_job_run(entry))
      Phoenix.PubSub.subscribe(Bildad.TestPubSub, "bildad:job:#{job_run.id}")

      {:ok, _} = JobEngine.launch_job_process(config, job_run)

      assert_receive {:bildad_job, :start, %{job_run_id: id}}
      assert id == job_run.id
      assert_receive {:bildad_job, :stop, %{result: :failed} = stop}
      refute Map.has_key?(stop, :error)
    end

    test "uses the given topic and can include error terms", %{config: config} do
      :ok =
        Bildad.PubSub.attach(Bildad.TestPubSub,
          id: :custom,
          topic: &"jobs:#{&1.job_run_identifier}",
          include_errors: true
        )

      on_exit(fn -> Bildad.PubSub.detach(:custom) end)

      entry = enqueue(config, %{}, job: TestJobs.ReturnsError)
      Phoenix.PubSub.subscribe(Bildad.TestPubSub, "jobs:#{entry.job_run_identifier}")
      {:ok, job_run} = JobEngine.run_a_job(config, entry)
      await_done(job_run)

      assert_receive {:bildad_job, :stop, %{error: :nope}}
    end
  end
end
