# ScenicDriverRemote

Transport-agnostic Scenic driver that serializes Scenic scripts to a binary protocol and sends them to a remote renderer over any supported transport.

## Installation

Add `scenic_driver_remote` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:scenic_driver_remote, "~> 0.1.0"}
  ]
end
```

## Usage

Configure the driver in your Scenic application:

```elixir
config :my_app, :viewport,
  size: {800, 600},
  default_scene: MyApp.Scene.Home,
  drivers: [
    [
      module: ScenicDriverRemote,
      transport: ScenicDriverRemote.Transport.Tcp,
      host: "localhost",
      port: 4000
    ]
  ]
```

### Available Transports

- `ScenicDriverRemote.Transport.UnixSocket` - Unix domain socket (local IPC)
- `ScenicDriverRemote.Transport.Tcp` - TCP socket (remote debugging, cross-machine)
- `ScenicDriverRemote.Transport.WebSocket` - WebSocket (browser-based renderers, requires `websockex`)

### Unix Socket Example

```elixir
drivers: [
  [
    module: ScenicDriverRemote,
    transport: ScenicDriverRemote.Transport.UnixSocket,
    path: "/tmp/scenic.sock"
  ]
]
```

### TCP Example

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

## Protocol

The driver uses a binary protocol with big-endian encoding. See `ScenicDriverRemote.Protocol` for details.

## License

Apache-2.0
