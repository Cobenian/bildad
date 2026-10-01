defmodule Bildad.IntrospectTest do
  use Bildad.JobCase, async: false

  alias Bildad.Introspect

  @whitelist [
    :current_function,
    :current_stacktrace,
    :memory,
    :message_queue_len,
    :reductions,
    :status,
    :node
  ]

  test "info returns exactly the whitelisted fields of a running job", %{config: config} do
    {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config, %{"n" => 1}))
    assert_receive {:started, worker}
    send(worker, :not_finish_yet)

    assert {:ok, info} = Introspect.info(job_run.job_process_name)
    assert Enum.sort(Map.keys(info)) == Enum.sort(@whitelist)
    assert info.node == node()
    assert info.message_queue_len >= 0
    assert is_integer(info.memory) and is_integer(info.reductions)
    assert {_m, _f, _a} = info.current_function

    assert Enum.all?(info.current_stacktrace, fn {m, f, a, location} ->
             is_atom(m) and is_atom(f) and is_integer(a) and is_list(location)
           end),
           "frames carry arities, never arguments"

    send(worker, :finish)
    await_done(job_run)
    assert Introspect.info(job_run.job_process_name) == {:error, :not_running}
  end

  test "info of a name that is not running" do
    assert Introspect.info("no-such-job") == {:error, :not_running}
  end

  describe "remote_info" do
    test "on this node, by atom or by name, answers locally", %{config: config} do
      {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config))
      assert_receive {:started, worker}

      assert {:ok, %{node: node}} = Introspect.remote_info(node(), job_run.job_process_name)
      assert node == node()

      assert {:ok, _} = Introspect.remote_info(to_string(node()), job_run.job_process_name)

      send(worker, :finish)
      await_done(job_run)
    end

    test "never creates an atom for an unknown node name" do
      name = "never-seen-#{System.unique_integer([:positive])}@nowhere"
      assert Introspect.remote_info(name, "x") == {:error, :unknown_node}
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "another node, when this node is not distributed" do
      refute Node.alive?()
      assert Introspect.remote_info(:other@host, "x") == {:error, :not_distributed}
    end
  end

  describe "run_info" do
    test "uses the node recorded in the run's details", %{config: config} do
      put_bildad_env(:run_details, true)
      {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config))
      assert_receive {:started, worker}
      Bildad.RunDetails.Writer.flush()

      assert {:ok, %{node: node}} = Introspect.run_info(config, job_run)
      assert node == node()

      send(worker, :finish)
      await_done(job_run)
    end

    test "without details", %{config: config} do
      {:ok, job_run} = JobEngine.run_a_job(config, enqueue(config))
      assert_receive {:started, worker}

      assert Introspect.run_info(config, job_run) == {:error, :no_details}

      send(worker, :finish)
      await_done(job_run)
    end
  end
end
