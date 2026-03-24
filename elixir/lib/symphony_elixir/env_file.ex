defmodule SymphonyElixir.EnvFile do
  @moduledoc """
  Loads `.env` defaults and optional `.env.local` overrides from a workflow directory.
  """

  @env_files [
    {".env", :defaults},
    {".env.local", :local_override}
  ]

  @type load_mode :: :defaults | :local_override

  @spec load(String.t()) :: :ok | {:error, term()}
  def load(workflow_dir) when is_binary(workflow_dir) do
    existing_keys =
      System.get_env()
      |> Map.keys()
      |> MapSet.new()

    @env_files
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {filename, mode}, {:ok, loaded_keys} ->
      workflow_dir
      |> Path.join(filename)
      |> load_file(mode, existing_keys, loaded_keys)
      |> case do
        {:ok, next_loaded_keys} -> {:cont, {:ok, next_loaded_keys}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _loaded_keys} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_file(path, mode, existing_keys, loaded_keys) do
    if File.regular?(path) do
      with {:ok, contents} <- File.read(path) do
        parse_file(contents, path, loaded_keys, fn key, value, current_loaded_keys ->
          maybe_put_env(key, value, mode, existing_keys, current_loaded_keys)
        end)
      else
        {:error, reason} -> {:error, {:env_file_read_failed, path, reason}}
      end
    else
      {:ok, loaded_keys}
    end
  end

  defp maybe_put_env(key, value, mode, existing_keys, loaded_keys) do
    cond do
      mode == :defaults and MapSet.member?(existing_keys, key) ->
        {:ok, loaded_keys}

      mode == :local_override and MapSet.member?(existing_keys, key) and
          not MapSet.member?(loaded_keys, key) ->
        {:ok, loaded_keys}

      true ->
        System.put_env(key, value)
        {:ok, MapSet.put(loaded_keys, key)}
    end
  end

  defp parse_file(contents, path, loaded_keys, env_putter) when is_function(env_putter, 3) do
    contents
    |> String.split(~r/\r\n|\n|\r/, trim: false)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, loaded_keys}, fn {line, line_number}, {:ok, current_loaded_keys} ->
      case parse_line(line) do
        :skip ->
          {:cont, {:ok, current_loaded_keys}}

        {:ok, key, value} ->
          case env_putter.(key, value, current_loaded_keys) do
            {:ok, next_loaded_keys} -> {:cont, {:ok, next_loaded_keys}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, {:invalid_env_file, path, line_number, reason}}}
      end
    end)
  end

  defp parse_line(line) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :skip

      String.starts_with?(trimmed, "#") ->
        :skip

      true ->
        trimmed
        |> strip_export_prefix()
        |> split_assignment()
        |> case do
          {:ok, key, raw_value} ->
            with :ok <- validate_key(key),
                 {:ok, value} <- parse_value(raw_value) do
              {:ok, key, value}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp strip_export_prefix(line) do
    case String.split(line, ~r/\s+/, parts: 2) do
      ["export", rest] -> String.trim_leading(rest)
      _ -> line
    end
  end

  defp split_assignment(line) do
    case String.split(line, "=", parts: 2) do
      [raw_key, raw_value] ->
        {:ok, String.trim(raw_key), raw_value}

      _ ->
        {:error, :missing_assignment}
    end
  end

  defp validate_key(key) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key) do
      :ok
    else
      {:error, :invalid_key}
    end
  end

  defp parse_value(raw_value) when is_binary(raw_value) do
    value = String.trim_leading(raw_value)

    cond do
      value == "" ->
        {:ok, ""}

      String.starts_with?(value, "\"") ->
        parse_quoted_value(value, "\"", :double)

      String.starts_with?(value, "'") ->
        parse_quoted_value(value, "'", :single)

      true ->
        {:ok, strip_inline_comment(value) |> String.trim()}
    end
  end

  defp parse_quoted_value(value, quote, quote_mode) do
    opener_size = byte_size(quote)
    remainder = binary_part(value, opener_size, byte_size(value) - opener_size)

    case take_quoted_segment(remainder, quote_mode, "") do
      {:ok, quoted, rest} ->
        case String.trim(rest) do
          "" ->
            decode_quoted_value(quoted, quote_mode)

          "#" <> _comment ->
            decode_quoted_value(quoted, quote_mode)

          _ ->
            {:error, :trailing_characters}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp take_quoted_segment(<<>>, _quote_mode, _acc), do: {:error, :unterminated_quote}

  defp take_quoted_segment(<<"\"", rest::binary>>, :double, acc), do: {:ok, acc, rest}
  defp take_quoted_segment(<<"'", rest::binary>>, :single, acc), do: {:ok, acc, rest}

  defp take_quoted_segment(<<"\\", escaped, rest::binary>>, :double, acc) do
    take_quoted_segment(rest, :double, acc <> <<?\\, escaped>>)
  end

  defp take_quoted_segment(<<char::utf8, rest::binary>>, quote_mode, acc) do
    take_quoted_segment(rest, quote_mode, acc <> <<char::utf8>>)
  end

  defp decode_quoted_value(value, :single), do: {:ok, value}

  defp decode_quoted_value(value, :double) do
    case Jason.decode("\"" <> value <> "\"") do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_escape_sequence}
    end
  end

  defp strip_inline_comment(value) do
    Regex.replace(~r/\s+#.*$/, value, "")
  end
end
