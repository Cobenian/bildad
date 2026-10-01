defmodule Bildad.Text do
  @moduledoc false
  # Cutting text so it always fits a database column and is valid UTF-8 there.

  @doc "The first `max` code points (database string columns count code points)."
  def cut_chars(text, max) when is_binary(text) do
    text |> String.codepoints() |> Enum.take(max) |> Enum.join()
  end

  @doc "At most `max` bytes, cut on a UTF-8 character boundary."
  def cut_bytes(text, max) when is_binary(text) and byte_size(text) <= max, do: text

  def cut_bytes(text, max) when is_binary(text) do
    text |> binary_part(0, max) |> drop_partial_char()
  end

  @doc "Valid UTF-8 without NUL bytes (which Postgres text columns reject)."
  def sanitize(text) when is_binary(text) do
    text
    |> String.replace_invalid()
    |> String.replace(<<0>>, "")
  end

  # Drops an incomplete UTF-8 character left at the end by a byte cut. Only the last three
  # bytes are looked at, so binary data that is not UTF-8 is not otherwise changed.
  defp drop_partial_char(bin) do
    size = byte_size(bin)

    Enum.find_value(1..min(3, size)//1, bin, fn back ->
      <<byte>> = binary_part(bin, size - back, 1)

      case utf8_length(byte) do
        :continuation -> nil
        :single -> bin
        needed when needed > back -> binary_part(bin, 0, size - back)
        _complete -> bin
      end
    end)
  end

  defp utf8_length(byte) when byte < 0x80, do: :single
  defp utf8_length(byte) when byte < 0xC0, do: :continuation
  defp utf8_length(byte) when byte < 0xE0, do: 2
  defp utf8_length(byte) when byte < 0xF0, do: 3
  defp utf8_length(_byte), do: 4
end
