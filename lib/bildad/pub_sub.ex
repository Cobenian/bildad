if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule Bildad.PubSub do
    @moduledoc """
    Broadcasts Bildad's job telemetry events over `Phoenix.PubSub`. Compiled only when
    `phoenix_pubsub` is a dependency of the application.

        Bildad.PubSub.attach(MyApp.PubSub)

    Each event is broadcast as `{:bildad_job, event, payload}`, where `event` is the last
    part of the telemetry event name (`:start`, `:progress`, `:stop`, ...) and `payload` is
    a map with the job's identity (see `Bildad.current_job/0`) and, depending on the event,
    `fraction`, `message`, `result` and `kind`. The `:stream` event is not broadcast.

    Error terms (`error`, `reason`, `stacktrace`) are left out unless `include_errors: true`
    is given: they can contain data the job worked on, and a broadcast can reach every node
    and every page subscribed to the topic.

    PubSub reaches other nodes only when they are connected (or with a PubSub adapter that
    does not need it). Nodes that are not connected can read a run's persisted progress
    instead (see `Bildad.Job.Jobs.get_job_run_detail/2`).

    Options:

    * `:id` - the telemetry handler id, so several handlers can be attached. Default
      `Bildad.PubSub`.
    * `:topic` - a function from the payload to a topic. Default
      `"bildad:job:<job_run_id>"`.
    * `:include_errors` - include raw error terms. Default false.
    """

    require Logger

    @events [:start, :stop, :exception, :progress, :killed, :expired, :stopped]

    @doc "Attaches the broadcaster. Returns `:ok` or `{:error, :already_exists}`."
    def attach(pubsub, opts \\ []) do
      id = Keyword.get(opts, :id, __MODULE__)

      config = %{
        pubsub: pubsub,
        topic: Keyword.get(opts, :topic, &default_topic/1),
        include_errors: Keyword.get(opts, :include_errors, false)
      }

      :telemetry.attach_many(
        id,
        Enum.map(@events, &[:bildad, :job, &1]),
        &__MODULE__.handle_event/4,
        config
      )
    end

    @doc "Detaches the broadcaster attached with the given id."
    def detach(id \\ __MODULE__), do: :telemetry.detach(id)

    @doc false
    def handle_event([:bildad, :job, event], measurements, metadata, config) do
      payload = payload(event, measurements, metadata, config.include_errors)

      Phoenix.PubSub.broadcast(
        config.pubsub,
        config.topic.(payload),
        {:bildad_job, event, payload}
      )
    rescue
      # A handler that raises is detached for every job on the node; log and carry on.
      e -> Logger.warning("Bildad.PubSub could not broadcast: #{Exception.message(e)}")
    end

    defp payload(event, measurements, metadata, include_errors) do
      base =
        Map.take(metadata, [
          :job_run_id,
          :job_run_identifier,
          :job_template_id,
          :job_template_code,
          :job_module,
          :retry,
          :node
        ])

      extra =
        case event do
          :progress -> Map.take(metadata, [:fraction, :message])
          :stop -> Map.take(metadata, [:result]) |> Map.put(:duration, measurements[:duration])
          :exception -> Map.take(metadata, [:kind]) |> Map.put(:duration, measurements[:duration])
          _ -> %{}
        end

      errors =
        if include_errors, do: Map.take(metadata, [:error, :reason, :stacktrace]), else: %{}

      base |> Map.merge(extra) |> Map.merge(errors)
    end

    defp default_topic(%{job_run_id: id}), do: "bildad:job:#{id}"
  end
end
