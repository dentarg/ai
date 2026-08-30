#!/usr/bin/env ruby

require "json"
require "openssl"
require "open3"
require "socket"

module OnePasswordBridge
  Response = Struct.new(:status, :body)

  class Policy
    ALIAS_PATTERN = /\A[a-z0-9][a-z0-9._-]{0,63}\z/
    ACCOUNT_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/

    attr_reader :account

    def self.load(path, project)
      stat = File.stat(path)
      raise "policy must be owned by the current user" unless stat.uid == Process.uid
      raise "policy must not be group- or world-writable" unless (stat.mode & 0o022).zero?

      document = JSON.parse(File.read(path))
      project_policy = document.fetch("projects").fetch(project)
      new(project_policy.fetch("account"), project_policy.fetch("secrets"))
    rescue Errno::ENOENT
      raise "policy not found: #{path}"
    rescue KeyError
      raise "no 1Password policy for project: #{project}"
    rescue JSON::ParserError => error
      raise "invalid policy JSON: #{error.message}"
    end

    def initialize(account, secrets)
      raise "invalid 1Password account" unless account.is_a?(String) && account.match?(ACCOUNT_PATTERN)
      raise "secrets must be an object" unless secrets.is_a?(Hash)

      @account = account
      @secrets = secrets.to_h do |alias_name, reference|
        unless alias_name.is_a?(String) && alias_name.match?(ALIAS_PATTERN)
          raise "invalid secret alias: #{alias_name.inspect}"
        end
        unless reference.is_a?(String) && reference.start_with?("op://")
          raise "invalid 1Password reference for alias: #{alias_name}"
        end

        [alias_name, reference]
      end.freeze
    end

    def reference_for(alias_name)
      @secrets[alias_name]
    end
  end

  class Approver
    def initialize(project)
      @project = project
    end

    def approve?(alias_name)
      message = "Project: #{@project}\nSecret: #{alias_name}\n\nAllow this one retrieval?"
      script = <<~APPLESCRIPT
        on run arguments
          display dialog (item 1 of arguments) \
            buttons {"Deny", "Allow"} default button "Deny" cancel button "Deny" \
            with title "AI secret request"
        end run
      APPLESCRIPT
      _output, _error, status = Open3.capture3(
        "/usr/bin/osascript",
        "-",
        message,
        stdin_data: script,
      )
      status.success?
    rescue SystemCallError
      false
    end
  end

  class SecretReader
    def initialize(op_bin)
      @op_bin = op_bin
    end

    def read(account, reference)
      output, _error, status = Open3.capture3(
        @op_bin,
        "read",
        "--account",
        account,
        reference,
      )
      raise "1Password CLI failed" unless status.success?

      output
    end
  end

  class Broker
    def initialize(policy:, token:, approver:, reader:, logger:)
      @policy = policy
      @token = token
      @approver = approver
      @reader = reader
      @logger = logger
    end

    def resolve(alias_name, token)
      unless authenticated?(token)
        @logger.call("warn", "authentication_failed", alias_name)
        return Response.new(401, "unauthorized\n")
      end

      reference = @policy.reference_for(alias_name)
      unless reference
        @logger.call("warn", "unknown_alias", alias_name)
        return Response.new(404, "unknown secret alias\n")
      end

      unless @approver.approve?(alias_name)
        @logger.call("info", "request_denied", alias_name)
        return Response.new(403, "secret request denied\n")
      end

      secret = @reader.read(@policy.account, reference)
      @logger.call("info", "secret_read", alias_name)
      Response.new(200, secret)
    rescue StandardError
      @logger.call("error", "secret_read_failed", alias_name)
      Response.new(502, "1Password request failed\n")
    end

    private

    def authenticated?(candidate)
      return false unless candidate&.bytesize == @token.bytesize

      OpenSSL.fixed_length_secure_compare(candidate, @token)
    end
  end

  class Server
    STATUS_TEXT = {
      200 => "OK",
      400 => "Bad Request",
      401 => "Unauthorized",
      403 => "Forbidden",
      404 => "Not Found",
      405 => "Method Not Allowed",
      431 => "Request Header Fields Too Large",
      502 => "Bad Gateway",
    }.freeze

    MAX_HEADER_BYTES = 16 * 1024

    attr_reader :port

    def initialize(broker:, certificate:, private_key:, bind: "0.0.0.0", port: 0)
      @broker = broker
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
        connection = nil
        begin
          connection = @server.accept
          handle(connection)
        rescue OpenSSL::SSL::SSLError
          next
        rescue IOError, SystemCallError
          raise unless @closed

          break
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

    def handle(connection)
      request_line = connection.gets
      return unless request_line

      headers = read_headers(connection)
      return write_response(connection, Response.new(431, "headers too large\n")) unless headers

      method, path, version = request_line.strip.split(" ", 3)
      return write_response(connection, Response.new(400, "bad request\n")) unless version&.start_with?("HTTP/")
      return write_response(connection, Response.new(405, "method not allowed\n")) unless method == "POST"

      match = path.match(%r{\A/v1/secrets/([a-z0-9][a-z0-9._-]{0,63})\z})
      return write_response(connection, Response.new(404, "not found\n")) unless match

      authorization = headers["authorization"]
      token = authorization&.delete_prefix("Bearer ") if authorization&.start_with?("Bearer ")
      write_response(connection, @broker.resolve(match[1], token))
    end

    def read_headers(connection)
      headers = {}
      bytes = 0
      while (line = connection.gets)
        bytes += line.bytesize
        return if bytes > MAX_HEADER_BYTES
        break if line == "\r\n" || line == "\n"

        name, value = line.split(":", 2)
        return unless value

        headers[name.downcase] = value.strip
      end
      headers
    end

    def write_response(connection, response)
      reason = STATUS_TEXT.fetch(response.status)
      body = response.body.b
      connection.write("HTTP/1.1 #{response.status} #{reason}\r\n")
      connection.write("Content-Type: text/plain\r\n")
      connection.write("Content-Length: #{body.bytesize}\r\n")
      connection.write("Cache-Control: no-store\r\n")
      connection.write("Connection: close\r\n\r\n")
      connection.write(body)
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

  def self.log(level, event, project, alias_name = nil, error: nil)
    fields = ["at=#{level}", "event=#{event}", "project=#{JSON.generate(project)}"]
    fields << "alias=#{JSON.generate(alias_name)}" if alias_name
    fields << "error=#{JSON.generate(error)}" if error
    $stdout.puts(fields.join(" "))
    $stdout.flush
  end

  def self.main
    project = ENV.fetch("OP_BRIDGE_PROJECT")
    policy = Policy.load(ENV.fetch("OP_BRIDGE_POLICY"), project)
    certificate, private_key = certificate()
    File.write(ENV.fetch("OP_BRIDGE_CA_FILE"), certificate.to_pem)

    logger = ->(level, event, alias_name) { log(level, event, project, alias_name) }
    broker = Broker.new(
      policy: policy,
      token: ENV.fetch("OP_BRIDGE_TOKEN"),
      approver: Approver.new(project),
      reader: SecretReader.new(ENV.fetch("OP_BRIDGE_OP_BIN")),
      logger: logger,
    )
    server = Server.new(broker: broker, certificate: certificate, private_key: private_key)
    Signal.trap("TERM") { server.close }
    Signal.trap("INT") { server.close }
    File.write(ENV.fetch("OP_BRIDGE_PORT_FILE"), "#{server.port}\n")
    log("info", "broker_started", project)
    server.run
  ensure
    log("info", "broker_stopped", project) if project
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    OnePasswordBridge.main
  rescue StandardError => error
    OnePasswordBridge.log(
      "fatal",
      "startup_failed",
      ENV.fetch("OP_BRIDGE_PROJECT", "unknown"),
      error: error.message,
    )
    exit 1
  end
end
