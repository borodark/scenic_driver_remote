defmodule ScenicDriverRemote.Protocol.Commands do
  @moduledoc """
  Command encoding for the Scenic remote rendering protocol.

  Commands are sent from the driver to the renderer.
  """

  alias ScenicDriverRemote.Protocol

  @doc """
  Encode a PUT_SCRIPT command.

  Stores or updates a script for rendering.

      Payload:
        id_len:    u32     - Length of script ID
        id:        bytes   - Script ID (binary)
        script:    bytes   - Serialized Scenic script (remaining bytes)
  """
  @spec put_script(term(), binary()) :: iodata()
  def put_script(id, script_bin) do
    id_bin = Protocol.encode_id(id)
    id_len = byte_size(id_bin)

    Protocol.encode_message(
      Protocol.cmd_put_script(),
      [<<id_len::big-unsigned-32>>, id_bin, script_bin]
    )
  end

  @doc """
  Encode a DEL_SCRIPT command.

  Deletes a script.

      Payload:
        id_len:    u32     - Length of script ID
        id:        bytes   - Script ID to delete
  """
  @spec del_script(term()) :: iodata()
  def del_script(id) do
    id_bin = Protocol.encode_id(id)
    id_len = byte_size(id_bin)

    Protocol.encode_message(
      Protocol.cmd_del_script(),
      [<<id_len::big-unsigned-32>>, id_bin]
    )
  end

  @doc """
  Encode a RESET command.

  Clears all scripts, fonts, and images.

      Payload: (empty)
  """
  @spec reset() :: iodata()
  def reset do
    Protocol.encode_message(Protocol.cmd_reset(), <<>>)
  end

  @doc """
  Encode a CLEAR_COLOR command.

  Sets the background clear color.

      Payload:
        r:         f32     - Red (0.0 - 1.0)
        g:         f32     - Green (0.0 - 1.0)
        b:         f32     - Blue (0.0 - 1.0)
        a:         f32     - Alpha (0.0 - 1.0)
  """
  @spec clear_color(float(), float(), float(), float()) :: iodata()
  def clear_color(r, g, b, a) do
    Protocol.encode_message(
      Protocol.cmd_clear_color(),
      <<r::big-float-32, g::big-float-32, b::big-float-32, a::big-float-32>>
    )
  end

  @doc """
  Encode a PUT_FONT command.

  Loads a font.

      Payload:
        name_len:  u32     - Length of font name
        data_len:  u32     - Length of font data
        name:      bytes   - Font name (UTF-8)
        data:      bytes   - Font file data (TTF/OTF)
  """
  @spec put_font(binary() | String.t(), binary()) :: iodata()
  def put_font(name, font_data) do
    name_bin = if is_binary(name), do: name, else: to_string(name)
    name_len = byte_size(name_bin)
    data_len = byte_size(font_data)

    Protocol.encode_message(
      Protocol.cmd_put_font(),
      [<<name_len::big-unsigned-32, data_len::big-unsigned-32>>, name_bin, font_data]
    )
  end

  @doc """
  Encode a PUT_IMAGE command.

  Loads an image/texture.

      Payload:
        id_len:    u32     - Length of image ID
        data_len:  u32     - Length of image data
        width:     u32     - Image width (0 if encoded format)
        height:    u32     - Image height (0 if encoded format)
        format:    u32     - Image format (see below)
        id:        bytes   - Image ID
        data:      bytes   - Image data

  Image formats:
    - 0: Encoded file (PNG, JPEG - decoder determines dimensions)
    - 1: Grayscale (1 byte/pixel)
    - 2: Grayscale + Alpha (2 bytes/pixel)
    - 3: RGB (3 bytes/pixel)
    - 4: RGBA (4 bytes/pixel)
  """
  @spec put_image(term(), atom(), non_neg_integer(), non_neg_integer(), binary()) :: iodata()
  def put_image(id, format, width, height, image_data) do
    id_bin = Protocol.encode_id(id)
    id_len = byte_size(id_bin)
    data_len = byte_size(image_data)
    format_int = Protocol.image_format_to_int(format)

    Protocol.encode_message(
      Protocol.cmd_put_image(),
      [
        <<
          id_len::big-unsigned-32,
          data_len::big-unsigned-32,
          width::big-unsigned-32,
          height::big-unsigned-32,
          format_int::big-unsigned-32
        >>,
        id_bin,
        image_data
      ]
    )
  end

  @doc """
  Encode a RENDER command.

  Triggers a frame render.

      Payload: (empty)
  """
  @spec render() :: iodata()
  def render do
    Protocol.encode_message(Protocol.cmd_render(), <<>>)
  end

  @doc """
  Encode a GLOBAL_TX command.

  Sets the global transform matrix.

      Payload:
        a, b, c, d, e, f: f32 - Transform matrix components
  """
  @spec global_tx(float(), float(), float(), float(), float(), float()) :: iodata()
  def global_tx(a, b, c, d, e, f) do
    Protocol.encode_message(
      Protocol.cmd_global_tx(),
      <<
        a::big-float-32,
        b::big-float-32,
        c::big-float-32,
        d::big-float-32,
        e::big-float-32,
        f::big-float-32
      >>
    )
  end

  @doc """
  Encode a QUIT command.

  Shuts down the renderer.

      Payload: (empty)
  """
  @spec quit() :: iodata()
  def quit do
    Protocol.encode_message(Protocol.cmd_quit(), <<>>)
  end
end
