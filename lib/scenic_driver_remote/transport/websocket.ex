if Code.ensure_loaded?(WebSockex) do
  defmodule ScenicDriverRemote.Transport.WebSocket do
    @moduledoc """
    WebSocket transport for browser-based renderers.

    Requires the `:websockex` dependency.

    ## Options

    - `:url` - Required. WebSocket URL to connect to.
    - `:owner` - Optional. Process to receive messages. Defaults to caller.

    ## Example

        ScenicDriverRemote.Transport.WebSocket.connect(url: "ws://localhost:4000/scenic")
    """

    @behaviour ScenicDriverRemote.Transport
    use WebSockex

    import Kernel, except: [send: 2]

    defstruct [:conn, :url, :owner]

    @impl ScenicDriverRemote.Transport
    def connect(opts) do
      url = Keyword.fetch!(opts, :url)
      owner = Keyword.get(opts, :owner, self())

      case WebSockex.start_link(url, __MODULE__, %{owner: owner}, async: true) do
        {:ok, conn} ->
          {:ok, %__MODULE__{conn: conn, url: url, owner: owner}}

        {:error, _} = error ->
          error
      end
    end

    @impl ScenicDriverRemote.Transport
    def disconnect(%__MODULE__{conn: conn}) do
      WebSockex.cast(conn, :close)
      :ok
    end

    @impl ScenicDriverRemote.Transport
    def send(%__MODULE__{conn: conn}, data) do
      WebSockex.send_frame(conn, {:binary, IO.iodata_to_binary(data)})
    end

    @impl ScenicDriverRemote.Transport
    def connected?(%__MODULE__{conn: conn}) do
      Process.alive?(conn)
    end

    @impl ScenicDriverRemote.Transport
    def controlling_process(%__MODULE__{conn: conn}, pid) do
      WebSockex.cast(conn, {:set_owner, pid})
      :ok
    end

    # WebSockex callbacks

    @impl WebSockex
    def handle_frame({:binary, data}, %{owner: owner} = state) do
      Kernel.send(owner, {:tcp, self(), data})
      {:ok, state}
    end

    def handle_frame(_frame, state) do
      {:ok, state}
    end

    @impl WebSockex
    def handle_cast(:close, state) do
      {:close, state}
    end

    def handle_cast({:set_owner, pid}, state) do
      {:ok, %{state | owner: pid}}
    end

    @impl WebSockex
    def handle_disconnect(_reason, %{owner: owner} = state) do
      Kernel.send(owner, {:tcp_closed, self()})
      {:ok, state}
    end
  end
else
  defmodule ScenicDriverRemote.Transport.WebSocket do
    @moduledoc """
    WebSocket transport for browser-based renderers.

    This module requires the `:websockex` dependency. Add it to your mix.exs:

        {:websockex, "~> 0.4"}
    """

    @behaviour ScenicDriverRemote.Transport

    defstruct [:conn, :url, :owner]

    @impl true
    def connect(_opts) do
      {:error, :websockex_not_available}
    end

    @impl true
    def disconnect(_transport), do: :ok

    @impl true
    def send(_transport, _data), do: {:error, :websockex_not_available}

    @impl true
    def connected?(_transport), do: false

    @impl true
    def controlling_process(_transport, _pid), do: {:error, :websockex_not_available}
  end
end
