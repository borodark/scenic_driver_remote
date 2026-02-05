defmodule ScenicDriverRemote.ProtocolTest do
  use ExUnit.Case, async: true

  alias ScenicDriverRemote.Protocol
  alias ScenicDriverRemote.Protocol.Commands
  alias ScenicDriverRemote.Protocol.Events

  # ---------------------------------------------------------------------------
  # Protocol basics
  # ---------------------------------------------------------------------------

  describe "Protocol.encode_message/2" do
    test "encodes message with correct header" do
      [header, payload] = Protocol.encode_message(0x01, "test")
      <<type::8, length::big-unsigned-32>> = header
      assert type == 0x01
      assert length == 4
      assert payload == "test"
    end

    test "handles empty payload" do
      [header, payload] = Protocol.encode_message(0x04, <<>>)
      <<type::8, length::big-unsigned-32>> = header
      assert type == 0x04
      assert length == 0
      assert payload == <<>>
    end

    test "handles large payload" do
      big = :crypto.strong_rand_bytes(100_000)
      [header, payload] = Protocol.encode_message(0xFF, big)
      <<_type::8, length::big-unsigned-32>> = header
      assert length == 100_000
      assert payload == big
    end
  end

  describe "Protocol.decode_header/1" do
    test "decodes a valid header" do
      bin = <<0x82, 9::big-unsigned-32, "remaining">>
      assert {:ok, 0x82, 9, "remaining"} == Protocol.decode_header(bin)
    end

    test "returns :incomplete for short input" do
      assert :incomplete == Protocol.decode_header(<<1, 2>>)
      assert :incomplete == Protocol.decode_header(<<>>)
    end
  end

  describe "Protocol.encode_id/1" do
    test "returns binary as-is" do
      assert Protocol.encode_id("test") == "test"
    end

    test "converts atom to string" do
      assert Protocol.encode_id(:test) == "test"
    end

    test "converts integer to string" do
      assert Protocol.encode_id(123) == "123"
    end

    test "converts list to string" do
      assert Protocol.encode_id(~c"abc") == "abc"
    end
  end

  describe "Protocol constants" do
    test "command type codes match scenic_driver_local" do
      assert Protocol.cmd_put_script() == 0x01
      assert Protocol.cmd_del_script() == 0x02
      assert Protocol.cmd_reset() == 0x03
      assert Protocol.cmd_global_tx() == 0x04
      assert Protocol.cmd_cursor_tx() == 0x05
      assert Protocol.cmd_render() == 0x06
      assert Protocol.cmd_clear_color() == 0x08
      assert Protocol.cmd_request_input() == 0x0A
      assert Protocol.cmd_quit() == 0x20
      assert Protocol.cmd_put_font() == 0x40
      assert Protocol.cmd_put_image() == 0x41
    end

    test "event type codes match scenic_driver_local" do
      assert Protocol.evt_reshape() == 0x05
      assert Protocol.evt_ready() == 0x06
      assert Protocol.evt_touch() == 0x08
      assert Protocol.evt_key() == 0x0A
      assert Protocol.evt_codepoint() == 0x0B
      assert Protocol.evt_cursor_pos() == 0x0C
      assert Protocol.evt_mouse_button() == 0x0D
      assert Protocol.evt_scroll() == 0x0E
      assert Protocol.evt_cursor_enter() == 0x0F
      assert Protocol.evt_log_info() == 0xA0
      assert Protocol.evt_log_warn() == 0xA1
      assert Protocol.evt_log_error() == 0xA2
    end

    test "image format codes" do
      assert Protocol.img_fmt_encoded() == 0
      assert Protocol.img_fmt_gray() == 1
      assert Protocol.img_fmt_gray_a() == 2
      assert Protocol.img_fmt_rgb() == 3
      assert Protocol.img_fmt_rgba() == 4
    end

    test "image_format_to_int/1" do
      assert Protocol.image_format_to_int(:encoded) == 0
      assert Protocol.image_format_to_int(:g) == 1
      assert Protocol.image_format_to_int(:ga) == 2
      assert Protocol.image_format_to_int(:rgb) == 3
      assert Protocol.image_format_to_int(:rgba) == 4
      assert Protocol.image_format_to_int(:unknown) == 0
    end

    test "touch_action_to_atom/1" do
      assert Protocol.touch_action_to_atom(0) == :down
      assert Protocol.touch_action_to_atom(1) == :up
      assert Protocol.touch_action_to_atom(2) == :move
      assert Protocol.touch_action_to_atom(99) == :unknown
    end
  end

  # ---------------------------------------------------------------------------
  # Commands
  # ---------------------------------------------------------------------------

  describe "Commands" do
    test "put_script" do
      binary = IO.iodata_to_binary(Commands.put_script("my_script", "script_data"))
      <<type::8, length::big-unsigned-32, payload::binary>> = binary

      assert type == Protocol.cmd_put_script()
      assert length == byte_size(payload)

      <<id_len::big-unsigned-32, id::binary-size(id_len), script::binary>> = payload
      assert id == "my_script"
      assert script == "script_data"
    end

    test "put_script with atom id" do
      binary = IO.iodata_to_binary(Commands.put_script(:main, "data"))

      <<_type::8, _length::big-unsigned-32, id_len::big-unsigned-32, id::binary-size(id_len),
        _rest::binary>> = binary

      assert id == "main"
    end

    test "del_script" do
      binary = IO.iodata_to_binary(Commands.del_script("my_script"))

      <<type::8, _length::big-unsigned-32, id_len::big-unsigned-32, id::binary-size(id_len)>> =
        binary

      assert type == Protocol.cmd_del_script()
      assert id == "my_script"
    end

    test "reset" do
      binary = IO.iodata_to_binary(Commands.reset())
      <<type::8, length::big-unsigned-32>> = binary
      assert type == Protocol.cmd_reset()
      assert length == 0
    end

    test "clear_color" do
      binary = IO.iodata_to_binary(Commands.clear_color(0.5, 0.25, 0.75, 1.0))

      <<type::8, _length::big-unsigned-32, r::big-float-32, g::big-float-32, b::big-float-32,
        a::big-float-32>> = binary

      assert type == Protocol.cmd_clear_color()
      assert_in_delta r, 0.5, 0.001
      assert_in_delta g, 0.25, 0.001
      assert_in_delta b, 0.75, 0.001
      assert_in_delta a, 1.0, 0.001
    end

    test "put_font" do
      binary = IO.iodata_to_binary(Commands.put_font("roboto", "font_binary_data"))

      <<type::8, _length::big-unsigned-32, name_len::big-unsigned-32, _data_len::big-unsigned-32,
        name::binary-size(name_len), data::binary>> = binary

      assert type == Protocol.cmd_put_font()
      assert name == "roboto"
      assert data == "font_binary_data"
    end

    test "put_image" do
      binary = IO.iodata_to_binary(Commands.put_image("my_image", :rgba, 100, 200, "pixel_data"))

      <<type::8, _length::big-unsigned-32, id_len::big-unsigned-32, _data_len::big-unsigned-32,
        width::big-unsigned-32, height::big-unsigned-32, format::big-unsigned-32,
        id::binary-size(id_len), data::binary>> = binary

      assert type == Protocol.cmd_put_image()
      assert id == "my_image"
      assert width == 100
      assert height == 200
      assert format == Protocol.img_fmt_rgba()
      assert data == "pixel_data"
    end

    test "render" do
      binary = IO.iodata_to_binary(Commands.render())
      <<type::8, length::big-unsigned-32>> = binary
      assert type == Protocol.cmd_render()
      assert length == 0
    end

    test "global_tx" do
      binary = IO.iodata_to_binary(Commands.global_tx(2.0, 0.0, 0.0, 2.0, 10.0, 20.0))

      <<type::8, _length::big-unsigned-32, a::big-float-32, b::big-float-32, c::big-float-32,
        d::big-float-32, e::big-float-32, f::big-float-32>> = binary

      assert type == Protocol.cmd_global_tx()
      assert_in_delta a, 2.0, 0.001
      assert_in_delta b, 0.0, 0.001
      assert_in_delta c, 0.0, 0.001
      assert_in_delta d, 2.0, 0.001
      assert_in_delta e, 10.0, 0.001
      assert_in_delta f, 20.0, 0.001
    end

    test "global_tx payload is 24 bytes (6 floats)" do
      binary = IO.iodata_to_binary(Commands.global_tx(1.0, 0.0, 0.0, 1.0, 0.0, 0.0))
      <<_type::8, length::big-unsigned-32, _payload::binary>> = binary
      assert length == 24
    end

    test "quit" do
      binary = IO.iodata_to_binary(Commands.quit())
      <<type::8, length::big-unsigned-32>> = binary
      assert type == Protocol.cmd_quit()
      assert length == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  describe "Events.parse_all/1" do
    test "parses ready event" do
      binary = <<0x06, 0::big-unsigned-32>>
      {events, remaining} = Events.parse_all(binary)
      assert events == [{:ready}]
      assert remaining == <<>>
    end

    test "parses reshape event" do
      binary = <<0x05, 8::big-unsigned-32, 1080::big-unsigned-32, 2400::big-unsigned-32>>
      {events, remaining} = Events.parse_all(binary)
      assert events == [{:reshape, 1080, 2400}]
      assert remaining == <<>>
    end

    test "parses touch down event" do
      x = 100.5
      y = 200.5
      binary = <<0x08, 9::big-unsigned-32, 0::8, x::big-float-32, y::big-float-32>>
      {[{:touch, action, rx, ry}], <<>>} = Events.parse_all(binary)
      assert action == :down
      assert_in_delta rx, x, 0.001
      assert_in_delta ry, y, 0.001
    end

    test "parses touch up event" do
      binary = <<0x08, 9::big-unsigned-32, 1::8, 50.0::big-float-32, 60.0::big-float-32>>
      {[{:touch, :up, _, _}], <<>>} = Events.parse_all(binary)
    end

    test "parses touch move event" do
      binary = <<0x08, 9::big-unsigned-32, 2::8, 50.0::big-float-32, 60.0::big-float-32>>
      {[{:touch, :move, _, _}], <<>>} = Events.parse_all(binary)
    end

    test "parses key event" do
      binary =
        <<0x0A, 16::big-unsigned-32, 65::big-unsigned-32, 30::big-unsigned-32, 1::big-signed-32,
          0::big-unsigned-32>>

      {[{:key, key, scancode, action, mods}], <<>>} = Events.parse_all(binary)
      assert key == 65
      assert scancode == 30
      assert action == 1
      assert mods == 0
    end

    test "parses codepoint event" do
      binary = <<0x0B, 8::big-unsigned-32, 0x41::big-unsigned-32, 0::big-unsigned-32>>
      {[{:codepoint, cp, mods}], <<>>} = Events.parse_all(binary)
      assert cp == 0x41
      assert mods == 0
    end

    test "parses cursor_pos event" do
      binary = <<0x0C, 8::big-unsigned-32, 320.0::big-float-32, 480.0::big-float-32>>
      {[{:cursor_pos, x, y}], <<>>} = Events.parse_all(binary)
      assert_in_delta x, 320.0, 0.001
      assert_in_delta y, 480.0, 0.001
    end

    test "parses mouse_button event" do
      binary =
        <<0x0D, 20::big-unsigned-32, 0::big-unsigned-32, 1::big-unsigned-32, 0::big-unsigned-32,
          100.0::big-float-32, 200.0::big-float-32>>

      {[{:mouse_button, button, action, mods, x, y}], <<>>} = Events.parse_all(binary)
      assert button == 0
      assert action == 1
      assert mods == 0
      assert_in_delta x, 100.0, 0.001
      assert_in_delta y, 200.0, 0.001
    end

    test "parses scroll event" do
      binary =
        <<0x0E, 16::big-unsigned-32, 0.0::big-float-32, -3.0::big-float-32, 500.0::big-float-32,
          400.0::big-float-32>>

      {[{:scroll, xo, yo, x, y}], <<>>} = Events.parse_all(binary)
      assert_in_delta xo, 0.0, 0.001
      assert_in_delta yo, -3.0, 0.001
      assert_in_delta x, 500.0, 0.001
      assert_in_delta y, 400.0, 0.001
    end

    test "parses cursor_enter event" do
      binary = <<0x0F, 1::big-unsigned-32, 1::8>>
      {[{:cursor_enter, true}], <<>>} = Events.parse_all(binary)

      binary2 = <<0x0F, 1::big-unsigned-32, 0::8>>
      {[{:cursor_enter, false}], <<>>} = Events.parse_all(binary2)
    end

    test "parses stats event" do
      bytes = 1_234_567_890
      binary = <<0x01, 8::big-unsigned-32, bytes::big-unsigned-64>>
      {[{:stats, val}], <<>>} = Events.parse_all(binary)
      assert val == bytes
    end

    test "parses log events" do
      for {type, tag} <- [{0xA0, :log_info}, {0xA1, :log_warn}, {0xA2, :log_error}] do
        msg = "hello"
        binary = <<type, 5::big-unsigned-32, msg::binary>>
        {[{^tag, payload}], <<>>} = Events.parse_all(binary)
        assert payload == msg
      end
    end

    test "parses unknown event type" do
      binary = <<0xFF, 2::big-unsigned-32, "ab">>
      {[{:unknown, 0xFF, "ab"}], <<>>} = Events.parse_all(binary)
    end

    test "parses multiple events" do
      ready = <<0x06, 0::big-unsigned-32>>
      reshape = <<0x05, 8::big-unsigned-32, 800::big-unsigned-32, 600::big-unsigned-32>>
      binary = ready <> reshape

      {events, remaining} = Events.parse_all(binary)
      assert events == [{:ready}, {:reshape, 800, 600}]
      assert remaining == <<>>
    end

    test "handles incomplete header" do
      {events, remaining} = Events.parse_all(<<0x06, 0>>)
      assert events == []
      assert remaining == <<0x06, 0>>
    end

    test "handles incomplete payload" do
      binary = <<0x05, 8::big-unsigned-32, 800::big-unsigned-32>>
      {events, remaining} = Events.parse_all(binary)
      assert events == []
      assert remaining == binary
    end

    test "handles empty buffer" do
      {events, remaining} = Events.parse_all(<<>>)
      assert events == []
      assert remaining == <<>>
    end

    test "parses complete events and returns trailing incomplete" do
      ready = <<0x06, 0::big-unsigned-32>>
      partial = <<0x05, 8::big-unsigned-32, 800::big-unsigned-32>>
      binary = ready <> partial

      {events, remaining} = Events.parse_all(binary)
      assert events == [{:ready}]
      assert remaining == partial
    end
  end

  # ---------------------------------------------------------------------------
  # Round-trip: encode command, decode header, verify type + length
  # ---------------------------------------------------------------------------

  describe "round-trip" do
    test "every command produces a valid protocol frame" do
      commands = [
        Commands.reset(),
        Commands.render(),
        Commands.quit(),
        Commands.clear_color(0.0, 0.0, 0.0, 1.0),
        Commands.put_script("id", "data"),
        Commands.del_script("id"),
        Commands.put_font("f", "bin"),
        Commands.put_image("i", :rgb, 10, 10, "px"),
        Commands.global_tx(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
      ]

      for cmd <- commands do
        binary = IO.iodata_to_binary(cmd)
        assert {:ok, _type, length, rest} = Protocol.decode_header(binary)
        assert byte_size(rest) == length
      end
    end
  end
end
