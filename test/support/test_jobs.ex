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
end
