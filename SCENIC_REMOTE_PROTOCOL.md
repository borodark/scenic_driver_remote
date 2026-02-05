# Scenic Remote Rendering Protocol Specification

**Version 1.0** | **Canonical Source**: [scenic_driver_local](https://github.com/ScenicFramework/scenic_driver_local)

This document specifies the binary protocol used for communication between a Scenic driver (BEAM/Elixir) and a native renderer (Android, iOS, desktop, browser).

## Overview

```
+------------------+       binary protocol        +------------------+
|  BEAM / Scenic   | --------------------------> |  Remote Renderer  |
|  ViewPort        | <--- events (touch, keys) --|  (Android / iOS)  |
|  + driver        |       TCP / WS / Unix       |  Canvas / Metal   |
+------------------+                              +------------------+
```

The driver serializes Scenic script operations into framed binary messages and pushes them to the renderer. The renderer sends back input events which the driver translates into Scenic input events.

## Implementations

| Component | Language | Repository |
|-----------|----------|------------|
| scenic_driver_remote | Elixir | [scenic_driver_remote](https://github.com/borodark/scenic_driver_remote) |
| scenic_renderer_native | C | [scenic_renderer_native](https://github.com/borodark/scenic_renderer_native) |

## Frame Format

All messages (commands and events) share one frame format:

```
+--------+----------------+------------------+
| Type   | Length         | Payload          |
| 1 byte | 4 bytes BE     | Length bytes     |
+--------+----------------+------------------+
```

- **Type**: Command or event identifier (uint8)
- **Length**: Payload length in bytes (uint32, big-endian)
- **Payload**: Type-specific binary data

Header size: **5 bytes**

## Numeric Encoding

| Type | Size | Encoding |
|------|------|----------|
| u8 | 1 byte | unsigned |
| i32 | 4 bytes | big-endian, signed |
| u32 | 4 bytes | big-endian, unsigned |
| u64 | 8 bytes | big-endian, unsigned |
| f32 | 4 bytes | IEEE 754 single precision, big-endian |

## Commands (Driver -> Renderer)

Commands flow from the Scenic driver to the native renderer.

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

### Command Details

#### PUT_SCRIPT (0x01)
Store or update a script for rendering.
```
Payload:
  id_len:    u32     - Length of script ID
  id:        bytes   - Script ID (binary string)
  script:    bytes   - Serialized Scenic script (remaining bytes)
```

#### DEL_SCRIPT (0x02)
Delete a script.
```
Payload:
  id_len:    u32     - Length of script ID
  id:        bytes   - Script ID to delete
```

#### RESET (0x03)
Clear all scripts, fonts, and images.
```
Payload: (empty)
```

#### GLOBAL_TX (0x04)
Set global transformation matrix (2D affine transform).
```
Payload:
  a:         f32     - Scale X
  b:         f32     - Skew Y
  c:         f32     - Skew X
  d:         f32     - Scale Y
  e:         f32     - Translate X
  f:         f32     - Translate Y

Matrix form:
  | a  c  e |
  | b  d  f |
  | 0  0  1 |
```

#### CURSOR_TX (0x05)
Set cursor transformation matrix.
```
Payload: (same as GLOBAL_TX)
```

#### RENDER (0x06)
Trigger a frame render.
```
Payload: (empty)
```

#### CLEAR_COLOR (0x08)
Set the background clear color.
```
Payload:
  r:         f32     - Red (0.0 - 1.0)
  g:         f32     - Green (0.0 - 1.0)
  b:         f32     - Blue (0.0 - 1.0)
  a:         f32     - Alpha (0.0 - 1.0)
```

#### REQUEST_INPUT (0x0A)
Request specific input types.
```
Payload:
  flags:     u32     - Input type flags (bitmask)
```

#### QUIT (0x20)
Shutdown the renderer.
```
Payload: (empty)
```

#### PUT_FONT (0x40)
Load a font.
```
Payload:
  name_len:  u32     - Length of font name/hash
  data_len:  u32     - Length of font data
  name:      bytes   - Font name/hash (UTF-8)
  data:      bytes   - Font file data (TTF/OTF)
```

#### PUT_IMAGE (0x41)
Load an image/texture.
```
Payload:
  id_len:    u32     - Length of image ID
  data_len:  u32     - Length of image data
  width:     u32     - Image width (0 if encoded format)
  height:    u32     - Image height (0 if encoded format)
  format:    u32     - Image format (see below)
  id:        bytes   - Image ID/hash
  data:      bytes   - Image data
```

## Events (Renderer -> Driver)

Events flow from the native renderer back to the Scenic driver.

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

### Event Details

#### STATS (0x01)
Statistics report from renderer.
```
Payload:
  bytes_received: u64 - Total bytes received
```

#### RESHAPE (0x05)
Window/viewport resize notification.
```
Payload:
  width:     u32     - New width in pixels
  height:    u32     - New height in pixels
```

#### READY (0x06)
Renderer is initialized and ready to receive commands.
```
Payload: (empty)
```

#### TOUCH (0x08)
Touch/pointer event.
```
Payload:
  action:    u8      - Touch action (see below)
  x:         f32     - X coordinate
  y:         f32     - Y coordinate
```

Touch actions:
- 0: DOWN (finger pressed)
- 1: UP (finger released)
- 2: MOVE (finger moved)

#### KEY (0x0A)
Keyboard key event.
```
Payload:
  key:       u32     - Key code
  scancode:  u32     - Hardware scancode
  action:    i32     - 0=release, 1=press, 2=repeat
  mods:      u32     - Modifier flags
```

#### CODEPOINT (0x0B)
Unicode character input.
```
Payload:
  codepoint: u32     - Unicode codepoint
  mods:      u32     - Modifier flags
```

#### CURSOR_POS (0x0C)
Mouse cursor movement.
```
Payload:
  x:         f32     - X coordinate
  y:         f32     - Y coordinate
```

#### MOUSE_BUTTON (0x0D)
Mouse button event.
```
Payload:
  button:    u32     - Button ID (0=left, 1=right, 2=middle)
  action:    u32     - 0=release, 1=press
  mods:      u32     - Modifier flags
  x:         f32     - X coordinate
  y:         f32     - Y coordinate
```

#### SCROLL (0x0E)
Scroll wheel event.
```
Payload:
  x_offset:  f32     - Horizontal scroll amount
  y_offset:  f32     - Vertical scroll amount
  x:         f32     - Cursor X coordinate
  y:         f32     - Cursor Y coordinate
```

#### CURSOR_ENTER (0x0F)
Cursor entered/left window.
```
Payload:
  entered:   u8      - 1=entered, 0=left
```

#### LOG_INFO/WARN/ERROR (0xA0-0xA2)
Log messages from renderer.
```
Payload:
  message:   bytes   - UTF-8 log message
```

## Image Formats

| Code | Name | Description |
|------|------|-------------|
| 0 | ENCODED | Compressed file (PNG, JPEG) - decoder determines dimensions |
| 1 | GRAY | Grayscale, 1 byte/pixel |
| 2 | GRAY_A | Grayscale + Alpha, 2 bytes/pixel |
| 3 | RGB | RGB, 3 bytes/pixel |
| 4 | RGBA | RGBA, 4 bytes/pixel |

## Connection Lifecycle

```
Renderer                          Driver
    |                                |
    |<-------- TCP connect ----------|
    |                                |
    |-------- READY event --------->|
    |                                |
    |<-- PUT_FONT (for each font) --|
    |<-- PUT_IMAGE (for each img) --|
    |<-- PUT_SCRIPT (for each) -----|
    |<-------- RENDER --------------|
    |                                |
    |-------- RESHAPE event ------->|
    |                                |
    |<-------- GLOBAL_TX -----------|
    |<-------- RENDER --------------|
    |                                |
    |   (normal operation loop)      |
    |                                |
    |<-- PUT_SCRIPT (updates) ------|
    |<-------- RENDER --------------|
    |                                |
    |-------- TOUCH event --------->|
    |-------- KEY event ----------->|
    |           ...                  |
```

1. Client connects (TCP/Unix socket handshake)
2. Renderer sends **READY** event
3. Driver resyncs all fonts, images, and scripts
4. Driver sends **RENDER**
5. Renderer sends **RESHAPE** with its screen dimensions
6. Driver computes GLOBAL_TX (scale + offset) and sends it
7. Normal operation: scene updates flow as PUT_SCRIPT + RENDER; input flows back

## Viewport Scaling

The driver maintains a "design size" (the viewport size in Scenic). When the renderer sends RESHAPE with actual screen dimensions, the driver computes a transformation matrix:

```
scale_x = screen_width / design_width
scale_y = screen_height / design_height

GLOBAL_TX = (scale_x, 0, 0, scale_y, 0, 0)
```

This stretches the design canvas to fill the device screen. For aspect-ratio-preserving scaling with letterboxing:

```
scale = min(scale_x, scale_y)
offset_x = (screen_width - design_width * scale) / 2
offset_y = (screen_height - design_height * scale) / 2

GLOBAL_TX = (scale, 0, 0, scale, offset_x, offset_y)
```

## Transport Options

The protocol is transport-agnostic. Supported transports:

| Transport | Use Case |
|-----------|----------|
| Unix Socket | Local IPC (Android/iOS with co-located BEAM) |
| TCP | Remote rendering, debugging, multi-device |
| WebSocket | Browser-based renderers |

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-02 | Initial specification, aligned with scenic_driver_local |

## License

Apache-2.0
