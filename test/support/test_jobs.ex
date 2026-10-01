defmodule Bildad.TestJobs do
  @moduledoc false
  # Job modules for the engine tests. Each reports to the test process, which registers
  # itself as :bildad_test, so a test can tell whether (and how often) a job ran.

  defmodule Instant do
    @moduledoc false
    # Returns at once, without reporting.
    def run_job(_job_context), do: {:ok, :done}
  end

  defmodule ReportsRegistration do
    @moduledoc false
    # Reports the names its process is registered under when the job starts.
    def run_job(_job_context) do
      send(:bildad_test, {:registered_as, Registry.keys(Bildad.JobRegistry, self())})
      {:ok, :done}
    end
  end

  defmodule Blocking do
    @moduledoc false
    # Waits until the test sends :finish to the job's process.
    def run_job(_job_context) do
      send(:bildad_test, {:started, self()})

      receive do
        :finish -> {:ok, :finished}
      end
    end
  end

  defmodule Exits do
    @moduledoc false
    def run_job(_job_context), do: exit(:boom)
  end

  defmodule ExitsNormally do
    @moduledoc false
    def run_job(_job_context), do: exit(:normal)
  end

  defmodule Throws do
    @moduledoc false
    def run_job(_job_context), do: throw(:boom)
  end

  defmodule FailsWithLongReason do
    @moduledoc false
    # Fails with a reason far longer than job_runs.reason, made of multi-byte characters.
    def run_job(_job_context), do: {:error, String.duplicate("é", 1_000)}
  end

  defmodule ExitsWithLinkedTask do
    @moduledoc false
    # Starts a linked process that never ends on its own, then exits.
    def run_job(_job_context) do
      linked = spawn_link(fn -> Process.sleep(:infinity) end)
      send(:bildad_test, {:linked, linked})
      exit(:boom)
    end
  end

  defmodule Controlled do
    @moduledoc false
    # Waits until the test says how to end: {:end_with, :ok | :throw}.
    def run_job(_job_context) do
      send(:bildad_test, {:started, self()})

      receive do
        {:end_with, :ok} -> {:ok, :finished}
        {:end_with, :throw} -> throw(:boom)
      end
    end
  end

  defmodule Progresses do
    @moduledoc false
    # Reports progress from its own process and from a task, then succeeds.
    def run_job(_job_context) do
      send(:bildad_test, {:current_job, Bildad.current_job()})

      for {fraction, message} <- [{0.1, "a"}, {0.2, "b"}, {0.3, "c"}] do
        :ok = Bildad.progress(fraction, message)
      end

      Task.async(fn ->
        send(:bildad_test, {:task_current_job, Bildad.current_job()})
        Bildad.progress(0.5, "from a task")
      end)
      |> Task.await()

      :ok = Bildad.progress(1, "done")
      {:ok, :done}
    end
  end

  defmodule ProgressesThenWaits do
    @moduledoc false
    # Reports progress, then waits until the test sends :finish.
    def run_job(_job_context) do
      :ok = Bildad.progress(0.4, "scoring")
      send(:bildad_test, {:started, self()})

      receive do
        :finish -> {:ok, :finished}
      end
    end
  end

  defmodule Streams do
    @moduledoc false
    def run_job(_job_context) do
      :ok = Bildad.stream(["hel", "lo"])
      {:ok, :done}
    end
  end

  defmodule Raises do
    @moduledoc false
    def run_job(_job_context), do: raise("boom")
  end

  defmodule ReturnsError do
    @moduledoc false
    def run_job(_job_context), do: {:error, :nope}
  end

  defmodule LogsThenFails do
    @moduledoc false
    # Logs "line 1" .. "line n" (n from the context, default 3), a debug line, then fails.
    require Logger

    def run_job(context) do
      for i <- 1..Map.get(context, "n", 3), do: Logger.info("line #{i}")
      Logger.debug("a debug line")
      Task.async(fn -> Logger.info("from a task") end) |> Task.await()
      {:error, :failed_on_purpose}
    end
  end

  defmodule LogsThenSucceeds do
    @moduledoc false
    require Logger

    def run_job(_context) do
      Logger.info("all good")
      {:ok, :done}
    end
  end

  defmodule LogsThenWaits do
    @moduledoc false
    # Logs a line, then waits until the test sends :finish.
    require Logger

    def run_job(_context) do
      Logger.warning("working on it")
      send(:bildad_test, {:started, self()})

      receive do
        :finish -> {:ok, :finished}
      end
    end
  end
end
