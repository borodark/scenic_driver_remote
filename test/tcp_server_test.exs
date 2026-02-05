defmodule ScenicDriverRemote.Transport.TcpServerTest do
  use ExUnit.Case, async: false

  alias ScenicDriverRemote.Transport.TcpServer

  @port 14_040

  describe "single client" do
    test "starts listening and accepts a connection" do
      {:ok, server} = TcpServer.connect(port: @port)
      assert TcpServer.connected?(server) == false

      # Connect a TCP client
      {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, active: false])
      Process.sleep(200)

      assert TcpServer.connected?(server) == true

      :gen_tcp.close(client)
      Process.sleep(200)

      assert TcpServer.connected?(server) == false
      TcpServer.disconnect(server)
    end

    test "broadcasts data to connected client" do
      {:ok, server} = TcpServer.connect(port: @port + 1)
      {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", @port + 1, [:binary, active: false])
      Process.sleep(200)

      TcpServer.send(server, "hello")
      {:ok, data} = :gen_tcp.recv(client, 0, 1000)
      assert data == "hello"

      :gen_tcp.close(client)
      TcpServer.disconnect(server)
    end

    test "forwards complete frames from client to owner" do
      {:ok, server} = TcpServer.connect(port: @port + 2)
      {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", @port + 2, [:binary, active: false])
      Process.sleep(200)

      # Send a READY event frame: type=0x80, length=0
      frame = <<0x80, 0::big-unsigned-32>>
      :gen_tcp.send(client, frame)

      assert_receive {:tcp, _socket, ^frame}, 1000

      :gen_tcp.close(client)
      TcpServer.disconnect(server)
    end

    test "returns error when sending with no clients" do
      {:ok, server} = TcpServer.connect(port: @port + 3)
      assert {:error, :not_connected} = TcpServer.send(server, "data")
      TcpServer.disconnect(server)
    end
  end

  describe "multi-client" do
    test "accepts multiple simultaneous clients" do
      {:ok, server} = TcpServer.connect(port: @port + 10)
      {:ok, c1} = :gen_tcp.connect(~c"127.0.0.1", @port + 10, [:binary, active: false])
      Process.sleep(200)
      {:ok, c2} = :gen_tcp.connect(~c"127.0.0.1", @port + 10, [:binary, active: false])
      Process.sleep(200)

      assert TcpServer.connected?(server) == true

      :gen_tcp.close(c1)
      Process.sleep(200)

      # Still connected because c2 is alive
      assert TcpServer.connected?(server) == true

      :gen_tcp.close(c2)
      Process.sleep(200)

      assert TcpServer.connected?(server) == false
      TcpServer.disconnect(server)
    end

    test "broadcasts to all clients" do
      {:ok, server} = TcpServer.connect(port: @port + 11)
      {:ok, c1} = :gen_tcp.connect(~c"127.0.0.1", @port + 11, [:binary, active: false])
      Process.sleep(200)
      {:ok, c2} = :gen_tcp.connect(~c"127.0.0.1", @port + 11, [:binary, active: false])
      Process.sleep(200)

      TcpServer.send(server, "broadcast")

      {:ok, d1} = :gen_tcp.recv(c1, 0, 1000)
      {:ok, d2} = :gen_tcp.recv(c2, 0, 1000)
      assert d1 == "broadcast"
      assert d2 == "broadcast"

      :gen_tcp.close(c1)
      :gen_tcp.close(c2)
      TcpServer.disconnect(server)
    end

    test "events from either client are forwarded to owner" do
      {:ok, server} = TcpServer.connect(port: @port + 12)
      {:ok, c1} = :gen_tcp.connect(~c"127.0.0.1", @port + 12, [:binary, active: false])
      Process.sleep(200)
      {:ok, c2} = :gen_tcp.connect(~c"127.0.0.1", @port + 12, [:binary, active: false])
      Process.sleep(200)

      # Send READY from client 1
      ready = <<0x80, 0::big-unsigned-32>>
      :gen_tcp.send(c1, ready)
      assert_receive {:tcp, _, ^ready}, 1000

      # Send RESHAPE from client 2
      reshape = <<0x81, 8::big-unsigned-32, 1080::big-unsigned-32, 2400::big-unsigned-32>>
      :gen_tcp.send(c2, reshape)
      assert_receive {:tcp, _, ^reshape}, 1000

      :gen_tcp.close(c1)
      :gen_tcp.close(c2)
      TcpServer.disconnect(server)
    end
  end

  describe "frame buffering" do
    test "buffers partial frames and delivers when complete" do
      {:ok, server} = TcpServer.connect(port: @port + 20)
      {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", @port + 20, [:binary, active: false])
      Process.sleep(200)

      # Send header only (partial frame)
      frame = <<0x81, 8::big-unsigned-32, 1080::big-unsigned-32, 2400::big-unsigned-32>>
      <<part1::binary-size(3), part2::binary>> = frame

      :gen_tcp.send(client, part1)
      Process.sleep(100)

      # Should not have received anything yet
      refute_receive {:tcp, _, _}, 100

      # Send rest
      :gen_tcp.send(client, part2)
      assert_receive {:tcp, _, ^frame}, 1000

      :gen_tcp.close(client)
      TcpServer.disconnect(server)
    end

    test "handles multiple frames in one TCP segment" do
      {:ok, server} = TcpServer.connect(port: @port + 21)
      {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", @port + 21, [:binary, active: false])
      Process.sleep(200)

      ready = <<0x80, 0::big-unsigned-32>>
      reshape = <<0x81, 8::big-unsigned-32, 800::big-unsigned-32, 600::big-unsigned-32>>

      # Send both frames in one TCP write
      :gen_tcp.send(client, ready <> reshape)

      assert_receive {:tcp, _, ^ready}, 1000
      assert_receive {:tcp, _, ^reshape}, 1000

      :gen_tcp.close(client)
      TcpServer.disconnect(server)
    end
  end

  describe "get_local_ip/0" do
    test "returns a 4-tuple IPv4 address" do
      {a, b, c, d} = TcpServer.get_local_ip()
      assert is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d)
      assert a != 127 or {a, b, c, d} == {127, 0, 0, 1}
    end
  end

  describe "format helpers" do
    test "format_ip/1" do
      assert TcpServer.format_ip({192, 168, 1, 100}) == "192.168.1.100"
      assert TcpServer.format_ip(:invalid) == "unknown"
    end

    test "format_ip_tuple/1" do
      assert TcpServer.format_ip_tuple({10, 0, 0, 1}) == "{10, 0, 0, 1}"
      assert TcpServer.format_ip_tuple(:bad) == "{127, 0, 0, 1}"
    end
  end
end
