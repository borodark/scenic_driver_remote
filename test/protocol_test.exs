defmodule ScenicDriverRemote.ProtocolTest do
  use ExUnit.Case, async: true

  alias ScenicDriverRemote.Protocol
  alias ScenicDriverRemote.Protocol.Commands
  alias ScenicDriverRemote.Protocol.Events

  describe "Protocol.encode_message/2" do
    test "encodes message with correct header" do
      [header, payload] = Protocol.encode_message(0x01, "test")
      <<type::8, length::big-unsigned-32>> = header
      assert type == 0x01
      assert length == 4
      assert payload == "test"
    end

    test "handles empty payload" do
      [header, payload] = Protocol.encode_message(0x03, <<>>)
      <<type::8, length::big-unsigned-32>> = header
      assert type == 0x03
      assert length == 0
      assert payload == <<>>
    end
  end

  describe "Protocol.encode_id/1" do
    test "returns binary as-is" do
      assert Protocol.encode_id("test") == "test"
    end

    test "converts atom to string" do
      assert Protocol.encode_id(:test) == "test"
    end

    test "converts other terms to string" do
      assert Protocol.encode_id(123) == "123"
    end
  end

  describe "Commands" do
    test "put_script encodes correctly" do
      result = Commands.put_script("my_script", "script_data")
      binary = IO.iodata_to_binary(result)

      # Parse header
      <<type::8, length::big-unsigned-32, payload::binary>> = binary
      assert type == Protocol.cmd_put_script()
      assert length == byte_size(payload)

      # Parse payload
      <<id_len::big-unsigned-32, id::binary-size(id_len), script::binary>> = payload
      assert id_len == 9
      assert id == "my_script"
      assert script == "script_data"
    end

    test "del_script encodes correctly" do
      result = Commands.del_script("my_script")
      binary = IO.iodata_to_binary(result)

      <<type::8, length::big-unsigned-32, payload::binary>> = binary
      assert type == Protocol.cmd_del_script()

      <<id_len::big-unsigned-32, id::binary-size(id_len)>> = payload
      assert id == "my_script"
    end

    test "reset encodes correctly" do
      result = Commands.reset()
      binary = IO.iodata_to_binary(result)

      <<type::8, length::big-unsigned-32>> = binary
      assert type == Protocol.cmd_reset()
      assert length == 0
    end

    test "clear_color encodes correctly" do
      result = Commands.clear_color(0.5, 0.25, 0.75, 1.0)
      binary = IO.iodata_to_binary(result)

      <<type::8, _length::big-unsigned-32,
        r::big-float-32, g::big-float-32, b::big-float-32, a::big-float-32>> = binary

      assert type == Protocol.cmd_clear_color()
      assert_in_delta r, 0.5, 0.001
      assert_in_delta g, 0.25, 0.001
      assert_in_delta b, 0.75, 0.001
      assert_in_delta a, 1.0, 0.001
    end

    test "put_font encodes correctly" do
      result = Commands.put_font("roboto", "font_binary_data")
      binary = IO.iodata_to_binary(result)

      <<type::8, _length::big-unsigned-32,
        name_len::big-unsigned-32, data_len::big-unsigned-32,
        name::binary-size(name_len), data::binary>> = binary

      assert type == Protocol.cmd_put_font()
      assert name == "roboto"
      assert data == "font_binary_data"
    end

    test "put_image encodes correctly" do
      result = Commands.put_image("my_image", :rgba, 100, 200, "pixel_data")
      binary = IO.iodata_to_binary(result)

      <<type::8, _length::big-unsigned-32,
        id_len::big-unsigned-32, data_len::big-unsigned-32,
        width::big-unsigned-32, height::big-unsigned-32,
        format::big-unsigned-32,
        id::binary-size(id_len), data::binary>> = binary

      assert type == Protocol.cmd_put_image()
      assert id == "my_image"
      assert width == 100
      assert height == 200
      assert format == Protocol.img_fmt_rgba()
      assert data == "pixel_data"
    end

    test "render encodes correctly" do
      result = Commands.render()
      binary = IO.iodata_to_binary(result)

      <<type::8, length::big-unsigned-32>> = binary
      assert type == Protocol.cmd_render()
      assert length == 0
    end
  end

  describe "Events.parse_all/1" do
    test "parses ready event" do
      binary = <<0x10, 0::big-unsigned-32>>
      {events, remaining} = Events.parse_all(binary)

      assert events == [{:ready}]
      assert remaining == <<>>
    end

    test "parses reshape event" do
      binary = <<0x03, 8::big-unsigned-32, 800::big-unsigned-32, 600::big-unsigned-32>>
      {events, remaining} = Events.parse_all(binary)

      assert events == [{:reshape, 800, 600}]
      assert remaining == <<>>
    end

    test "parses touch event" do
      x = 100.5
      y = 200.5
      binary = <<0x01, 9::big-unsigned-32, 0::8, x::big-float-32, y::big-float-32>>
      {events, remaining} = Events.parse_all(binary)

      [{:touch, action, rx, ry}] = events
      assert action == :down
      assert_in_delta rx, x, 0.001
      assert_in_delta ry, y, 0.001
      assert remaining == <<>>
    end

    test "parses multiple events" do
      ready = <<0x10, 0::big-unsigned-32>>
      reshape = <<0x03, 8::big-unsigned-32, 800::big-unsigned-32, 600::big-unsigned-32>>
      binary = ready <> reshape

      {events, remaining} = Events.parse_all(binary)

      assert events == [{:ready}, {:reshape, 800, 600}]
      assert remaining == <<>>
    end

    test "handles incomplete data" do
      # Only header, no payload
      binary = <<0x03, 8::big-unsigned-32, 800::big-unsigned-32>>
      {events, remaining} = Events.parse_all(binary)

      assert events == []
      assert remaining == binary
    end
  end
end
