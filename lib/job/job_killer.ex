defmodule Bildad.Job.JobKiller do
  use Task, restart: :permanent

  require Logger

  alias Bildad.Job.JobConfig
  alias Bildad.Job.Jobs
  alias Bildad.Job.JobEngine

  def start_link(opts) do
    Logger.warning("start link called for JobKiller #{inspect(opts)}")
    Task.start_link(__MODULE__, :run, [opts[:check_time_in_seconds]])
  end

  def run(check_time_in_seconds) do
    Logger.warning("init called for JobKiller #{inspect(check_time_in_seconds)}")
    seconds = check_time_in_seconds || 60
    Process.sleep(1000 * seconds)
    Logger.warning("yawn, JobKiller woke up from a nice nap")
    job_config = get_job_config()
    job_runs_to_kill = Jobs.list_job_runs_to_kill(job_config)
    Logger.warning("jobs_to_kill: #{inspect(Enum.count(job_runs_to_kill))}")

    job_runs_to_kill
    |> Enum.map(fn job_run_to_kill ->
      Logger.warning("time to kill a job #{inspect(job_run_to_kill, pretty: true)}")
      r = JobEngine.kill_a_job(job_config, job_run_to_kill)
      Logger.info("killed a job: #{inspect(r)}")
      Logger.warning("killed a job")
    end)

    Logger.warning("all done!")
  end

  # impl

  def get_job_config() do
    JobConfig.new(Searchlink.Repo)
  end
end
