defmodule ScenicDriverRemote.Transport.TcpServer do
  @moduledoc """
  TCP server transport for remote rendering.

  Unlike `Tcp` which connects to a remote server, this module listens for
  incoming connections from mobile renderers (Android/iOS).

  The server starts listening immediately and accepts connections asynchronously.
  When a client connects, TCP messages are forwarded to the controlling process.

  ## Options

  - `:port` - Required. Port number to listen on.
  - `:host` - Optional. Interface to bind to (default: all interfaces).

  ## Example

      config :my_app, :viewport,
        drivers: [
          [
            module: ScenicDriverRemote,
            transport: ScenicDriverRemote.Transport.TcpServer,
            port: 4040
          ]
        ]
  """

  @behaviour ScenicDriverRemote.Transport

  use GenServer
  require Logger

  import Kernel, except: [send: 2]

  defstruct [:listen_socket, :client_socket, :port, :host, :owner]

  # Client API

  @impl ScenicDriverRemote.Transport
  def connect(opts) do
    port = Keyword.fetch!(opts, :port)
    host = Keyword.get(opts, :host, {0, 0, 0, 0})

    case GenServer.start_link(__MODULE__, {port, host, self()}) do
      {:ok, pid} ->
        # Return a handle that wraps the GenServer
        {:ok, %__MODULE__{port: port, host: host, owner: pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl ScenicDriverRemote.Transport
  def disconnect(%__MODULE__{owner: pid}) when is_pid(pid) do
    GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  def disconnect(_), do: :ok

  @impl ScenicDriverRemote.Transport
  def send(%__MODULE__{owner: pid}, data) when is_pid(pid) do
    GenServer.call(pid, {:send, data})
  catch
    :exit, _ -> {:error, :not_connected}
  end

  def send(_, _), do: {:error, :not_connected}

  @impl ScenicDriverRemote.Transport
  def connected?(%__MODULE__{owner: pid}) when is_pid(pid) do
    GenServer.call(pid, :connected?)
  catch
    :exit, _ -> false
  end

  def connected?(_), do: false

  @impl ScenicDriverRemote.Transport
  def controlling_process(%__MODULE__{owner: pid}, new_owner) when is_pid(pid) do
    GenServer.call(pid, {:controlling_process, new_owner})
  catch
    :exit, _ -> {:error, :not_connected}
  end

  def controlling_process(_, _), do: {:error, :not_connected}

  # Get server info for QR code generation
  def get_server_info(%__MODULE__{owner: pid}) when is_pid(pid) do
    GenServer.call(pid, :get_server_info)
  catch
    :exit, _ -> {:error, :not_running}
  end

  # GenServer callbacks

  @impl GenServer
  def init({port, host, owner}) do
    host_tuple = normalize_host(host)

    tcp_opts = [:binary, active: false, packet: :raw, reuseaddr: true, ip: host_tuple]

    case :gen_tcp.listen(port, tcp_opts) do
      {:ok, listen_socket} ->
        local_ip = get_local_ip()
        Logger.info("#{__MODULE__}: Listening on #{format_ip(local_ip)}:#{port}")
        Logger.info("#{__MODULE__}: QR payload: {probnikoff_net, {#{format_ip_tuple(local_ip)}, #{port}}}")

        state = %{
          listen_socket: listen_socket,
          client_socket: nil,
          port: port,
          host: host_tuple,
          owner: owner,
          local_ip: local_ip
        }

        # Start accepting connections asynchronously
        Kernel.send(self(), :accept)

        {:ok, state}

      {:error, reason} ->
        Logger.error("#{__MODULE__}: Failed to listen on port #{port}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:send, data}, _from, %{client_socket: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:send, data}, _from, %{client_socket: socket} = state) do
    result = :gen_tcp.send(socket, data)
    {:reply, result, state}
  end

  def handle_call(:connected?, _from, %{client_socket: socket} = state) do
    connected = socket != nil && port_open?(socket)
    {:reply, connected, state}
  end

  def handle_call({:controlling_process, new_owner}, _from, %{client_socket: socket} = state) do
    result =
      if socket do
        :gen_tcp.controlling_process(socket, new_owner)
      else
        :ok
      end

    {:reply, result, %{state | owner: new_owner}}
  end

  def handle_call(:get_server_info, _from, %{local_ip: ip, port: port} = state) do
    {:reply, {:ok, ip, port}, state}
  end

  @impl GenServer
  def handle_info(:accept, %{listen_socket: listen_socket} = state) do
    # Non-blocking accept with timeout
    case :gen_tcp.accept(listen_socket, 100) do
      {:ok, client_socket} ->
        handle_new_client(client_socket, state)

      {:error, :timeout} ->
        # Keep trying to accept
        Kernel.send(self(), :accept)
        {:noreply, state}

      {:error, :closed} ->
        Logger.info("#{__MODULE__}: Listen socket closed")
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("#{__MODULE__}: Accept error: #{inspect(reason)}")
        Kernel.send(self(), :accept)
        {:noreply, state}
    end
  end

  def handle_info({:tcp, socket, data}, %{client_socket: socket, owner: owner} = state) do
    # Forward TCP data to owner (the Scenic driver)
    Kernel.send(owner, {:tcp, socket, data})
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{client_socket: socket, owner: owner} = state) do
    Logger.info("#{__MODULE__}: Client disconnected")
    Kernel.send(owner, {:tcp_closed, socket})
    # Go back to accepting new connections
    Kernel.send(self(), :accept)
    {:noreply, %{state | client_socket: nil}}
  end

  def handle_info({:tcp_error, socket, reason}, %{client_socket: socket, owner: owner} = state) do
    Logger.warning("#{__MODULE__}: Client error: #{inspect(reason)}")
    Kernel.send(owner, {:tcp_error, socket, reason})
    :gen_tcp.close(socket)
    Kernel.send(self(), :accept)
    {:noreply, %{state | client_socket: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("#{__MODULE__}: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{listen_socket: listen, client_socket: client}) do
    if client, do: :gen_tcp.close(client)
    if listen, do: :gen_tcp.close(listen)
    :ok
  end

  # Private helpers

  defp handle_new_client(client_socket, %{client_socket: old_socket, owner: owner} = state) do
    # Close existing client if any
    if old_socket, do: :gen_tcp.close(old_socket)

    {:ok, {addr, port}} = :inet.peername(client_socket)
    addr_str = format_ip(addr)
    Logger.info("#{__MODULE__}: Client connected from #{addr_str}:#{port}")

    # Set socket to active mode so we receive messages
    :inet.setopts(client_socket, active: true)

    # Transfer controlling process to ourselves (we'll forward to owner)
    :gen_tcp.controlling_process(client_socket, self())

    # Notify owner that we're connected (driver will see this as successful connection)
    # The driver already handles {:tcp, ...} messages

    {:noreply, %{state | client_socket: client_socket}}
  end

  defp normalize_host(host) when is_tuple(host), do: host
  defp normalize_host(host) when is_binary(host), do: parse_ip(host)
  defp normalize_host(host) when is_list(host), do: parse_ip(to_string(host))
  defp normalize_host(_), do: {0, 0, 0, 0}

  defp parse_ip(str) do
    case :inet.parse_address(to_charlist(str)) do
      {:ok, addr} -> addr
      _ -> {0, 0, 0, 0}
    end
  end

  defp port_open?(socket) do
    case :inet.peername(socket) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Get the local IP address (first non-loopback IPv4).
  """
  def get_local_ip do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.flat_map(fn {_name, opts} ->
          opts
          |> Enum.filter(fn
            {:addr, {a, _, _, _}} when a != 127 -> true
            _ -> false
          end)
          |> Enum.map(fn {:addr, addr} -> addr end)
        end)
        |> List.first() || {127, 0, 0, 1}

      _ ->
        {127, 0, 0, 1}
    end
  end

  def format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  def format_ip(_), do: "unknown"

  def format_ip_tuple({a, b, c, d}), do: "{#{a}, #{b}, #{c}, #{d}}"
  def format_ip_tuple(_), do: "{127, 0, 0, 1}"
end
