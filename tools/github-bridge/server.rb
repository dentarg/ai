require "socket"
require "tmpdir"
require_relative "executor"
require_relative "../onepassword-bridge/server"

module GitHubBridge
  class Server
    MAX_HEADERS = 16 * 1024
    MAX_BODY = 16 * 1024
    attr_reader :port

    def initialize(broker:, certificate:, private_key:, bind: "0.0.0.0", timeout: 10)
      @broker, @timeout = broker, timeout
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
        begin
          connection = @server.accept
          request, token = Timeout.timeout(@timeout) do
            connection.accept
            read_request(connection)
          end
          response = @broker.call(request, token)
          Timeout.timeout(@timeout) { write_response(connection, response) }
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

    def read_request(connection)
      line = read_line(connection)
      raise ArgumentError unless line == "POST /v1/github HTTP/1.1\r\n"
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
      raise ArgumentError if headers.key?("transfer-encoding")
      length = headers.fetch("content-length", "")
      raise ArgumentError unless length.match?(/\A[0-9]{1,5}\z/) && length.to_i.between?(1, MAX_BODY)
      raise ArgumentError unless headers["content-type"] == "application/json"
      authorization = headers["authorization"].to_s
      token = authorization.delete_prefix("Bearer ") if authorization.start_with?("Bearer ")
      # Authenticate before reading or parsing the body.
      return [nil, token] unless @broker.authenticated?(token)
      body = connection.read(length.to_i)
      raise ArgumentError unless body && body.bytesize == length.to_i
      [JSON.parse(body), token]
    end

    def write_response(connection, response)
      body = response.body.b
      connection.write("HTTP/1.1 #{response.status} Response\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: #{body.bytesize}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")
      connection.write(body)
    end
  end

  def self.log(level, event, project, operation = nil, repository = nil)
    fields = { profile: ENV["GH_BRIDGE_PROFILE"], project: project, operation: operation, repository: repository }
    details = fields.reject { |_, value| value.nil? }.map { |key, value| "#{key}=#{JSON.generate(value)}" }
    puts (["at=#{level}", "event=#{event}"] + details).join(" ")
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
                          logger: ->(level, event, operation, repository) { log(level, event, project, operation, repository) })
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
