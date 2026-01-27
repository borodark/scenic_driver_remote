defmodule ScenicDriverRemote.Transport.Tcp do
  @moduledoc """
  TCP socket transport for remote rendering.

  ## Options

  - `:host` - Required. Hostname or IP address to connect to.
  - `:port` - Required. Port number to connect to.

  ## Example

      ScenicDriverRemote.Transport.Tcp.connect(host: "localhost", port: 4000)
  """

  @behaviour ScenicDriverRemote.Transport

  defstruct [:socket, :host, :port]

  @impl true
  def connect(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)

    host_charlist =
      cond do
        is_binary(host) -> String.to_charlist(host)
        is_list(host) -> host
        true -> to_charlist(host)
      end

    case :gen_tcp.connect(host_charlist, port, [:binary, active: true, packet: :raw]) do
      {:ok, socket} ->
        {:ok, %__MODULE__{socket: socket, host: host, port: port}}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def disconnect(%__MODULE__{socket: socket}) do
    :gen_tcp.close(socket)
    :ok
  end

  @impl true
  def send(%__MODULE__{socket: socket}, data) do
    case :gen_tcp.send(socket, data) do
      :ok -> :ok
      error -> error
    end
  end

  @impl true
  def connected?(%__MODULE__{socket: socket}) do
    case :inet.peername(socket) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @impl true
  def controlling_process(%__MODULE__{socket: socket}, pid) do
    :gen_tcp.controlling_process(socket, pid)
  end
end
