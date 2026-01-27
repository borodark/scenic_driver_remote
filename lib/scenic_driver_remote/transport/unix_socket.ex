defmodule ScenicDriverRemote.Transport.UnixSocket do
  @moduledoc """
  Unix domain socket transport for local IPC.

  ## Options

  - `:path` - Required. Path to the Unix socket file.

  ## Example

      ScenicDriverRemote.Transport.UnixSocket.connect(path: "/tmp/scenic.sock")
  """

  @behaviour ScenicDriverRemote.Transport

  defstruct [:socket, :path]

  @impl true
  def connect(opts) do
    path = Keyword.fetch!(opts, :path)

    case :gen_tcp.connect({:local, path}, 0, [:binary, active: true, packet: :raw]) do
      {:ok, socket} ->
        {:ok, %__MODULE__{socket: socket, path: path}}

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
