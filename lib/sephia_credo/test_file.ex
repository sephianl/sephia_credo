defmodule SephiaCredo.TestFile do
  @moduledoc "Whether a source file is an ExUnit test file."

  def test_file?(%Credo.SourceFile{filename: filename}) when is_binary(filename),
    do: String.ends_with?(filename, "_test.exs")

  def test_file?(_source_file), do: false
end
