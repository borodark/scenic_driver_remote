# ScenicDriverRemote

Transport-agnostic Scenic driver for remote rendering. Serializes Scenic
scripts to a compact binary protocol and sends them over TCP, Unix socket,
or WebSocket to a remote renderer (Android, iOS, browser, desktop).

## Architecture

```
+------------------+       binary protocol        +------------------+
|  BEAM / Scenic   | --------------------------> |  Remote Renderer  |
|  ViewPort        | <--- events (touch, keys) --|  (Android / iOS)  |
|  + this driver   |       TCP / WS / Unix       |  Canvas / Metal   |
+------------------+                              +------------------+
```

This driver implements the BEAM/Elixir side of the [Scenic Remote Protocol](../SCENIC_REMOTE_PROTOCOL.md). It converts Scenic script operations (put_script, del_script, reset, render) into framed binary messages and pushes them to the renderer. The renderer sends back input events (touch, reshape, keyboard) which the driver translates into Scenic input events.

**Related**: [scenic_renderer_native](https://github.com/borodark/scenic_renderer_native) - C library implementing the renderer side

### Multi-client support (TcpServer)

`TcpServer` accepts multiple simultaneous connections. Commands are broadcast
to every connected client; events from any client are forwarded to the
Scenic driver. Per-client receive buffers prevent interleaved partial frames
from corrupting the protocol parser.

## Installation

```elixir
# mix.exs
def deps do
  [
    {:scenic_driver_remote, path: "../scenic_driver_remote"}
    # or from git:
    # {:scenic_driver_remote, git: "https://github.com/borodark/scenic_driver_remote.git"}
  ]
end
```

## Quick start

### TcpServer (recommended for mobile renderers)

The server listens on a port; mobile apps connect to it.

```elixir
viewport_config = [
  name: :main_viewport,
  size: {1080, 2400},
  default_scene: MyApp.Scene.Main,
  drivers: [
    [
      module: ScenicDriverRemote,
      transport: ScenicDriverRemote.Transport.TcpServer,
      port: 4040
    ]
  ]
]

Scenic.start_link([viewport_config])
```

### TCP client

The driver connects to a renderer already listening somewhere.

```elixir
drivers: [
  [
    module: ScenicDriverRemote,
    transport: ScenicDriverRemote.Transport.Tcp,
    host: "192.168.1.100",
    port: 4000
  ]
]
```

### Unix socket

For local IPC (e.g. a co-located native renderer).

```elixir
drivers: [
  [
    module: ScenicDriverRemote,
    transport: ScenicDriverRemote.Transport.UnixSocket,
    path: "/tmp/scenic.sock"
  ]
]
```

### WebSocket

For browser-based renderers. Requires `{:websockex, "~> 0.4"}` in deps.

```elixir
drivers: [
  [
    module: ScenicDriverRemote,
    transport: ScenicDriverRemote.Transport.WebSocket,
    url: "ws://localhost:4000/scenic"
  ]
]
```

## Driver options

| Option | Type | Default | Description |
|---|---|---|---|
| `transport` | atom | *required* | Transport module |
| `port` | integer | | Port (TcpServer, Tcp) |
| `host` | string/tuple | `{0,0,0,0}` | Bind address (TcpServer) or remote host (Tcp) |
| `path` | string | | Socket path (UnixSocket) |
| `url` | string | | WebSocket URL |
| `reconnect_interval` | integer | 1000 | ms between reconnection attempts |

## Binary Protocol

See [SCENIC_REMOTE_PROTOCOL.md](SCENIC_REMOTE_PROTOCOL.md) for the complete protocol specification.

### Quick Reference

All messages share one frame format:

```
+--------+----------------+------------------+
| Type   | Length         | Payload          |
| 1 byte | 4 bytes BE    | Length bytes      |
+--------+----------------+------------------+
```

### Commands (driver -> renderer)

| Code | Name | Payload |
|------|------|---------|
| 0x01 | PUT_SCRIPT | id_len:u32 id:bytes script:bytes |
| 0x02 | DEL_SCRIPT | id_len:u32 id:bytes |
| 0x03 | RESET | *(empty)* |
| 0x04 | GLOBAL_TX | a:f32 b:f32 c:f32 d:f32 e:f32 f:f32 |
| 0x05 | CURSOR_TX | a:f32 b:f32 c:f32 d:f32 e:f32 f:f32 |
| 0x06 | RENDER | *(empty)* |
| 0x08 | CLEAR_COLOR | r:f32 g:f32 b:f32 a:f32 |
| 0x0A | REQUEST_INPUT | flags:u32 |
| 0x20 | QUIT | *(empty)* |
| 0x40 | PUT_FONT | name_len:u32 data_len:u32 name:bytes data:bytes |
| 0x41 | PUT_IMAGE | id_len:u32 data_len:u32 w:u32 h:u32 fmt:u32 id:bytes data:bytes |

### Events (renderer -> driver)

| Code | Name | Payload |
|------|------|---------|
| 0x01 | STATS | bytes_received:u64 |
| 0x05 | RESHAPE | width:u32 height:u32 |
| 0x06 | READY | *(empty)* |
| 0x08 | TOUCH | action:u8 x:f32 y:f32 |
| 0x0A | KEY | key:u32 scancode:u32 action:i32 mods:u32 |
| 0x0B | CODEPOINT | codepoint:u32 mods:u32 |
| 0x0C | CURSOR_POS | x:f32 y:f32 |
| 0x0D | MOUSE_BUTTON | button:u32 action:u32 mods:u32 x:f32 y:f32 |
| 0x0E | SCROLL | x_off:f32 y_off:f32 x:f32 y:f32 |
| 0x0F | CURSOR_ENTER | entered:u8 |
| 0xA0 | LOG_INFO | message:bytes |
| 0xA1 | LOG_WARN | message:bytes |
| 0xA2 | LOG_ERROR | message:bytes |

Numeric encoding: **u32** = unsigned 32-bit big-endian, **i32** = signed,
**f32** = IEEE 754 float big-endian, **u8** = single byte, **u64** = unsigned 64-bit BE.

### Connection lifecycle

1. Client connects (TCP handshake).
2. Client sends **READY** event.
3. Driver resyncs all scripts + fonts + images, then sends **RENDER**.
4. Client sends **RESHAPE** with its screen dimensions.
5. Driver computes GLOBAL_TX (scale + offset) and sends it.
6. Normal operation: scene updates flow as PUT_SCRIPT + RENDER; input flows back.

## Viewport sizing

Set `size: {w, h}` to the pixel resolution of your primary target device:

```elixir
size: {1080, 2400}   # Android 1080p tall
size: {1179, 2556}   # iPhone 15 Pro
```

When a client connects and sends RESHAPE with its actual screen size, the
driver computes a uniform-scale + center-offset transform (GLOBAL_TX) so the
scene fits the screen with letterbox bars if aspect ratios differ.

## Custom transport

Implement the `ScenicDriverRemote.Transport` behaviour:

```elixir
defmodule MyTransport do
  @behaviour ScenicDriverRemote.Transport

  defstruct [:conn]

  @impl true
  def connect(opts), do: {:ok, %__MODULE__{conn: ...}}

  @impl true
  def disconnect(t), do: :ok

  @impl true
  def send(t, data), do: ...

  @impl true
  def connected?(t), do: true

  @impl true
  def controlling_process(t, pid), do: :ok
end
```

The transport must deliver incoming data to the owner process as
`{:tcp, socket_or_ref, binary_data}` messages.

## Tests

```bash
mix test
```

57 tests covering protocol encoding/decoding, event parsing, TcpServer
multi-client connections, frame buffering, and broadcast.

## Related Projects

- [scenic_renderer_native](https://github.com/borodark/scenic_renderer_native) - C renderer implementation
- [scenic_driver_local](https://github.com/ScenicFramework/scenic_driver_local) - Canonical protocol source
- [Scenic](https://github.com/ScenicFramework/scenic) - Elixir UI framework

## License

Apache-2.0
