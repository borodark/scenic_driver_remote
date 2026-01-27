defmodule ScenicDriverRemote.Transport do
  @moduledoc """
  Transport behaviour for Scenic remote rendering.

  Implement this behaviour to create custom transports.
  """

  @type t :: struct()

  @doc """
  Connect to a remote renderer.

  Options are transport-specific. Returns {:ok, transport} on success.
  """
  @callback connect(opts :: keyword()) :: {:ok, t()} | {:error, term()}

  @doc """
  Disconnect from the renderer.
  """
  @callback disconnect(t()) :: :ok

  @doc """
  Send data to the renderer.
  """
  @callback send(t(), iodata()) :: :ok | {:error, term()}

  @doc """
  Check if currently connected.
  """
  @callback connected?(t()) :: boolean()

  @doc """
  Transfer ownership of the underlying connection to another process.
  """
  @callback controlling_process(t(), pid()) :: :ok | {:error, term()}
end
