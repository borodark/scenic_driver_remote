defmodule ScenicDriverRemote do
  @moduledoc """
  Transport-agnostic Scenic driver for remote rendering.

  This driver serializes Scenic scripts to a binary protocol and sends them
  to a remote renderer over any supported transport (Unix socket, TCP, WebSocket).

  ## Configuration

      config :my_app, :viewport,
        size: {800, 600},
        drivers: [
          [
            module: ScenicDriverRemote,
            transport: ScenicDriverRemote.Transport.Tcp,
            host: "localhost",
            port: 4000
          ]
        ]

  ## Transport Options

  Each transport has its own specific options:

  - `ScenicDriverRemote.Transport.UnixSocket` - requires `:path`
  - `ScenicDriverRemote.Transport.Tcp` - requires `:host` and `:port`
  - `ScenicDriverRemote.Transport.WebSocket` - requires `:url`
  """

  use Scenic.Driver
  require Logger

  alias Scenic.ViewPort
  alias Scenic.Assets.Static
  alias Scenic.Assets.Stream
  alias Scenic.Script
  alias ScenicDriverRemote.Protocol
  alias ScenicDriverRemote.Protocol.Commands
  alias ScenicDriverRemote.Protocol.Events

  @opts_schema [
    name: [type: {:or, [:atom, :string]}],
    transport: [type: :atom, required: true],
    # Transport-specific options passed through
    path: [type: :string],
    host: [type: :string],
    port: [type: :integer],
    url: [type: :string],
    reconnect_interval: [type: :integer, default: 1000]
  ]

  @impl Scenic.Driver
  def validate_opts(opts), do: NimbleOptions.validate(Enum.into(opts, []), @opts_schema)

  @impl Scenic.Driver
  def init(driver, opts) do
    transport_module = opts[:transport]
    reconnect_interval = opts[:reconnect_interval] || 1000

    Logger.info("#{__MODULE__}: Initializing with transport #{inspect(transport_module)}")

    driver =
      Scenic.Driver.assign(driver,
        transport_module: transport_module,
        transport: nil,
        transport_opts: opts,
        connected: false,
        reconnect_interval: reconnect_interval,
        media: %{fonts: [], images: [], streams: []},
        recv_buffer: <<>>
      )

    # Try to connect
    driver = try_connect(driver)

    {:ok, driver}
  end

  @impl Scenic.Driver
  def reset_scene(driver) do
    Logger.debug("#{__MODULE__}: reset_scene")
    send_command(driver, Commands.reset())
    driver = Scenic.Driver.assign(driver, :media, %{fonts: [], images: [], streams: []})
    {:ok, driver}
  end

  @impl Scenic.Driver
  def clear_color(color, driver) do
    Logger.debug("#{__MODULE__}: clear_color #{inspect(color)}")
    {r, g, b, a} = normalize_color(color)
    send_command(driver, Commands.clear_color(r, g, b, a))
    {:ok, driver}
  end

  @impl Scenic.Driver
  def update_scene(ids, driver) do
    #Logger.debug("#{__MODULE__}: update_scene #{inspect(ids)}")

    driver =
      Enum.reduce(ids, driver, fn id, driver ->
        case ViewPort.get_script(driver.viewport, id) do
          {:ok, script} ->
            driver = ensure_media(script, driver)
            script_bin = script |> Script.serialize() |> IO.iodata_to_binary()
            send_command(driver, Commands.put_script(id, script_bin))
            driver

          {:error, :not_found} ->
            driver
        end
      end)

    # Trigger a render after updating scripts
    send_command(driver, Commands.render())

    {:ok, driver}
  end

  @impl Scenic.Driver
  def del_scripts(ids, driver) do
    Logger.debug("#{__MODULE__}: del_scripts #{inspect(ids)}")

    Enum.each(ids, fn id ->
      send_command(driver, Commands.del_script(id))
    end)

    {:ok, driver}
  end

  @impl Scenic.Driver
  def request_input(_inputs, driver) do
    # Input events come from the renderer
    {:ok, driver}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, driver) do
    driver = handle_incoming_data(data, driver)
    {:noreply, driver}
  end

  def handle_info({:tcp_closed, _socket}, driver) do
    Logger.warning("#{__MODULE__}: Connection closed, reconnecting...")
    driver = Scenic.Driver.assign(driver, transport: nil, connected: false)
    reconnect_interval = Scenic.Driver.get(driver, :reconnect_interval)
    Process.send_after(self(), :reconnect, reconnect_interval)
    {:noreply, driver}
  end

  def handle_info({:tcp_error, _socket, reason}, driver) do
    Logger.warning("#{__MODULE__}: Connection error: #{inspect(reason)}, reconnecting...")
    driver = Scenic.Driver.assign(driver, transport: nil, connected: false)
    reconnect_interval = Scenic.Driver.get(driver, :reconnect_interval)
    Process.send_after(self(), :reconnect, reconnect_interval)
    {:noreply, driver}
  end

  def handle_info(:reconnect, driver) do
    driver = try_connect(driver)
    {:noreply, driver}
  end

  def handle_info(msg, driver) do
    Logger.debug("#{__MODULE__}: Unhandled message: #{inspect(msg)}")
    {:noreply, driver}
  end

  # Private functions

  defp try_connect(driver) do
    transport_module = Scenic.Driver.get(driver, :transport_module)
    transport_opts = Scenic.Driver.get(driver, :transport_opts)

    case transport_module.connect(transport_opts) do
      {:ok, transport} ->
        Logger.info("#{__MODULE__}: Connected via #{inspect(transport_module)}")
        Scenic.Driver.assign(driver, transport: transport, connected: true)

      {:error, reason} ->
        Logger.warning("#{__MODULE__}: Connection failed: #{inspect(reason)}, retrying...")
        reconnect_interval = Scenic.Driver.get(driver, :reconnect_interval)
        Process.send_after(self(), :reconnect, reconnect_interval)
        driver
    end
  end

  defp send_command(driver, command) do
    transport = Scenic.Driver.get(driver, :transport)
    transport_module = Scenic.Driver.get(driver, :transport_module)

    if transport && transport_module.connected?(transport) do
      transport_module.send(transport, command)
    else
      :ok
    end
  end

  defp handle_incoming_data(data, driver) do
    buffer = Scenic.Driver.get(driver, :recv_buffer) <> data
    {events, remaining} = Events.parse_all(buffer)

    Enum.each(events, fn event ->
      handle_event(event, driver)
    end)

    Scenic.Driver.assign(driver, :recv_buffer, remaining)
  end

  defp handle_event({:ready}, driver) do
    Logger.info("#{__MODULE__}: Renderer ready, resyncing scene...")

    # Resync all current scripts to the newly connected renderer
    script_ids = ViewPort.all_script_ids(driver.viewport)
    Logger.debug("#{__MODULE__}: Resyncing #{length(script_ids)} scripts")

    Enum.each(script_ids, fn id ->
      case ViewPort.get_script(driver.viewport, id) do
        {:ok, script} ->
          script_bin = script |> Script.serialize() |> IO.iodata_to_binary()
          send_command(driver, Commands.put_script(id, script_bin))

        {:error, :not_found} ->
          :ok
      end
    end)

    # Trigger render after resync
    send_command(driver, Commands.render())
    :ok
  end

  defp handle_event({:reshape, width, height}, driver) do
    Logger.info("#{__MODULE__}: reshape #{width}x#{height}")
    Scenic.ViewPort.input(driver.viewport, {:viewport, {:reshape, {width, height}}})

    # Scene re-layouts for reshape dimensions, so use identity global transform.
    send_command(driver, Commands.global_tx(1.0, 0.0, 0.0, 1.0, 0.0, 0.0))
    send_command(driver, Commands.render())
  end

  defp handle_event({:stats, bytes_received}, _driver) do
    :persistent_term.put(:net_bytes_received, bytes_received)
  end

  defp handle_event({:touch, action, x, y}, driver) do
    input =
      case action do
        :down -> {:cursor_button, {:btn_left, 1, [], {x, y}}}
        :up -> {:cursor_button, {:btn_left, 0, [], {x, y}}}
        :move -> {:cursor_pos, {x, y}}
      end

    Scenic.ViewPort.input(driver.viewport, input)
  end

  defp handle_event({:key, key, scancode, action, mods}, driver) do
    action_atom =
      case action do
        0 -> :release
        1 -> :press
        2 -> :repeat
        _ -> :press
      end

    Scenic.ViewPort.input(driver.viewport, {:key, {key, scancode, action_atom, mods}})
  end

  defp handle_event({:codepoint, codepoint, mods}, driver) do
    Scenic.ViewPort.input(driver.viewport, {:codepoint, {codepoint, mods}})
  end

  defp handle_event({:cursor_pos, x, y}, driver) do
    Scenic.ViewPort.input(driver.viewport, {:cursor_pos, {x, y}})
  end

  defp handle_event({:mouse_button, button, action, mods, x, y}, driver) do
    action_val = if action == 1, do: 1, else: 0
    Scenic.ViewPort.input(driver.viewport, {:cursor_button, {button, action_val, mods, {x, y}}})
  end

  defp handle_event({:scroll, x_offset, y_offset, x, y}, driver) do
    Scenic.ViewPort.input(driver.viewport, {:scroll, {{x_offset, y_offset}, {x, y}}})
  end

  defp handle_event(event, _driver) do
    Logger.debug("#{__MODULE__}: Unhandled event: #{inspect(event)}")
    :ok
  end

  defp normalize_color({r, g, b}) when is_integer(r), do: {r / 255, g / 255, b / 255, 1.0}
  defp normalize_color({r, g, b, a}) when is_integer(r), do: {r / 255, g / 255, b / 255, a / 255}
  defp normalize_color({r, g, b}) when is_float(r), do: {r, g, b, 1.0}
  defp normalize_color({r, g, b, a}) when is_float(r), do: {r, g, b, a}
  defp normalize_color(_), do: {0.0, 0.0, 0.0, 1.0}

  defp ensure_media(script, driver) do
    media = Script.media(script)

    driver
    |> ensure_fonts(Map.get(media, :fonts, []))
    |> ensure_images(Map.get(media, :images, []))
    |> ensure_streams(Map.get(media, :streams, []))
  end

  defp ensure_fonts(driver, []), do: driver

  defp ensure_fonts(%{assigns: %{media: media}} = driver, ids) do
    fonts = Map.get(media, :fonts, [])

    fonts =
      Enum.reduce(ids, fonts, fn id, fonts ->
        with false <- Enum.member?(fonts, id),
             {:ok, {Static.Font, _}} <- Static.meta(id),
             {:ok, str_hash} <- Static.to_hash(id),
             {:ok, bin} <- Static.load(id) do
          send_command(driver, Commands.put_font(str_hash, bin))
          [id | fonts]
        else
          _ -> fonts
        end
      end)

    Scenic.Driver.assign(driver, :media, Map.put(media, :fonts, fonts))
  end

  defp ensure_images(driver, []), do: driver

  defp ensure_images(%{assigns: %{media: media}} = driver, ids) do
    images = Map.get(media, :images, [])

    images =
      Enum.reduce(ids, images, fn id, images ->
        with false <- Enum.member?(images, id),
             {:ok, {Static.Image, {w, h, _}}} <- Static.meta(id),
             {:ok, str_hash} <- Static.to_hash(id),
             {:ok, bin} <- Static.load(id) do
          send_command(driver, Commands.put_image(str_hash, :encoded, w, h, bin))
          [id | images]
        else
          _ -> images
        end
      end)

    Scenic.Driver.assign(driver, :media, Map.put(media, :images, images))
  end

  defp ensure_streams(driver, []), do: driver

  defp ensure_streams(%{assigns: %{media: media}} = driver, ids) do
    streams = Map.get(media, :streams, [])

    streams =
      Enum.reduce(ids, streams, fn id, streams ->
        with false <- Enum.member?(streams, id),
             :ok <- Stream.subscribe(id) do
          case Stream.fetch(id) do
            {:ok, {Stream.Image, {w, h, _format}, bin}} ->
              send_command(driver, Commands.put_image(id, :encoded, w, h, bin))
              [id | streams]

            {:ok, {Stream.Bitmap, {w, h, format}, bin}} ->
              send_command(driver, Commands.put_image(id, format, w, h, bin))
              [id | streams]

            _ ->
              streams
          end
        else
          _ -> streams
        end
      end)

    Scenic.Driver.assign(driver, :media, Map.put(media, :streams, streams))
  end
end
