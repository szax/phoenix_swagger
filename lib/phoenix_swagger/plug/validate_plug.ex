defmodule PhoenixSwagger.Plug.Validate do
  import Plug.Conn
  alias PhoenixSwagger.Validator

  @table :validator_table

  @doc """
  Plug.init callback

  Options:

   - `:validation_failed_status` the response status to set when parameter validation fails, defaults to 400.
  """
  def init(opts), do: opts

  def call(conn, opts) do
    validation_failed_status = Keyword.get(opts, :validation_failed_status, 400)
    req_path = Enum.filter(:ets.tab2list(@table), fn({path, basePath, _}) ->
      pathInfo = remove_base_path(conn.path_info, String.split(basePath, "/") |> tl)
      req_path = [String.downcase(conn.method) | pathInfo]
      equal_paths(path, String.split(path, "/") |> tl, req_path) != []
    end)
    with [{path, _, _}] <- req_path,
         :ok <- validate_body_params(path, conn.params),
         :ok <- validate_query_params(path, conn.params) do
      conn
    else
      [] ->
        response = Poison.encode! %{
          error: %{
            message: "API does not provide resource",
            path: "/" <> (conn.path_info |> Enum.join("/"))
          }
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, response)
        |> halt()

      {:error, error, path} ->
        response = Poison.encode! %{
          error: %{
            message: get_error_message(error),
            path: path
          }
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(validation_failed_status, response)
        |> halt()
    end
  end

  defp validate_boolean(name, value, parameters) do
    try do
      val = String.to_existing_atom(value)
      if val != true and val != false do
        {:error, "Type mismatch. Expected Boolean but got String.", "#/#{name}"}
      else
        validate_query_params(parameters)
      end
    rescue _e in ArgumentError ->
        {:error, "Type mismatch. Expected Boolean but got String.", "#/#{name}"}
    end
  end

  defp validate_integer(name, value, parameters) do
    try do
      _ = String.to_integer(value)
      validate_query_params(parameters)
    rescue _e in ArgumentError ->
        {:error, "Type mismatch. Expected Integer but got String.", "#/#{name}"}
    end
  end

  defp validate_query_params([]), do: :ok
  defp validate_query_params([{_type, _name, nil, false} | parameters]) do
    validate_query_params(parameters)
  end
  defp validate_query_params([{_type, name, nil, true} | _]) do
    {:error, "Required property #{name} was not present.", "#"}
  end
  defp validate_query_params([{"string", _name, _val, _} | parameters]) do
    validate_query_params(parameters)
  end
  defp validate_query_params([{"integer", name, val, _} | parameters]) do
    validate_integer(name, val, parameters)
  end
  defp validate_query_params([{"boolean", name, val, _} | parameters]) do
    validate_boolean(name, val, parameters)
  end
  defp validate_query_params(path, params) do
    [{_, _basePath, schema}] = :ets.lookup(@table, path)
    parameters = Enum.map(schema.schema["parameters"], fn parameter ->
      if parameter["type"] != nil and parameter["in"] == "query" do
        {parameter["type"], parameter["name"], params[parameter["name"]], parameter["required"]}
      else
        []
      end
    end) |> List.flatten
    validate_query_params(parameters)
  end

  defp validate_body_params(path, params) do
    [{_, _, schema}] = :ets.lookup(@table, path)
    parameters = Enum.map(schema.schema["parameters"], fn parameter ->
      if parameter["type"] != nil and parameter["in"] == "query" do
        parameter["name"]
      else
        []
      end
    end) |> List.flatten
    if parameters == [] do
      Validator.validate(path, params)
    else
      params = Enum.filter(params, fn ({name, _val}) ->
        not name in parameters
      end) |> Enum.into(%{})
      Validator.validate(path, params)
    end
  end

  defp equal_paths(_, [], req) when length(req) > 0, do: []
  defp equal_paths(_, orig, []) when length(orig) > 0, do: []
  defp equal_paths(orig_path, [], []), do: orig_path
  defp equal_paths(orig_path, [orig | orig_path_rest], [ req | req_path_rest]) do
    if (String.codepoints(orig) |> hd) == "{" or orig == req do
      equal_paths(orig_path, orig_path_rest, req_path_rest)
    else
      []
    end
  end

  # It is pretty safe to strip request path by base path. They can't be
  # non-equal. In this way, the router even will not execute this plug.
  defp remove_base_path(path, []), do: path
  defp remove_base_path([_path | rest], [_base_path | base_path_rest]) do
    remove_base_path(rest, base_path_rest)
  end

  defp get_error_message(error) when is_list(error), do: List.first(error) |> elem(0)
  defp get_error_message(error), do: error
end
