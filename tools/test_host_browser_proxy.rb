#!/usr/bin/env ruby

require "minitest/autorun"
require "net/http"
require "socket"

require_relative "host-browser-proxy"

class HostBrowserProxyTest < Minitest::Test
  TOKEN = "session-token"

  def test_certificate_remains_valid_for_long_running_sessions
    certificate, = HostBrowserProxy.certificate

    assert_operator certificate.not_after, :>, Time.now + (364 * 24 * 60 * 60)
  end

  def setup
    @requests = Queue.new
    @upstream = TCPServer.new("127.0.0.1", 0)
    @upstream_thread = Thread.new do
      loop do
        connection = @upstream.accept
        Thread.new(connection) do |client|
          request = read_headers(client)
          @requests << request
          if request.match?(/^GET \/devtools\/browser\/test HTTP\/1\.1/)
            client.write("HTTP/1.1 101 Switching Protocols\r\n")
            client.write("Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            IO.copy_stream(client, client)
          else
            body = JSON.generate(
              "Browser" => "Chrome Canary",
              "webSocketDebuggerUrl" => "ws://127.0.0.1:#{@upstream.local_address.ip_port}/devtools/browser/test",
            )
            client.write("HTTP/1.1 200 OK\r\n")
            client.write("Content-Type: application/json\r\n")
            client.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
          end
        ensure
          client.close
        end
      end
    rescue IOError, SystemCallError
      nil
    end

    @certificate, private_key = HostBrowserProxy.certificate
    @proxy = HostBrowserProxy::Server.new(
      upstream_port: @upstream.local_address.ip_port,
      token: TOKEN,
      advertised_host: "host.containers.internal",
      certificate: @certificate,
      private_key: private_key,
      bind: "127.0.0.1",
    )
    @proxy_thread = Thread.new { @proxy.run }
  end

  def teardown
    @proxy&.close
    @upstream&.close
    @proxy_thread&.join
    @upstream_thread&.join
  end

  def test_requires_authentication_and_rewrites_the_websocket_endpoint
    unauthorized = request("/json/version")
    assert_equal "401", unauthorized.code

    authorized = request("/json/version", token: TOKEN)
    assert_equal "200", authorized.code
    payload = JSON.parse(authorized.body)
    assert_equal "Chrome Canary", payload.fetch("Browser")
    assert_equal(
      "wss://host.containers.internal:#{@proxy.port}/devtools/browser/test",
      payload.fetch("webSocketDebuggerUrl"),
    )
    upstream_request = @requests.pop
    refute_match(/^authorization:/i, upstream_request)
    assert_match(
      /^host: 127\.0\.0\.1:#{@upstream.local_address.ip_port}\r?$/i,
      upstream_request,
    )
  end

  def test_authenticates_and_tunnels_websocket_connections
    socket = TCPSocket.new("127.0.0.1", @proxy.port)
    ssl = OpenSSL::SSL::SSLSocket.new(socket, ssl_context)
    ssl.hostname = "host.containers.internal"
    ssl.connect
    ssl.write("GET /devtools/browser/test HTTP/1.1\r\n")
    ssl.write("Host: host.containers.internal:#{@proxy.port}\r\n")
    ssl.write("Authorization: Bearer #{TOKEN}\r\n")
    ssl.write("Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n")

    response = read_headers(ssl)
    assert_match(/^HTTP\/1\.1 101 Switching Protocols/, response)
    ssl.write("hello")
    assert_equal "hello", ssl.read(5)
  ensure
    ssl&.close
    socket&.close
  end

  private

  def request(path, token: nil)
    http = Net::HTTP.new("127.0.0.1", @proxy.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.cert_store = OpenSSL::X509::Store.new.tap { |store| store.add_cert(@certificate) }
    request = Net::HTTP::Get.new(path)
    request["Authorization"] = "Bearer #{token}" if token
    http.request(request)
  end

  def ssl_context
    OpenSSL::SSL::SSLContext.new.tap do |context|
      context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      context.cert_store = OpenSSL::X509::Store.new.tap { |store| store.add_cert(@certificate) }
    end
  end

  def read_headers(connection)
    buffer = +""
    buffer << connection.readpartial(1024) until buffer.include?("\r\n\r\n")
    buffer
  end
end
