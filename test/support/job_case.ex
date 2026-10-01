defmodule Bildad.JobCase do
  @moduledoc false
  # Helpers shared by the engine tests. Not async: jobs run in their own processes against a
  # shared database, and some tests change application config.

  use ExUnit.CaseTemplate

  import Ecto.Query

  alias Bildad.Job.{JobConfig, JobEngine, JobRun, JobTemplate}
  alias Bildad.TestRepo, as: Repo

  using do
    quote do
      import Bildad.JobCase
      alias Bildad.Job.{JobConfig, JobEngine, JobQueueEntry, JobRun, JobRunDetail, JobTemplate}
      alias Bildad.TestJobs
      alias Bildad.TestRepo, as: Repo
    end
  end

  setup do
    # Deleting the templates cascades to their queue entries, job runs and details.
    Repo.delete_all(JobTemplate)
    Process.register(self(), :bildad_test)
    %{config: JobConfig.new(Repo)}
  end

  @doc "Sets :bildad application env for the test, restoring it afterwards."
  def put_bildad_env(key, value) do
    previous = Application.fetch_env(:bildad, key)
    Application.put_env(:bildad, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:bildad, key, v)
        :error -> Application.delete_env(:bildad, key)
      end
    end)
  end

  @doc "Sends every given telemetry event to the test process as {:telemetry, event, m, md}."
  def capture_telemetry(events) do
    id = "test-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach_many(
      id,
      Enum.map(events, &[:bildad, :job, &1]),
      fn [:bildad, :job, event], measurements, metadata, _ ->
        send(test, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end

  def enqueue(config, context \\ %{}, opts \\ []) do
    template =
      Repo.insert!(%JobTemplate{
        name: "Test job",
        code: "TEST_#{System.unique_integer([:positive])}",
        active: true,
        display_order: 1,
        job_module_name: Atom.to_string(Keyword.get(opts, :job, Bildad.TestJobs.Blocking)),
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

  def runs_for(entry) do
    Repo.all(from(r in JobRun, where: r.job_run_identifier == ^entry.job_run_identifier))
  end

  # A RUNNING job run for the entry, as run_a_job leaves it just before the launch.
  def running_job_run(entry) do
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

  # Waits for the run to be finished and for its process to be gone, so nothing from this
  # test is still using the database when the next one starts.
  def await_done(job_run, tries \\ 250)

  def await_done(job_run, 0), do: flunk("job run #{job_run.id} did not finish")

  def await_done(job_run, tries) do
    case Repo.get!(JobRun, job_run.id) do
      %JobRun{status: "DONE"} = done ->
        if pid = JobEngine.find_elixir_process(job_run), do: await_dead(pid)
        done

      _ ->
        Process.sleep(20)
        await_done(job_run, tries - 1)
    end
  end

  def await_dead(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5_000 -> flunk("process #{inspect(pid)} did not exit")
    end
  end
end
