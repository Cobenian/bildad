defmodule Bildad.Application do
  @moduledoc """
  Starts `Bildad.JobRegistry`, the registry that job processes register themselves in.

  A job process is registered under its job run's `job_process_name`, a string, so no atom
  is created per job run. The registry is local to each node, like the job processes.

  This application starts automatically when Bildad is a runtime dependency of the host
  application (the default). A host that lists Bildad with `runtime: false` or under
  `included_applications` must start `{Registry, keys: :unique, name: Bildad.JobRegistry}`
  in its own supervision tree.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Bildad.JobRegistry}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Bildad.Supervisor)
  end
end
