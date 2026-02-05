defmodule ScenicDriverRemote.Transport.TcpServer do
  @moduledoc """
  TCP server transport for remote rendering with multi-client support.

  Listens for incoming connections from mobile renderers (Android/iOS).
  Multiple clients can connect simultaneously — commands are broadcast
  to all connected clients, and events from any client are forwarded
  to the Scenic driver.

  ## Options

  - `:port` - Required. Port number to listen on.
  - `:host` - Optional. Interface to bind to (default: all interfaces).
  """

  @behaviour ScenicDriverRemote.Transport

  use GenServer
  require Logger

  import Kernel, except: [send: 2]

  defstruct [:port, :host, :owner]

  # Client API

  @impl ScenicDriverRemote.Transport
  def connect(opts) do
    port = Keyword.fetch!(opts, :port)
    host = Keyword.get(opts, :host, {0, 0, 0, 0})

    case GenServer.start_link(__MODULE__, {port, host, self()}) do
      {:ok, pid} ->
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

  @doc "Returns `{:ok, ip_tuple, port}` for the listening server."
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

        Logger.info(
          "#{__MODULE__}: QR payload: {probnikoff_net, {#{format_ip_tuple(local_ip)}, #{port}}}"
        )

        state = %{
          listen_socket: listen_socket,
          clients: %{},
          port: port,
          host: host_tuple,
          owner: owner,
          local_ip: local_ip
        }

        Kernel.send(self(), :accept)

        {:ok, state}

      {:error, reason} ->
        Logger.error("#{__MODULE__}: Failed to listen on port #{port}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:send, _data}, _from, %{clients: clients} = state)
      when map_size(clients) == 0 do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:send, data}, _from, %{clients: clients} = state) do
    failed =
      Enum.reduce(clients, [], fn {socket, _client_state}, failed ->
        case :gen_tcp.send(socket, data) do
          :ok -> failed
          {:error, _reason} -> [socket | failed]
        end
      end)

    # Remove clients that failed to receive
    state =
      Enum.reduce(failed, state, fn socket, state ->
        remove_client(socket, state, "send failed")
      end)

    {:reply, :ok, state}
  end

  def handle_call(:connected?, _from, %{clients: clients} = state) do
    {:reply, map_size(clients) > 0, state}
  end

  def handle_call({:controlling_process, new_owner}, _from, state) do
    {:reply, :ok, %{state | owner: new_owner}}
  end

  def handle_call(:get_server_info, _from, %{local_ip: ip, port: port} = state) do
    {:reply, {:ok, ip, port}, state}
  end

  @impl GenServer
  def handle_info(:accept, %{listen_socket: listen_socket} = state) do
    case :gen_tcp.accept(listen_socket, 100) do
      {:ok, client_socket} ->
        state = handle_new_client(client_socket, state)
        Kernel.send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
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

  def handle_info({:tcp, socket, data}, %{clients: clients, owner: owner} = state) do
    case Map.get(clients, socket) do
      nil ->
        {:noreply, state}

      %{buffer: buffer} ->
        buffer = buffer <> data
        {frames, remaining} = extract_frames(buffer)

        # Forward each complete frame to the driver
        Enum.each(frames, fn frame ->
          Kernel.send(owner, {:tcp, socket, frame})
        end)

        clients = Map.put(clients, socket, %{buffer: remaining})
        {:noreply, %{state | clients: clients}}
    end
  end

  def handle_info({:tcp_closed, socket}, %{clients: clients} = state) do
    if Map.has_key?(clients, socket) do
      state = remove_client(socket, state, "disconnected")
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:tcp_error, socket, reason}, %{clients: clients} = state) do
    if Map.has_key?(clients, socket) do
      state = remove_client(socket, state, "error: #{inspect(reason)}")
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("#{__MODULE__}: Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{listen_socket: listen, clients: clients}) do
    Enum.each(clients, fn {socket, _} ->
      :gen_tcp.close(socket)
    end)

    if listen, do: :gen_tcp.close(listen)
    :ok
  end

  # Private helpers

  defp handle_new_client(client_socket, %{clients: clients} = state) do
    {:ok, {addr, port}} = :inet.peername(client_socket)
    addr_str = format_ip(addr)
    count = map_size(clients) + 1
    Logger.info("#{__MODULE__}: Client connected from #{addr_str}:#{port} (#{count} total)")

    :inet.setopts(client_socket, active: true)
    :gen_tcp.controlling_process(client_socket, self())

    clients = Map.put(clients, client_socket, %{buffer: <<>>})
    %{state | clients: clients}
  end

  defp remove_client(socket, %{clients: clients} = state, reason) do
    :gen_tcp.close(socket)
    clients = Map.delete(clients, socket)
    count = map_size(clients)
    Logger.info("#{__MODULE__}: Client #{reason} (#{count} remaining)")
    %{state | clients: clients}
  end

  # Extract complete protocol frames from a buffer.
  # Frame format: type(1 byte) + length(4 bytes BE) + payload(length bytes)
  defp extract_frames(buffer, frames \\ [])

  defp extract_frames(<<type::8, length::big-unsigned-32, rest::binary>> = _buffer, frames)
       when byte_size(rest) >= length do
    <<payload::binary-size(length), remaining::binary>> = rest
    frame = <<type::8, length::big-unsigned-32, payload::binary>>
    extract_frames(remaining, [frame | frames])
  end

  defp extract_frames(buffer, frames) do
    {Enum.reverse(frames), buffer}
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

  @doc """
  Get the local IP address (first non-loopback IPv4).
  """
  def get_local_ip do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.flat_map(fn {_name, opts} -> non_loopback_addrs(opts) end)
        |> List.first() || {127, 0, 0, 1}

      _ ->
        {127, 0, 0, 1}
    end
  end

  defp non_loopback_addrs(opts) do
    for {:addr, {a, _, _, _} = addr} <- opts, a != 127, do: addr
  end

  def format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  def format_ip(_), do: "unknown"

  def format_ip_tuple({a, b, c, d}), do: "{#{a}, #{b}, #{c}, #{d}}"
  def format_ip_tuple(_), do: "{127, 0, 0, 1}"
end
