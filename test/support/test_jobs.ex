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
end
