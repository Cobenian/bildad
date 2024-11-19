defmodule Bildad do
  @moduledoc """
  This module contains documentation for the Bildad Jobs Framework.

  This framework has a queue (with priority) and it can work across multiple nodes.

  > **NOTE**: THIS FRAMEWORK DOES NOT GUARANTEE EXACTLY ONCE DELIVERY.

  IF YOU ARE LOOKING FOR A JOB SCHEDULING FRAMEWORK THAT GUARAENTEES EXACTLY ONCE DELIVERY, THIS IS NOT IT.
  THIS FRAMEWORK ALSO DOES NOT GUARANTEE THAT A JOB WILL RUN EXACTLY ONE TIME.

  This framework is intended to only for jobs that are Elixir code and that will be running in a group of nodes
  that are NOT connected. 

  ## Database

  Bildad uses the following tables in the database:

  * `Job templates` are the definition of the jobs that are available to run. They contain the name of the Elixir 
  module to run and they contain a json schema to validate the job context when a job is run. Job templates are 
  created by the application and are used to create job queue entries when it is time to run a job.

  * `Job queue entries` are the jobs that should be run. They have a status of available or running. They are 
  created by the application and are run by the job engine. If the job completes successfully the job queue entry is
  deleted. If the job fails it will be retried up to the number of max retries specified in the queue entry. Once
  the maximum number of retries is reached the entry is deleted from the queue.

  * `Job runs` are the occurances of a job that have run or are running. They are created by the job engine when 
  it picks up an entry from the queue and tries to run it. Job runs may be successful or failed. Job runs are
  not deleted from the database when they are done to serve as a history of what has run.

  ## Modules

  The `Bildad.Job.JobConfig` module is responsible for holding the configuration of the job scheduling framework. 
  It holds the module for the database repository and other internal configuration values.

  The `Bildad.Job.Jobs` module is responsible for querying for job templates, job queue entries, and job runs.
  It also has functions for creating, updating, and deleting job templates.

  The `Bildad.Job.JobEngine` module is responsible for running jobs. Jobs are enqueued in the job queue by the application
  and then run by the job engine. This module also expires jobs that have timed out and are not running on any nodes.
  This is meant to be run on a single node at a time (the framework does NOT guarantee this). 
  A load balancer can be used to send requests to balance the load across multiple nodes.

  The `Bildad.Job.JobKiller` module is responsible for killing jobs that have run too long. It runs on each node.
  This module is configured to run under a supervision tree, you do not need to programmatically call it.

  ## Error Handling

  Bildad has built in retries for jobs that fail.

  There are three primary types of error handling in Bildad:

  * Jobs that fail are immediately marked as failed run in the `job_runs` table. If it is the last retry 
  then the job is removed from the queue. If it is not the last retry then the queue entry is updated to 
  be available.
  * Jobs that run past their timeout are killed by the `JobKiller` module ON THE NODE RUNNING THE JOB. 
  The job is marked as failed in the `job_runs` table. If it is not the last retry then the queue entry 
  is updated to be available. If it is the last retry then the job is removed from the queue.
  * Jobs that fail and are no longer running on any node (so they cannot be killed) are marked as failed 
  in the `job_runs` table after the expiration date. 

  ## Name
  Why the name Bildad? Bildad is a character from the Bible. He was one of Job's friends.

  See the `README.md` for more information.
  """
end
