defmodule SephiaCredo.TestFile do
  @moduledoc "Whether a source file is an ExUnit test file, or test code at all."

  def test_file?(%Credo.SourceFile{filename: filename}) when is_binary(filename),
    do: String.ends_with?(filename, "_test.exs")

  def test_file?(_source_file), do: false

  @doc """
  Whether a source file is test code: an ExUnit test file, or any file under a
  `test/` folder that is not under `lib/`, such as `test/support/factory.ex`.
  """
  def test_code?(%Credo.SourceFile{filename: filename} = source_file) when is_binary(filename) do
    segments = Path.split(filename)
    test_file?(source_file) or ("test" in segments and "lib" not in segments)
  end

  def test_code?(_source_file), do: false
end
