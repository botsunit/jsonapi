defmodule JSONAPI.QueryParser do
  @behaviour Plug
  alias JSONAPI.Config
  alias JSONAPI.Exceptions.InvalidQuery
  import JSONAPI.Utils.IncludeTree

  @moduledoc """
  Implements a fully JSONAPI V1 spec for parsing a complex query string and returning elixir
  datastructures. The purpose is to validate and encode incoming queries and fail quickly.

  Primarialy this handles:
    * [sorts](http://jsonapi.org/format/#fetching-sorting)
    * [include](http://jsonapi.org/format/#fetching-includes)
    * [filtering](http://jsonapi.org/format/#fetching-filtering)
    * [sparse fieldsets](http://jsonapi.org/format/#fetching-includes)

  This plug works in conjunction with a JSONAPI View as well as some plug defined
  configuration.

  In your controller you may add

  ```
  plug JSONAPI.QueryParser,
    filter: ~w(title),
    sort: ~w(created_at title),
    view: MyView
  ```

  If your controller's index function recieves a query with params inside those
  bounds it will build a JSONAPI.Config that has all the validated and parsed
  fields for your usage. The final configuration will be added to assigns `jsonapi_query`.

  The final output will be a `JSONAPI.Config` struct and will look similar to like
      %JSONAPI.Config{
        view: MyView,
        opts: [view: MyView, sort: ["created_at", "title"], filter: ["title"]],
        sort: [desc: :created_at] # Easily insertable into an ecto order_by,
        filter: [title: "my title"] # Easily reduceable into ecto where clauses
        includes: [comments: :user] # Easily insertable into a Repo.preload,
        fields: %{"myview" => [:id, :text], "comment" => [:id, :body]}
      }

  The final result should allow you to build a query quickly and with little overhead.
  You will notice the fields section is a not as easy to work with as the others and
  that is a result of Ecto not supporting high quality selects quite yet. This is a WIP.


  ## Options
    * `:view` - The JSONAPI View which is the basis for this plug.
    * `:sort` - List of atoms which define which fields can be sorted on.
    * `:filter` - List of atoms which define which fields can be filtered on.
  """

  def init(opts) do
    build_config(opts)
  end

  def call(conn, opts) do
    query_params = conn.query_params

    config = opts
    |> parse_fields(Map.get(query_params, "fields", %{}))
    |> parse_include(Map.get(query_params, "include", ""))
    |> parse_filter(Map.get(query_params, "filter", %{}))
    |> parse_sort(Map.get(query_params, "sort", ""))

    Plug.Conn.assign(conn, :jsonapi_query, config)
  end

  def parse_filter(config, map) when map_size(map) == 0, do: config
  def parse_filter(%Config{opts: opts} = config, filter) do
    opts_filter = Keyword.get(opts, :filter, [])
    Enum.reduce(filter, config, fn({key, val}, acc) ->
      unless Enum.any?(opts_filter, fn k -> k == key end) do
        raise InvalidQuery, resource: config.view.type(), param: key, param_type: :filter
      end

      %{acc | filter: Keyword.put(acc.filter, String.to_atom(key), val)}
    end)
  end

  def parse_fields(config, map) when map_size(map) == 0, do: config
  def parse_fields(%Config{} = config, fields) do
    Enum.reduce(fields, config, fn ({type, value}, acc) ->
      valid_fields =
        config
        |> get_valid_fields_for_type(type)
        |> Enum.into(HashSet.new)

      requested_fields =
        value
        |> String.split(",")
        |> Enum.map(&String.to_atom/1)
        |> Enum.into(HashSet.new)

      unless HashSet.subset?(requested_fields, valid_fields) do
        bad_fields =
          requested_fields
          |> HashSet.difference(valid_fields)
          |> HashSet.to_list()
          |> Enum.join(",")

        raise InvalidQuery, resource: config.view.type(),
                            param: bad_fields,
                            param_type: :fields
      end

      %{acc | fields: Map.put(acc.fields, type, HashSet.to_list(requested_fields))}
    end)
  end

  def parse_sort(config, ""), do: config
  def parse_sort(%Config{opts: opts} = config, sort_fields) do
    sorts =
      sort_fields
      |> String.split(",")
      |> Enum.map(fn field ->
        valid_sort = Keyword.get(opts, :sort, [])
        [_, direction, field] = Regex.run(~r/(-?)(\S*)/, field)

        unless field in valid_sort do
          raise InvalidQuery, resource: config.view.type(), param: field, param_type: :sort
        end

        build_sort(direction, String.to_atom(field))
      end)
      |> List.flatten()

    %{config | sort: sorts}
  end

  def build_sort("", field), do: [asc: field]
  def build_sort("-", field), do: [desc: field]

  def parse_include(config, ""), do: config
  def parse_include(%Config{} = config, include_str) do
    includes = handle_include(include_str, config)
    Map.put(config, :includes, includes)
  end

  def handle_include(str, config) when is_binary(str) do
    valid_includes = get_base_relationships(config.view)
    includes = String.split(str, ",")

    Enum.reduce(includes, [], fn(inc, acc) ->
      if inc =~ ~r/\w+\.\w+/ do
        acc ++ handle_nested_include(inc, valid_includes, config)
      else
        inc = String.to_atom(inc)
        if Enum.any?(valid_includes, fn ({key, _val}) -> key == inc end) do
          acc ++ [inc]
        else
          raise InvalidQuery, resource: config.view.type(), param: inc , param_type: :include
        end
      end
    end)
  end

  def handle_nested_include(key, valid_include, config) do
    keys = key |> String.split(".") |> Enum.map(&String.to_existing_atom/1)

    last = List.last(keys)
    path = Enum.slice(keys, 0, Enum.count(keys)-1)

    if member_of_tree?(keys, valid_include) do
      put_as_tree([], path, last)
    else
      raise InvalidQuery, resource: config.view.type() , param: key, param_type: :include
    end
  end

  def get_valid_fields_for_type(%{view: view}, type) do
    if type == view.type do
      view.fields
    else
     get_view_for_type(view, type).fields
    end
  end

  def get_view_for_type(view, type) do
    case Enum.find(view.relationships, fn {k, _v} -> Atom.to_string(k) == type end) do
      {_, view} -> view
      nil -> raise InvalidQuery, resource: view.type, param: type, param_type: :fields
    end
  end

  defp build_config(opts) do
    view = Keyword.fetch!(opts, :view)
    struct(JSONAPI.Config, opts: opts, view: view)
  end
end

