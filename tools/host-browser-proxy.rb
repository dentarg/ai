#!/usr/bin/env ruby

require "json"
require "openssl"
require "socket"
require "uri"

module HostBrowserProxy
  MAX_HEADER_BYTES = 64 * 1024

  class Server
    attr_reader :port

    def initialize(upstream_port:, token:, advertised_host:, certificate:, private_key:,
                   bind: "0.0.0.0", port: 0)
      @upstream_port = upstream_port
      @token = token
      @advertised_host = advertised_host
      tcp_server = TCPServer.new(bind, port)
      @port = tcp_server.local_address.ip_port

      context = OpenSSL::SSL::SSLContext.new
      context.cert = certificate
      context.key = private_key
      context.min_version = OpenSSL::SSL::TLS1_2_VERSION
      @server = OpenSSL::SSL::SSLServer.new(tcp_server, context)
      @server.start_immediately = true
    end

    def run
      loop do
        connection = @server.accept
        Thread.new(connection) do |client|
          handle(client)
        rescue OpenSSL::SSL::SSLError, IOError, SystemCallError => error
          HostBrowserProxy.log("warn", "connection_failed", error: error.message) unless @closed
        ensure
          client.close rescue nil
        end
      rescue OpenSSL::SSL::SSLError
        next
      rescue IOError, SystemCallError
        raise unless @closed

        break
      end
    end

    def close
      @closed = true
      @server.close
    end

    private

    def handle(client)
      request_line, headers = read_request(client)
      return unless request_line

      method, path, version = request_line.split(" ", 3)
      return respond(client, 400, "bad request\n") unless version&.start_with?("HTTP/")
      return respond(client, 401, "unauthorized\n") unless authenticated?(headers["authorization"])
      return respond(client, 403, "forbidden\n") unless allowed?(method, path)

      upstream = TCPSocket.new("127.0.0.1", @upstream_port)
      write_upstream_request(upstream, request_line, headers)
      if websocket?(headers)
        tunnel_websocket(client, upstream)
      else
        proxy_http(client, upstream)
      end
    ensure
      upstream&.close rescue nil
    end

    def read_request(connection)
      request_line = connection.gets&.strip
      return unless request_line

      headers = {}
      bytes = request_line.bytesize
      while (line = connection.gets)
        bytes += line.bytesize
        return respond(connection, 431, "headers too large\n") if bytes > MAX_HEADER_BYTES
        break if line == "\r\n" || line == "\n"

        name, value = line.split(":", 2)
        return respond(connection, 400, "bad request\n") unless value

        headers[name.downcase] = value.strip
      end
      [request_line, headers]
    end

    def authenticated?(authorization)
      candidate = authorization&.delete_prefix("Bearer ")
      return false unless candidate&.bytesize == @token.bytesize

      OpenSSL.fixed_length_secure_compare(candidate, @token)
    end

    def allowed?(method, path)
      return false unless %w[GET PUT].include?(method)

      path.start_with?("/json", "/devtools/")
    end

    def websocket?(headers)
      headers.fetch("upgrade", "").casecmp("websocket").zero?
    end

    def write_upstream_request(upstream, request_line, headers)
      upstream.write("#{request_line}\r\n")
      headers.each do |name, value|
        next if name == "authorization" || name == "host" || name == "connection"

        upstream.write("#{name}: #{value}\r\n")
      end
      upstream.write("Host: 127.0.0.1:#{@upstream_port}\r\n")
      connection = websocket?(headers) ? "Upgrade" : "close"
      upstream.write("Connection: #{connection}\r\n\r\n")
    end

    def tunnel_websocket(client, upstream)
      response_headers = read_header_block(upstream)
      return unless response_headers

      client.write(response_headers)
      return unless response_headers.start_with?("HTTP/1.1 101 ", "HTTP/1.0 101 ")

      completed = Queue.new
      copies = [
        Thread.new do
          copy_stream(upstream, client)
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
          nil
        ensure
          completed << true
        end,
        Thread.new do
          copy_stream(client, upstream)
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
          nil
        ensure
          completed << true
        end,
      ]
      completed.pop
      client.close
      upstream.close
      copies.each(&:join)
    end

    def copy_stream(source, destination)
      loop do
        destination.write(source.readpartial(16 * 1024))
      end
    rescue EOFError
      nil
    end

    def proxy_http(client, upstream)
      response = read_header_block(upstream)
      return unless response

      header, body = response.split("\r\n\r\n", 2)
      content_length = header[/\r\nContent-Length:\s*(\d+)/i, 1]
      if content_length
        remaining = content_length.to_i - body.bytesize
        body << upstream.read(remaining) if remaining.positive?
      else
        body << upstream.read.to_s
      end

      rewritten = rewrite_json(body)
      lines = header.split("\r\n")
      status = lines.shift
      lines.reject! { |line| line.match?(/\A(?:content-length|transfer-encoding|connection):/i) }
      lines << "Content-Length: #{rewritten.bytesize}"
      lines << "Connection: close"
      client.write(([status] + lines).join("\r\n") + "\r\n\r\n" + rewritten)
    end

    def rewrite_json(body)
      payload = JSON.parse(body)
      rewrite_websocket_urls(payload)
      JSON.generate(payload)
    rescue JSON::ParserError
      body
    end

    def rewrite_websocket_urls(value)
      case value
      when Hash
        value.each do |key, child|
          if key == "webSocketDebuggerUrl" && child.is_a?(String)
            uri = URI(child)
            value[key] = "wss://#{@advertised_host}:#{port}#{uri.request_uri}"
          else
            rewrite_websocket_urls(child)
          end
        end
      when Array
        value.each { |child| rewrite_websocket_urls(child) }
      end
    end

    def read_header_block(connection)
      buffer = +""
      until buffer.include?("\r\n\r\n")
        chunk = connection.readpartial(4096)
        buffer << chunk
        return if buffer.bytesize > MAX_HEADER_BYTES
      end
      buffer
    rescue EOFError
      nil
    end

    def respond(connection, status, body)
      reasons = {
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        431 => "Request Header Fields Too Large",
      }
      connection.write("HTTP/1.1 #{status} #{reasons.fetch(status)}\r\n")
      connection.write("Content-Type: text/plain\r\n")
      connection.write("Content-Length: #{body.bytesize}\r\n")
      connection.write("Connection: close\r\n\r\n#{body}")
      nil
    end
  end

  def self.certificate
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = Random.rand(1..(2**128))
    certificate.subject = OpenSSL::X509::Name.parse("/CN=host.containers.internal")
    certificate.issuer = certificate.subject
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 86_400

    extensions = OpenSSL::X509::ExtensionFactory.new
    extensions.subject_certificate = certificate
    extensions.issuer_certificate = certificate
    certificate.add_extension(extensions.create_extension("basicConstraints", "CA:FALSE", true))
    certificate.add_extension(extensions.create_extension("keyUsage", "digitalSignature,keyEncipherment", true))
    certificate.add_extension(extensions.create_extension("extendedKeyUsage", "serverAuth", false))
    certificate.add_extension(
      extensions.create_extension(
        "subjectAltName",
        "DNS:host.containers.internal,DNS:host.lima.internal,IP:127.0.0.1",
        false,
      ),
    )
    certificate.sign(key, OpenSSL::Digest.new("SHA256"))
    [certificate, key]
  end

  def self.log(level, event, error: nil)
    fields = ["at=#{level}", "event=#{event}"]
    fields << "error=#{JSON.generate(error)}" if error
    $stdout.puts(fields.join(" "))
    $stdout.flush
  end

  def self.main
    certificate, private_key = certificate()
    File.write(ENV.fetch("HOST_BROWSER_CA_FILE"), certificate.to_pem)
    server = Server.new(
      upstream_port: Integer(ENV.fetch("HOST_BROWSER_UPSTREAM_PORT")),
      token: ENV.fetch("HOST_BROWSER_TOKEN"),
      advertised_host: ENV.fetch("HOST_BROWSER_ADVERTISED_HOST"),
      certificate: certificate,
      private_key: private_key,
    )
    File.write(ENV.fetch("HOST_BROWSER_PORT_FILE"), "#{server.port}\n")
    trap("INT") { server.close }
    trap("TERM") { server.close }
    log("info", "proxy_started")
    server.run
  rescue StandardError => error
    log("fatal", "proxy_failed", error: error.message)
    exit 1
  end
end

HostBrowserProxy.main if $PROGRAM_NAME == __FILE__
