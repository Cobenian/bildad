# Bildad

Framework for running async jobs in an Elixir LiveView application.

Bildad is designed to run in a cluster of nodes that are NOT connected but share the same database.

A JobKiller application runs on each node looking for jobs to kill on that node.

A controller listens for requests to run the engine so that jobs will be started on ONE node.

Jobs that time out will eventually be killed. Jobs that die but are not killed will be expired.

A message with a configurable number of retires is put in the job queue to run a job. When the job is completed, killed or expired it is removed from the queue table. Entries in the queue can have the following status:

* AVAILABLE
* RUNNING

After the maximum number of retires messages are removed from the jobs queue.

Each run of a job in the message queue is stored in the `job runs` table. It contains the retry number and information about how long the job took along with the following:

* status (RUNNING, DONE)
* result (SUCCEEDED, FAILED)
* reason (text description of why a run failed)

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `bildad` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:bildad, "~> 0.1.0"}
  ]
end
```

Run the mix task to install the necessary migration and controller.

```bash
mix bildad.install
```

Follow the instructions for modifying the `router.ex` file.

```elixir
post "/jobs/engine/run", Jobs.JobsController, :run_job_engine
```

Follow the instructions for modifying the `application.ex` file.

```elixir
{Bildad.Job.JobKiller, repo: MyApp.Repo, check_time_in_seconds: 20},
```

> [!NOTE]
> You must call the run_job_engine periodically (via cron for example).

You must also create Job Templates for the jobs that you plan on running. They must 
contain the string version of the Elixir module to run and a JSON schema definition
so that the job context can be validated before a job is run.

## Architecture

* a database that works with Ecto
* a phoenix controller that listens for requests and runs the job engine
* a cron job to periodically run the jobs engine
  * the request will only hit one server and the engine will run on that node
* a job engine that runs on one node at a time
  * this expires old jobs that have all timed out and cannot be killed on any node
  * this runs new jobs in the queue that are available to run
* a job killer task that is run on each node
* custom jobs that have a `run_job` function that takes the job context
* job templates that know the module name and have the schema for the job context

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/bildad>.
