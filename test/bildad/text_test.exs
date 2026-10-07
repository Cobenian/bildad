defmodule Bildad.TextTest do
  use ExUnit.Case, async: true

  alias Bildad.Text

  describe "cut_bytes" do
    test "never splits a character, for 1- to 4-byte characters at every offset" do
      for char <- ["a", "é", "€", "𝄞"], prefix <- ["", "x", "xy", "xyz"] do
        text = prefix <> String.duplicate(char, 5)

        for max <- 0..byte_size(text) do
          cut = Text.cut_bytes(text, max)
          assert String.valid?(cut), "#{inspect(text)} cut at #{max}"
          assert byte_size(cut) <= max
          assert byte_size(cut) > max - byte_size(char)
          assert String.starts_with?(text, cut)
        end
      end
    end

    test "leaves a short text alone" do
      assert Text.cut_bytes("abc", 10) == "abc"
    end
  end

  test "cut_chars counts code points, not graphemes" do
    # "e" plus a combining accent: one grapheme, two code points.
    text = String.duplicate("é", 10)
    assert text |> Text.cut_chars(5) |> String.codepoints() |> length() == 5
    assert Text.cut_chars("abc", 10) == "abc"
  end

  test "sanitize removes invalid UTF-8 and NUL bytes, and keeps valid text" do
    assert Text.sanitize("plain é €") == "plain é €"
    assert Text.sanitize("a" <> <<0xFF, 0xFE>> <> "b\0c") == "abc"
    assert String.valid?(Text.sanitize(<<0xC3>>))
  end
end
