defmodule Bildad.RunLog.Handler do
  @moduledoc false
  # A :logger handler that keeps the last lines logged by each running job in a ring buffer
  # in the job process's own dictionary. :logger calls handlers in the process that logs,
  # so a process with no buffer (anything but a job process with the run log on) returns at
  # once, and a job's lines never mix with another's. Tasks the job starts have no buffer.
  #
  # Each line: the message only (no metadata), formatted with a size limit, passed through
  # the redaction hook (failing closed), made valid UTF-8 without NUL bytes, then cut to
  # max_line_bytes. Nothing here may raise: :logger removes a handler that does.

  @behaviour :logger_handler

  @buffer :"$bildad_run_log"
  @busy :"$bildad_run_log_busy"

  @impl true
  def adding_handler(config), do: {:ok, config}

  @impl true
  def log(event, %{config: config}) do
    # A redaction hook that logs would call this handler again from inside it: the busy flag
    # makes that inner call return at once instead of recursing.
    with {lines, count, dropped} <- Process.get(@buffer),
         nil <- Process.put(@busy, true) do
      try do
        Process.put(@buffer, append(lines, count, dropped, line(event, config), config))
      after
        Process.delete(@busy)
      end
    end

    :ok
  catch
    _, _ -> :ok
  end

  @doc false
  def buffer_key, do: @buffer

  defp append(lines, count, dropped, :drop, _config), do: {lines, count, dropped + 1}

  defp append(lines, count, dropped, line, %{max_lines: max}) when count < max do
    {:queue.in(line, lines), count + 1, dropped}
  end

  defp append(lines, count, dropped, line, _config) do
    {{:value, _oldest}, lines} = :queue.out(lines)
    {:queue.in(line, lines), count, dropped + 1}
  end

  # Any failure to build the line drops it (and counts it as dropped).
  defp line(event, config) do
    build_line(event, config)
  catch
    _, _ -> :drop
  end

  defp build_line(%{level: level, msg: msg, meta: meta}, config) do
    limit = config.max_line_bytes * 4

    with message when is_binary(message) <- message(msg, meta, limit),
         message when is_binary(message) <- redact(message, level, config.redact) do
      # The record separator separates saved lines (see Bildad.RunLog).
      message =
        message
        |> Bildad.Text.sanitize()
        |> String.replace("\u001E", "")
        |> Bildad.Text.cut_bytes(config.max_line_bytes)

      "#{timestamp(meta)} [#{level}] #{message}"
    else
      _ -> :drop
    end
  end

  defp message({:string, text}, _meta, limit) when is_binary(text) do
    Bildad.Text.cut_bytes(text, limit)
  end

  # A long chardata is sliced before it is turned into one binary.
  defp message({:string, chardata}, _meta, limit) do
    chardata |> :string.slice(0, limit) |> IO.chardata_to_string() |> Bildad.Text.cut_bytes(limit)
  end

  defp message({:report, report}, meta, limit) do
    case meta do
      %{report_cb: cb} when is_function(cb, 1) ->
        {format, args} = cb.(report)
        format(format, args, limit)

      %{report_cb: cb} when is_function(cb, 2) ->
        cb.(report, %{chars_limit: limit, depth: 30, single_line: true})
        |> IO.chardata_to_string()

      _ ->
        inspect(report, limit: 50, printable_limit: limit)
    end
  end

  defp message({format, args}, _meta, limit), do: format(format, args, limit)

  defp format(format, args, limit) do
    format |> :io_lib.format(args, chars_limit: limit) |> IO.chardata_to_string()
  end

  # Fails closed: anything but a binary (or a raise) drops the line.
  defp redact(message, _level, nil), do: message

  defp redact(message, level, {module, function, extra}) do
    case apply(module, function, [message, level | extra]) do
      kept when is_binary(kept) -> kept
      _ -> :drop
    end
  rescue
    _ -> :drop
  catch
    _, _ -> :drop
  end

  defp redact(_message, _level, _invalid), do: :drop

  defp timestamp(%{time: time}) when is_integer(time) do
    time |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  end

  defp timestamp(_meta), do: DateTime.utc_now() |> DateTime.to_iso8601()
end
