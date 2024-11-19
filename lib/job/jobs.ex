defmodule Bildad.Job.Jobs do
  @moduledoc """
  The Jobs module is responsible for managing job templates, job queue entries, and job runs.
  """

  alias Bildad.Job.JobTemplates
  alias Bildad.Job.JobQueueEntries
  alias Bildad.Job.JobRuns

  defdelegate list_job_templates(job_config), to: JobTemplates
  defdelegate list_job_templates(job_config, page, limit \\ nil), to: JobTemplates
  defdelegate list_all_job_templates(job_config), to: JobTemplates
  defdelegate list_all_job_templates(job_config, page, limit \\ nil), to: JobTemplates
  defdelegate list_active_job_templates(job_config), to: JobTemplates
  defdelegate list_active_job_templates(job_config, page, limit \\ nil), to: JobTemplates
  defdelegate list_inactive_job_templates(job_config), to: JobTemplates
  defdelegate list_inactive_job_templates(job_config, page, limit \\ nil), to: JobTemplates
  defdelegate create_job_template(job_config, job_template_params), to: JobTemplates
  defdelegate update_job_template(job_config, job_template, job_template_params), to: JobTemplates
  defdelegate delete_job_template(job_config, job_template), to: JobTemplates

  defdelegate list_job_runs_for_identifier(job_config, job_run_identifier), to: JobRuns
  defdelegate list_job_runs_to_kill(job_config), to: JobRuns
  defdelegate list_job_runs_to_kill(job_config, page, limit \\ nil), to: JobRuns
  defdelegate list_expired_jobs(job_config), to: JobRuns
  defdelegate list_expired_jobs(job_config, page, limit \\ nil), to: JobRuns
  defdelegate list_job_runs_for_result(job_config, result), to: JobRuns
  defdelegate list_job_runs_for_result(job_config, result, page, limit \\ nil), to: JobRuns
  defdelegate list_all_job_runs(job_config, page, limit \\ nil), to: JobRuns
  defdelegate get_number_of_job_runs(job_config), to: JobRuns

  defdelegate get_job_queue_entry_for_identifier(job_config, job_run_identifier),
    to: JobQueueEntries

  defdelegate list_jobs_to_run_in_the_queue(job_config), to: JobQueueEntries
  defdelegate list_jobs_to_run_in_the_queue(job_config, page, limit \\ nil), to: JobQueueEntries
  defdelegate list_running_jobs_in_the_queue(job_config), to: JobQueueEntries
  defdelegate list_running_jobs_in_the_queue(job_config, page, limit \\ nil), to: JobQueueEntries
  defdelegate list_jobs_for_status_in_the_queue(job_config, status), to: JobQueueEntries

  defdelegate list_jobs_for_status_in_the_queue(job_config, status, page, limit \\ nil),
    to: JobQueueEntries

  defdelegate list_all_jobs_in_the_queue(job_config), to: JobQueueEntries
  defdelegate list_all_jobs_in_the_queue(job_config, page, limit \\ nil), to: JobQueueEntries

  defdelegate get_number_of_jobs_in_the_queue(job_config), to: JobQueueEntries

  defdelegate get_queue_position_for_job_run_identifier(job_config, job_run_identifier),
    to: JobQueueEntries
end
