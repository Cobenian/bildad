defmodule Bildad.Application do
  @moduledoc """
  Starts `Bildad.JobRegistry`, the registry that job processes register themselves in, and
  the process that writes job run details (idle unless they are enabled; see
  `Bildad.Config`).

  A job process is registered under its job run's `job_process_name`, a string, so no atom
  is created per job run. The registry is local to each node, like the job processes.

  This application starts automatically when Bildad is a runtime dependency of the host
  application (the default). A host that lists Bildad with `runtime: false` or under
  `included_applications` must start `{Registry, keys: :unique, name: Bildad.JobRegistry}`
  (and, to use run details, `Bildad.RunDetails.Writer`) in its own supervision tree, and
  call `Bildad.RunLog.attach/0` to use the run log.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Bildad.JobRegistry},
      # Under its own supervisor, and temporary: if the writer keeps failing it is given up,
      # and that can never restart the registry (and so stop every running job).
      %{
        id: Bildad.RunDetails.Supervisor,
        type: :supervisor,
        restart: :temporary,
        start:
          {Supervisor, :start_link,
           [
             [Bildad.RunDetails.Writer],
             [strategy: :one_for_one, max_restarts: 10, max_seconds: 60]
           ]}
      }
    ]

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Bildad.Supervisor) do
      if Bildad.Config.run_log?(), do: Bildad.RunLog.attach()
      {:ok, pid}
    end
  end

  @impl true
  def stop(_state) do
    Bildad.RunLog.detach()
    :ok
  end
end
