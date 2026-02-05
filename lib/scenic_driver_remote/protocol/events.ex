defmodule ScenicDriverRemote.Protocol.Events do
  @moduledoc """
  Event decoding for the Scenic remote rendering protocol.

  Events are sent from the renderer to the driver.
  """

  alias ScenicDriverRemote.Protocol

  # Header size as a compile-time constant for guards
  @header_size 5

  @doc """
  Parse all complete events from a binary buffer.

  Returns {events, remaining_buffer}.
  """
  @spec parse_all(binary()) :: {list(), binary()}
  def parse_all(buffer) do
    parse_all(buffer, [])
  end

  defp parse_all(buffer, acc) do
    case parse_one(buffer) do
      {:ok, event, rest} ->
        parse_all(rest, [event | acc])

      :incomplete ->
        {Enum.reverse(acc), buffer}
    end
  end

  @doc """
  Parse a single event from a binary buffer.

  Returns {:ok, event, remaining} or :incomplete.
  """
  @spec parse_one(binary()) :: {:ok, tuple(), binary()} | :incomplete
  def parse_one(buffer) when byte_size(buffer) < @header_size do
    :incomplete
  end

  def parse_one(buffer) do
    case Protocol.decode_header(buffer) do
      {:ok, type, length, rest} when byte_size(rest) >= length ->
        <<payload::binary-size(length), remaining::binary>> = rest
        event = decode_event(type, payload)
        {:ok, event, remaining}

      {:ok, _type, _length, _rest} ->
        :incomplete

      :incomplete ->
        :incomplete
    end
  end

  # Event decoders
  # Values from scenic_driver_local (canonical source)

  # EVT_RESHAPE = 0x05
  defp decode_event(0x05, <<width::big-unsigned-32, height::big-unsigned-32>>) do
    {:reshape, width, height}
  end

  # EVT_READY = 0x06
  defp decode_event(0x06, <<>>) do
    {:ready}
  end

  # EVT_TOUCH = 0x08 (new in remote, slot 0x08 unused in scenic_driver_local)
  defp decode_event(0x08, <<action::8, x::big-float-32, y::big-float-32>>) do
    {:touch, Protocol.touch_action_to_atom(action), x, y}
  end

  # EVT_KEY = 0x0A
  defp decode_event(
         0x0A,
         <<key::big-unsigned-32, scancode::big-unsigned-32, action::big-signed-32,
           mods::big-unsigned-32>>
       ) do
    {:key, key, scancode, action, mods}
  end

  # EVT_CODEPOINT = 0x0B
  defp decode_event(0x0B, <<codepoint::big-unsigned-32, mods::big-unsigned-32>>) do
    {:codepoint, codepoint, mods}
  end

  # EVT_CURSOR_POS = 0x0C
  defp decode_event(0x0C, <<x::big-float-32, y::big-float-32>>) do
    {:cursor_pos, x, y}
  end

  # EVT_MOUSE_BUTTON = 0x0D
  defp decode_event(
         0x0D,
         <<button::big-unsigned-32, action::big-unsigned-32, mods::big-unsigned-32,
           x::big-float-32, y::big-float-32>>
       ) do
    {:mouse_button, button, action, mods, x, y}
  end

  # EVT_SCROLL = 0x0E
  defp decode_event(
         0x0E,
         <<x_offset::big-float-32, y_offset::big-float-32, x::big-float-32, y::big-float-32>>
       ) do
    {:scroll, x_offset, y_offset, x, y}
  end

  # EVT_CURSOR_ENTER = 0x0F
  defp decode_event(0x0F, <<entered::8>>) do
    {:cursor_enter, entered == 1}
  end

  # EVT_STATS = 0x01 (MSG_OUT_STATS in scenic_driver_local)
  defp decode_event(0x01, <<bytes_received::big-unsigned-64>>) do
    {:stats, bytes_received}
  end

  defp decode_event(0xA0, payload) do
    {:log_info, payload}
  end

  defp decode_event(0xA1, payload) do
    {:log_warn, payload}
  end

  defp decode_event(0xA2, payload) do
    {:log_error, payload}
  end

  defp decode_event(type, payload) do
    {:unknown, type, payload}
  end
end
