defmodule Bildad.Introspect do
  @moduledoc """
  Looks inside a running job: what it is doing, how much memory it uses, how busy it is.

  `info/1` answers for a job running on the calling node. `remote_info/3` asks another node,
  and `run_info/2` finds the node from the run's details (which need run details enabled; see
  `Bildad.Config`). Bildad does not need its nodes to be connected, so asking another node
  only works when the two are already connected: Bildad never connects nodes itself.

  Only these fields are returned, and nothing else about the process ever is:

  * `:current_function` - `{module, function, arity}` the process is in
  * `:current_stacktrace` - the call stack as `{module, function, arity, location}` entries
    (arities, never arguments)
  * `:memory` - bytes used by the process
  * `:message_queue_len` - messages waiting in its mailbox (the count, not the messages)
  * `:reductions` - work done so far; compare two readings to see whether it is busy
  * `:status` - `:running`, `:runnable`, `:waiting`, ...
  * `:node` - the node running the job

  The process dictionary, the messages, the backtrace, links and monitors are never
  returned: they can hold the data the job works on.

  Only the job's own process is looked at: a job that does its work in tasks shows as
  waiting for them.

  These functions do no access control. Expose them only to people allowed to see jobs.
  """

  alias Bildad.Job.JobConfig
  alias Bildad.Job.JobRun
  alias Bildad.Job.JobRunDetails

  @fields [
    :current_function,
    :current_stacktrace,
    :memory,
    :message_queue_len,
    :reductions,
    :status
  ]

  @type info :: %{
          current_function: {module(), atom(), non_neg_integer()} | :undefined,
          current_stacktrace: list(),
          memory: non_neg_integer(),
          message_queue_len: non_neg_integer(),
          reductions: non_neg_integer(),
          status: atom(),
          node: node()
        }

  @type error ::
          :not_running
          | :unknown_node
          | :not_distributed
          | :noconnection
          | :timeout
          | :unsupported
          | :no_details

  @doc """
  Process information for the job running on this node under `job_process_name` (the job
  run's `job_process_name`). `{:error, :not_running}` when no such job runs here.
  """
  @spec info(String.t()) :: {:ok, info()} | {:error, :not_running}
  def info(job_process_name) when is_binary(job_process_name) do
    with [{pid, _}] <- Registry.lookup(Bildad.JobRegistry, job_process_name),
         list when is_list(list) <- Process.info(pid, @fields) do
      {:ok, list |> Map.new() |> Map.put(:node, node())}
    else
      _ -> {:error, :not_running}
    end
  end

  @doc """
  Like `info/1`, for a job running on `node` (an atom, or a string such as the one recorded
  in the run's details).

  Never raises. Returns `{:error, reason}` with:

  * `:unknown_node` - a string that names no node this node has heard of
  * `:not_distributed` - this node is not running distributed Erlang
  * `:noconnection` - the node is not connected (it is never connected implicitly) or went
    away during the call
  * `:timeout` - no answer within `opts[:timeout]` milliseconds (default 2000)
  * `:unsupported` - the node runs a Bildad without this function
  * `:not_running` - the job is not running there (any more)
  """
  @spec remote_info(node() | String.t(), String.t(), keyword()) ::
          {:ok, info()} | {:error, error()}
  def remote_info(node, job_process_name, opts \\ []) when is_binary(job_process_name) do
    timeout = Keyword.get(opts, :timeout, 2_000)

    with {:ok, node} <- to_node(node) do
      cond do
        node == node() -> info(job_process_name)
        not Node.alive?() -> {:error, :not_distributed}
        node not in Node.list() -> {:error, :noconnection}
        true -> call(node, job_process_name, timeout)
      end
    end
  end

  @doc """
  Like `remote_info/3`, for a job run, on the node recorded in its details.
  `{:error, :no_details}` when the run has no details (run details are not enabled, or the
  run started before they were).
  """
  @spec run_info(%JobConfig{}, %JobRun{}, keyword()) ::
          {:ok, info()} | {:error, error()}
  def run_info(%JobConfig{} = job_config, %JobRun{} = job_run, opts \\ []) do
    case JobRunDetails.get_job_run_detail(job_config, job_run.id) do
      %{node: node} when is_binary(node) -> remote_info(node, job_run.job_process_name, opts)
      _ -> {:error, :no_details}
    end
  end

  # A node name from the database must not create an atom: one that is not already an atom
  # is a node this node has never been connected to.
  defp to_node(node) when is_atom(node), do: {:ok, node}

  defp to_node(node) when is_binary(node) do
    {:ok, String.to_existing_atom(node)}
  rescue
    ArgumentError -> {:error, :unknown_node}
  end

  defp call(node, job_process_name, timeout) do
    case :erpc.call(node, __MODULE__, :info, [job_process_name], timeout) do
      {:ok, %{} = info} -> {:ok, Map.take(info, @fields ++ [:node])}
      {:error, _} -> {:error, :not_running}
      _ -> {:error, :unsupported}
    end
  catch
    :error, {:erpc, :noconnection} -> {:error, :noconnection}
    :error, {:erpc, :timeout} -> {:error, :timeout}
    # The remote node has no Bildad.Introspect.info/1, or no job registry.
    :error, {:exception, :undef, _} -> {:error, :unsupported}
    :error, {:exception, %UndefinedFunctionError{}, _} -> {:error, :unsupported}
    :error, {:exception, %ArgumentError{}, _} -> {:error, :unsupported}
    _kind, _reason -> {:error, :unsupported}
  end
end
