require "socket"
require "tmpdir"
require "time"
require "uri"
require_relative "executor"
require_relative "../onepassword-bridge/server"

module GitHubBridge
  class Server
    MAX_HEADERS = 16 * 1024
    MAX_BODY = 16 * 1024
    attr_reader :port

    def initialize(broker:, certificate:, private_key:, bind: "0.0.0.0", timeout: 10, upload_timeout: 60)
      @broker, @timeout, @upload_timeout = broker, timeout, upload_timeout
      tcp = TCPServer.new(bind, 0)
      @port = tcp.local_address.ip_port
      context = OpenSSL::SSL::SSLContext.new
      context.cert, context.key = certificate, private_key
      context.min_version = OpenSSL::SSL::TLS1_2_VERSION
      @server = OpenSSL::SSL::SSLServer.new(tcp, context)
      @server.start_immediately = false
    end

    def run
      until @closed
        connection = nil
        request = nil
        response = nil
        begin
          connection = @server.accept
          Timeout.timeout(@timeout) { connection.accept }
          request, token = read_request(connection)
          response = @broker.call(request, token)
          response_timeout = response.body.is_a?(Download) ? 60 : @timeout
          Timeout.timeout(response_timeout) { write_response(connection, response) }
        rescue ArgumentError, JSON::ParserError
          begin
            Timeout.timeout(@timeout) { write_response(connection, Response.new(400, "invalid request\n")) }
          rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error
            nil
          end
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error
          # A malformed or stalled client must not stop the broker.
          next
        ensure
          response.body.close if response&.body.is_a?(Download)
          request["asset"].close if request.is_a?(Hash) && request["asset"].is_a?(Asset)
          connection&.close
        end
      end
    end

    def close
      @closed = true
      @server.close
    end

    private

    def read_line(connection)
      line = +"".b
      while line.bytesize <= MAX_HEADERS
        character = connection.read(1)
        raise ArgumentError unless character && !character.empty?
        line << character
        return line if character == "\n"
      end
      raise ArgumentError
    end

    def read_headers(connection)
      line = read_line(connection)
      upload = line == "POST /v1/github/assets HTTP/1.1\r\n"
      raise ArgumentError unless upload || line == "POST /v1/github HTTP/1.1\r\n"
      headers = {}
      bytes = line.bytesize
      loop do
        line = read_line(connection)
        raise ArgumentError unless line && line.end_with?("\r\n")
        bytes += line.bytesize
        raise ArgumentError if bytes > MAX_HEADERS
        break if line == "\r\n"
        name, value = line.chomp.split(":", 2)
        raise ArgumentError unless name&.match?(/\A[A-Za-z0-9-]+\z/) && value
        name = name.downcase
        raise ArgumentError if headers.key?(name)
        headers[name] = value.strip
      end
      [upload, headers]
    end

    def read_request(connection)
      upload, headers = Timeout.timeout(@timeout) { read_headers(connection) }
      raise ArgumentError if headers.key?("transfer-encoding")
      length = headers.fetch("content-length", "")
      maximum = upload ? Asset::MAX_VIDEO_BYTES : MAX_BODY
      raise ArgumentError unless length.match?(/\A[0-9]{1,9}\z/) && length.to_i.between?(1, maximum)
      authorization = headers["authorization"].to_s
      token = authorization.delete_prefix("Bearer ") if authorization.start_with?("Bearer ")
      # Authenticate before reading or parsing the body.
      return [nil, token] unless @broker.authenticated?(token)
      if upload
        name = URI.decode_www_form_component(headers.fetch("x-github-asset-name", ""))
        asset = Timeout.timeout(@upload_timeout) do
          Asset.new(connection, name: name, content_type: headers["content-type"], size: length.to_i)
        end
        return [{ "operation" => "asset-upload", "repository" => headers["x-github-repository"], "asset" => asset }, token]
      end
      raise ArgumentError unless headers["content-type"] == "application/json"
      body = Timeout.timeout(@timeout) { connection.read(length.to_i) }
      raise ArgumentError unless body && body.bytesize == length.to_i
      [JSON.parse(body), token]
    end

    def write_response(connection, response)
      download = response.body.is_a?(Download)
      body = download ? response.body.file : response.body.b
      type = download ? response.body.content_type : "text/plain; charset=utf-8"
      length = download ? body.size : body.bytesize
      connection.write("HTTP/1.1 #{response.status} Response\r\nContent-Type: #{type}\r\nContent-Length: #{length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")
      if download
        while (chunk = body.read(64 * 1024))
          connection.write(chunk)
        end
      else
        connection.write(body)
      end
    end
  end

  def self.log(level, event, project, operation = nil, repository = nil, diagnostics = {})
    fields = {
      session_id: File.basename(ENV.fetch("GH_BRIDGE_SESSION_DIR", "unknown")),
      profile: ENV["GH_BRIDGE_PROFILE"], project: project, operation: operation, repository: repository,
    }.merge(diagnostics)
    details = fields.reject { |_, value| value.nil? }.map { |key, value| "#{key}=#{JSON.generate(value)}" }
    puts (["at=#{level}", "timestamp=#{Time.now.utc.iso8601(3)}", "event=#{event}"] + details).join(" ")
    $stdout.flush
  end

  def self.main
    project = ENV.fetch("GH_BRIDGE_PROJECT")
    policy = Policy.load(Policy.path, ENV.fetch("GH_BRIDGE_PROFILE"))
    certificate, private_key = OnePasswordBridge.certificate
    directory = ENV.fetch("GH_BRIDGE_SESSION_DIR")
    File.write(File.join(directory, "bridge", "ca.pem"), certificate.to_pem)
    Dir.mktmpdir("github-command-", directory) do |command_directory|
      executor = Executor.new(policy: policy, gh: ENV.fetch("GH_BRIDGE_GH_BIN"),
                              op: ENV.fetch("GH_BRIDGE_OP_BIN"), directory: command_directory)
      broker = Broker.new(policy: policy, token: ENV.fetch("GH_BRIDGE_TOKEN"), executor: executor,
                          approver: Approver.new(project, directory: command_directory),
                          logger: ->(level, event, operation, repository, diagnostics = {}) {
                            log(level, event, project, operation, repository, diagnostics)
                          })
      server = Server.new(broker: broker, certificate: certificate, private_key: private_key)
      Signal.trap("TERM") { server.close }
      Signal.trap("INT") { server.close }
      File.write(File.join(directory, "bridge", "port"), "#{server.port}\n")
      log("info", "broker_started", project)
      server.run
    end
  ensure
    log("info", "broker_stopped", project) if project
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    GitHubBridge.main
  rescue StandardError
    # Never log subprocess output, credentials, or request bodies.
    GitHubBridge.log("fatal", "startup_failed", ENV.fetch("GH_BRIDGE_PROJECT", "unknown"))
    exit 1
  end
end
