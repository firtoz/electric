defmodule Electric.Client.Fetch.Request do
  use GenServer

  alias Electric.Client
  alias Electric.Client.Fetch
  alias Electric.Client.Offset
  alias Electric.Client.ShapeDefinition
  alias Electric.Client.Util

  require Logger

  defstruct [
    :base_url,
    :shape_handle,
    :live,
    :shape,
    :next_cursor,
    update_mode: :modified,
    method: :get,
    offset: Offset.before_all(),
    params: %{},
    headers: %{},
    authenticated: false
  ]

  @type params :: %{String.t() => String.t()}
  @type headers :: %{String.t() => [String.t()] | String.t()}

  fields = [
    method: quote(do: :get | :head | :delete),
    base_url: quote(do: URI.t()),
    offset: quote(do: Electric.Client.Offset.t()),
    shape_handle: quote(do: Electric.Client.shape_handle() | nil),
    update_mode: quote(do: Electric.Client.update_mode()),
    live: quote(do: boolean()),
    next_cursor: quote(do: Electric.Client.cursor()),
    shape: quote(do: ShapeDefinition.t()),
    params: quote(do: params()),
    headers: quote(do: headers())
  ]

  @type unauthenticated :: %__MODULE__{unquote_splicing(fields), authenticated: false}
  @type authenticated :: %__MODULE__{unquote_splicing(fields), authenticated: true}
  @type t :: unauthenticated() | authenticated()

  # the base url should come from the client
  attrs = Keyword.delete(fields, :base_url)

  attr_types =
    attrs
    |> Enum.reduce(nil, fn
      {name, spec}, nil -> quote(do: unquote({name, spec}))
      {name, spec}, acc -> quote(do: unquote({name, spec}) | unquote(acc))
    end)

  @type attr :: unquote(attr_types)
  @type attrs :: [attr()] | %{unquote_splicing(attrs)}

  @doc false
  def name(request_id) do
    {:via, Registry, {Electric.Client.Registry, {__MODULE__, request_id}}}
  end

  defp request_id(%Client{fetch: {fetch_impl, _}}, %__MODULE__{shape_handle: nil} = request) do
    %{base_url: base_url, shape: shape_definition} = request
    {fetch_impl, base_url, shape_definition}
  end

  defp request_id(%Client{fetch: {fetch_impl, _}}, %__MODULE__{} = request) do
    %{base_url: base_url, offset: offset, live: live, shape_handle: shape_handle} = request
    {fetch_impl, base_url, shape_handle, Offset.to_tuple(offset), live}
  end

  @doc """
  Returns the URL for the Request.
  """
  @spec url(t()) :: binary()
  def url(%__MODULE__{} = request, opts \\ []) do
    %{base_url: base_url} = request
    path = "/v1/shape"
    uri = URI.append_path(base_url, path)

    if Keyword.get(opts, :query, true) do
      query = request |> params() |> URI.encode_query(:rfc3986)

      URI.to_string(%{uri | query: query})
    else
      URI.to_string(uri)
    end
  end

  @doc false
  @spec params(t()) :: params()
  def params(%__MODULE__{} = request) do
    %{
      shape: shape,
      update_mode: update_mode,
      live: live?,
      shape_handle: shape_handle,
      offset: %Offset{} = offset,
      next_cursor: cursor,
      params: params
    } = request

    (params || %{})
    |> Map.merge(ShapeDefinition.params(shape))
    |> Map.merge(%{"offset" => Offset.to_string(offset)})
    |> Util.map_put_if("update_mode", to_string(update_mode), update_mode != :modified)
    |> Util.map_put_if("handle", shape_handle, is_binary(shape_handle))
    |> Util.map_put_if("live", "true", live?)
    |> Util.map_put_if("cursor", cursor, !is_nil(cursor))
  end

  @doc false
  def request(%Client{} = client, %__MODULE__{} = request) do
    request_id = request_id(client, request)

    # register this pid before making the request to avoid race conditions for
    # very fast responses
    {:ok, monitor_pid} = start_monitor(request_id)

    try do
      ref = Fetch.Monitor.register(monitor_pid, self())

      {:ok, _request_pid} = start_request(request_id, request, client, monitor_pid)

      Fetch.Monitor.wait(ref)
    catch
      :exit, {reason, _} ->
        Logger.debug(fn ->
          "Request process ended with reason #{inspect(reason)} before we could register. Re-attempting."
        end)

        request(client, request)
    end
  end

  defp start_request(request_id, request, client, monitor_pid) do
    DynamicSupervisor.start_child(
      Electric.Client.RequestSupervisor,
      {__MODULE__, {request_id, request, client, monitor_pid}}
    )
    |> return_existing()
  end

  defp start_monitor(request_id) do
    DynamicSupervisor.start_child(
      Electric.Client.RequestSupervisor,
      {Electric.Client.Fetch.Monitor, request_id}
    )
    |> return_existing()
  end

  defp return_existing({:ok, pid}), do: {:ok, pid}
  defp return_existing({:error, {:already_started, pid}}), do: {:ok, pid}
  defp return_existing(error), do: error

  @doc false
  def child_spec({request_id, _request, _client, _monitor_pid} = args) do
    %{
      id: {__MODULE__, request_id},
      start: {__MODULE__, :start_link, [args]},
      restart: :transient,
      type: :worker
    }
  end

  @doc false
  def start_link({request_id, request, client, monitor_pid}) do
    GenServer.start_link(__MODULE__, {request_id, request, client, monitor_pid},
      name: name(request_id)
    )
  end

  @impl true
  def init({request_id, request, client, monitor_pid}) do
    Logger.debug(fn ->
      "Starting request for #{inspect(request_id)}"
    end)

    state = %{
      request_id: request_id,
      request: request,
      client: client,
      monitor_pid: monitor_pid
    }

    {:ok, state, {:continue, :request}}
  end

  @impl true
  def handle_continue(:request, state) do
    %{client: client, request: request} = state
    %{fetch: {fetcher, fetcher_opts}} = client

    authenticated_request = Client.authenticate_request(client, request)

    case fetcher.fetch(authenticated_request, fetcher_opts) do
      {:ok, %Fetch.Response{status: status} = response} when status in 200..299 ->
        reply(response, state)

      {:ok, %Fetch.Response{} = response} ->
        # Turn HTTP errors into errors
        reply({:error, response}, state)

      error ->
        reply(error, state)
    end

    {:stop, :normal, state}
  end

  defp reply(response, %{monitor_pid: monitor_pid}) do
    Fetch.Monitor.reply(monitor_pid, response)
  end
end
