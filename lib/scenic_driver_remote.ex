defmodule ScenicDriverRemote do
  @moduledoc """
  Transport-agnostic Scenic driver for remote rendering.

  This driver serializes Scenic scripts to a binary protocol and sends them
  to a remote renderer over any supported transport (Unix socket, TCP, WebSocket).

  ## Configuration

      config :my_app, :viewport,
        size: {1080, 2400},
        default_scene: MyApp.Scene.Main,
        drivers: [
          [
            module: ScenicDriverRemote,
            transport: ScenicDriverRemote.Transport.TcpServer,
            port: 4040
          ]
        ]

  ## Viewport Size

  The `size: {w, h}` in the viewport config declares the **logical canvas** your
  scene renders into. Set it to the pixel resolution of your primary target device:

      # Android phone (1080p tall)
      size: {1080, 2400}

      # iPhone (logical points × 3 = pixels, but use pixels here)
      size: {1179, 2556}

  The scene's `init/3` receives this as `scene.viewport.size` and uses it to
  compute layout (widget sizes, padding, font sizes, etc.).

  ### What happens on the device

  When the remote client (Android/iOS app) connects, it reports its actual screen
  size via a `RESHAPE` event. The driver then:

  1. Forwards the reshape to the scene (so it can optionally re-layout).
  2. Computes a **GLOBAL_TX** transform that scales and centers the viewport
     canvas onto the device screen (letterbox fit).

  **If the device matches the viewport config** (e.g. `size: {1080, 2400}` and
  the Android phone is 1080×2400), GLOBAL_TX is identity — the scene renders 1:1.

  **If the device differs** (e.g. an iPhone at 1179×2556), GLOBAL_TX scales the
  1080×2400 canvas uniformly to fit inside 1179×2556, with centering offsets to
  fill any leftover margin.

  In practice: set `size` to your most common target device. Other devices will
  see the same content scaled to fit, with small letterbox bars if aspect ratios
  differ.

  ## Transport Options

  Each transport has its own specific options:

  - `ScenicDriverRemote.Transport.UnixSocket` - requires `:path`
  - `ScenicDriverRemote.Transport.Tcp` - requires `:host` and `:port`
  - `ScenicDriverRemote.Transport.TcpServer` - requires `:port` (listens for connections)
  - `ScenicDriverRemote.Transport.WebSocket` - requires `:url`

  ## Scaling / Coordinate Spaces

  Three coordinate spaces are involved in rendering:

  1. **Base design space** — the reference resolution a scene was authored for
     (e.g. `@base_width 1668, @base_height 2388` in the scene module).
     Padding, gaps, and font sizes are expressed relative to this size.

  2. **Viewport config space** — the `size: {w, h}` from the viewport config.
     The scene's `init/3` reads `scene.viewport.size` and scales from base → viewport.

  3. **Device pixel space** — the actual screen pixels reported by the remote
     client via the `RESHAPE` event (e.g. 1080×2400 on Android, 1179×2556 on iPhone).

  ### RESHAPE flow

  When the client sends `RESHAPE(device_w, device_h)`:

  1. The event is forwarded to the scene as `{:viewport, {:reshape, {w, h}}}`.
     If the scene handles this, it can re-layout its graph for the device dimensions.

  2. The driver computes a **GLOBAL_TX** affine transform that maps from
     viewport config space → device pixel space (uniform scale + centering):

         scale = min(device_w / vp_w, device_h / vp_h)
         tx    = (device_w - vp_w * scale) / 2
         ty    = (device_h - vp_h * scale) / 2

     This is sent to the client as `global_tx(scale, 0, 0, scale, tx, ty)`.

  ### Important: double-scaling caveat

  If the scene **also** re-layouts on reshape (using device dimensions directly),
  then scene coordinates are already in device pixel space and the GLOBAL_TX
  scaling is applied on top — causing content to overflow the viewport.

  This is invisible when viewport config matches the device exactly (e.g.
  Android NET at 1080×2400) because GLOBAL_TX becomes identity. On any device
  with a different resolution the overflow becomes visible.

  **To avoid double-scaling**, either:
  - The scene should ignore reshape and always render in viewport config space
    (let GLOBAL_TX handle adaptation), **or**
  - The driver should send identity GLOBAL_TX when the scene handles reshape.
  """

  use Scenic.Driver
  require Logger
  import Bitwise, only: [band: 2]

  alias Scenic.ViewPort
  alias Scenic.Assets.Static
  alias Scenic.Assets.Stream
  alias Scenic.Script
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
    # Logger.debug("#{__MODULE__}: update_scene #{inspect(ids)}")

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

  # Client reports its actual screen size in device pixels.
  #
  # Two things happen:
  #   1. Forward to scene — scene may re-layout its graph for the new dimensions.
  #   2. Compute GLOBAL_TX — uniform scale + centering that maps from the
  #      configured viewport size (e.g. 1080×2400) to the reported device size.
  #
  # NOTE: if the scene re-layouts using {width, height} directly, the scene
  # coordinates are already in device-pixel space and the GLOBAL_TX scaling
  # is redundant (see @moduledoc "double-scaling caveat").
  defp handle_event({:reshape, width, height}, driver) do
    Scenic.ViewPort.input(driver.viewport, {:viewport, {:reshape, {width, height}}})

    # Scale from viewport config space → device pixel space (letterbox fit)
    {vp_w, vp_h} = driver.viewport.size
    sx = width / vp_w
    sy = height / vp_h
    scale = min(sx, sy)

    # Center content when aspect ratios differ
    rendered_w = vp_w * scale
    rendered_h = vp_h * scale
    tx = (width - rendered_w) / 2.0
    ty = (height - rendered_h) / 2.0

    Logger.info(
      "#{__MODULE__}: reshape #{width}x#{height} vp=#{vp_w}x#{vp_h} scale=#{scale} offset=#{tx},#{ty}"
    )

    send_command(driver, Commands.global_tx(scale, 0.0, 0.0, scale, tx, ty))
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

  defp handle_event({:key, key, _scancode, action, mods}, driver) do
    key_atom = if is_atom(key), do: key, else: :"key_#{key}"
    Scenic.ViewPort.input(driver.viewport, {:key, {key_atom, action, int_to_mods(mods)}})
  end

  defp handle_event({:codepoint, codepoint, mods}, driver) do
    Scenic.ViewPort.input(driver.viewport, {:codepoint, {codepoint, mods}})
  end

  defp handle_event({:cursor_pos, x, y}, driver) do
    Scenic.ViewPort.input(driver.viewport, {:cursor_pos, {x, y}})
  end

  defp handle_event({:mouse_button, button, action, mods, x, y}, driver) do
    action_val = if action == 1, do: 1, else: 0
    btn = button_to_atom(button)

    Scenic.ViewPort.input(
      driver.viewport,
      {:cursor_button, {btn, action_val, int_to_mods(mods), {x, y}}}
    )
  end

  defp handle_event({:scroll, x_offset, y_offset, x, y}, driver) do
    Scenic.ViewPort.input(driver.viewport, {:cursor_scroll, {{x_offset, y_offset}, {x, y}}})
  end

  defp handle_event(event, _driver) do
    Logger.debug("#{__MODULE__}: Unhandled event: #{inspect(event)}")
    :ok
  end

  # GLFW modifier bitmask → Scenic modifier atom list
  @mod_bits [
    {0x0001, :shift},
    {0x0002, :ctrl},
    {0x0004, :alt},
    {0x0008, :meta},
    {0x0010, :caps_lock},
    {0x0020, :num_lock}
  ]

  defp int_to_mods(mods) when is_integer(mods) do
    for {bit, atom} <- @mod_bits, band(mods, bit) != 0, do: atom
  end

  defp int_to_mods(mods) when is_list(mods), do: mods
  defp int_to_mods(_), do: []

  defp button_to_atom(0), do: :left
  defp button_to_atom(1), do: :right
  defp button_to_atom(2), do: :middle
  defp button_to_atom(n) when is_integer(n), do: :"button_#{n}"
  defp button_to_atom(a) when is_atom(a), do: a

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
          load_stream(driver, id, streams)
        else
          _ -> streams
        end
      end)

    Scenic.Driver.assign(driver, :media, Map.put(media, :streams, streams))
  end

  defp load_stream(driver, id, streams) do
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
  end
end
