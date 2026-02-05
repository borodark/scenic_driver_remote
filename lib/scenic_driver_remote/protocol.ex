defmodule ScenicDriverRemote.Protocol do
  @moduledoc """
  Binary protocol for Scenic remote rendering.

  ## Frame Format

  All messages use the same frame format:

      +--------+----------------+------------------+
      | Type   | Length         | Payload          |
      | 1 byte | 4 bytes BE     | Length bytes     |
      +--------+----------------+------------------+

  - Type: Command or event identifier (uint8)
  - Length: Payload length in bytes (uint32, big-endian)
  - Payload: Type-specific binary data

  ## Numeric Encoding

  - uint8: 1 byte, unsigned
  - int32: 4 bytes, big-endian, signed
  - uint32: 4 bytes, big-endian, unsigned
  - float32: 4 bytes, IEEE 754 single precision, big-endian
  """

  @protocol_version 1

  # Message header size
  @header_size 5

  # Commands (driver -> renderer)
  # Values from scenic_driver_local (canonical source)
  @cmd_put_script 0x01
  @cmd_del_script 0x02
  @cmd_reset 0x03
  @cmd_global_tx 0x04
  @cmd_cursor_tx 0x05
  @cmd_render 0x06
  @cmd_clear_color 0x08
  @cmd_request_input 0x0A
  @cmd_quit 0x20
  @cmd_put_font 0x40
  @cmd_put_image 0x41

  # Events (renderer -> driver)
  # Values from scenic_driver_local (canonical source)
  @evt_reshape 0x05
  @evt_ready 0x06
  @evt_touch 0x08
  @evt_key 0x0A
  @evt_codepoint 0x0B
  @evt_cursor_pos 0x0C
  @evt_mouse_button 0x0D
  @evt_scroll 0x0E
  @evt_cursor_enter 0x0F
  @evt_log_info 0xA0
  @evt_log_warn 0xA1
  @evt_log_error 0xA2

  # Image formats
  @img_fmt_encoded 0
  @img_fmt_gray 1
  @img_fmt_gray_a 2
  @img_fmt_rgb 3
  @img_fmt_rgba 4

  # Touch actions
  @touch_down 0
  @touch_up 1
  @touch_move 2

  # Public constants
  def protocol_version, do: @protocol_version
  def header_size, do: @header_size

  # Command type constants
  def cmd_put_script, do: @cmd_put_script
  def cmd_del_script, do: @cmd_del_script
  def cmd_reset, do: @cmd_reset
  def cmd_clear_color, do: @cmd_clear_color
  def cmd_put_font, do: @cmd_put_font
  def cmd_put_image, do: @cmd_put_image
  def cmd_render, do: @cmd_render
  def cmd_global_tx, do: @cmd_global_tx
  def cmd_cursor_tx, do: @cmd_cursor_tx
  def cmd_request_input, do: @cmd_request_input
  def cmd_quit, do: @cmd_quit

  # Event type constants
  def evt_touch, do: @evt_touch
  def evt_key, do: @evt_key
  def evt_reshape, do: @evt_reshape
  def evt_codepoint, do: @evt_codepoint
  def evt_cursor_pos, do: @evt_cursor_pos
  def evt_mouse_button, do: @evt_mouse_button
  def evt_scroll, do: @evt_scroll
  def evt_cursor_enter, do: @evt_cursor_enter
  def evt_ready, do: @evt_ready
  def evt_log_info, do: @evt_log_info
  def evt_log_warn, do: @evt_log_warn
  def evt_log_error, do: @evt_log_error

  # Image format constants
  def img_fmt_encoded, do: @img_fmt_encoded
  def img_fmt_gray, do: @img_fmt_gray
  def img_fmt_gray_a, do: @img_fmt_gray_a
  def img_fmt_rgb, do: @img_fmt_rgb
  def img_fmt_rgba, do: @img_fmt_rgba

  # Touch action constants
  def touch_down, do: @touch_down
  def touch_up, do: @touch_up
  def touch_move, do: @touch_move

  @doc """
  Encode a message with header.
  """
  @spec encode_message(integer(), iodata()) :: iodata()
  def encode_message(type, payload) do
    payload_bin = IO.iodata_to_binary(payload)
    length = byte_size(payload_bin)
    [<<type::8, length::big-unsigned-32>>, payload_bin]
  end

  @doc """
  Decode a message header, returning {type, length} or :incomplete.
  """
  @spec decode_header(binary()) :: {:ok, integer(), integer(), binary()} | :incomplete
  def decode_header(<<type::8, length::big-unsigned-32, rest::binary>>) do
    {:ok, type, length, rest}
  end

  def decode_header(_), do: :incomplete

  @doc """
  Encode a script ID (handles atoms, binaries, and other terms).
  """
  @spec encode_id(term()) :: binary()
  def encode_id(id) when is_binary(id), do: id
  def encode_id(id) when is_atom(id), do: Atom.to_string(id)
  def encode_id(id), do: to_string(id)

  @doc """
  Convert image format atom to integer.
  """
  @spec image_format_to_int(atom()) :: integer()
  def image_format_to_int(:encoded), do: @img_fmt_encoded
  def image_format_to_int(:g), do: @img_fmt_gray
  def image_format_to_int(:ga), do: @img_fmt_gray_a
  def image_format_to_int(:rgb), do: @img_fmt_rgb
  def image_format_to_int(:rgba), do: @img_fmt_rgba
  def image_format_to_int(_), do: @img_fmt_encoded

  @doc """
  Convert touch action integer to atom.
  """
  @spec touch_action_to_atom(integer()) :: atom()
  def touch_action_to_atom(@touch_down), do: :down
  def touch_action_to_atom(@touch_up), do: :up
  def touch_action_to_atom(@touch_move), do: :move
  def touch_action_to_atom(_), do: :unknown
end
