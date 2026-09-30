require "base64"
require "etc"
require "rbconfig"
require "socket"
require "timeout"
require_relative "session" unless defined?(SessionCLI)

# One supervised SSH/Tailcat bridge per invitation gives revocation a precise
# process boundary, including forwarding-only connections with no terminal.
class SessionRemote < SessionCLI
  PREFIX = "ai-session-v1."

  def run(action, argv)
    options = {ports: [], bind: "127.0.0.1"}
    parser = OptionParser.new do |p|
      p.banner = case action
                 when "join" then "Usage: ai session join INVITATION|@FILE [--port LOCAL_PORT:CONTAINER_PORT]"
                 when "invitations" then "Usage: ai session invitations NAME"
                 else "Usage: ai session #{action} NAME PARTICIPANT"
                 end
      p.on("--port PORT", "Forward LOCAL_PORT:CONTAINER_PORT (or the same PORT)") { |v| options[:ports] << v } if action == "join"
      if action == "join"
        %w[podman docker].each do |engine|
          p.on("--#{engine}", "Join using the published image through #{engine}") do
            raise Error, "choose either --podman or --docker" if options[:engine] && options[:engine] != engine
            options[:engine] = engine
          end
        end
        p.on("--image IMAGE", "Participant container image (default: #{DEFAULT_IMAGE})") { |value| options[:image] = value }
        p.on("--bind ADDRESS", %w[127.0.0.1 0.0.0.0], "Preview bind address (default: 127.0.0.1; containers: 0.0.0.0)") do |value|
          options[:bind] = value
          options[:explicit_bind] = true
        end
      end
      p.on("-h", "--help") { puts p; return 0 }
    end
    parser.parse!(argv)
    raise Error, parser.to_s unless argv.size == (%w[join invitations].include?(action) ? 1 : 2)
    unless action == "join"
      raise Error, "run session #{action} inside the Linux VM where the session is running" unless RUBY_PLATFORM.include?("linux")
      unless path_for(argv.first).join("session.json").file?
        raise Error, "session #{argv.first.inspect} was not found here; run this command in its VM (use ai session list)"
      end
    end

    case action
    when "join"
      if options[:engine]
        join_container(argv.first, options)
        return 0
      end
      raise Error, "--image requires --podman or --docker" if options[:image]
      token = argv.first
      if token.start_with?("@")
        token = File.open(File.expand_path(token.delete_prefix("@"))) { |file| file.read(16_384).to_s.strip }
      end
      join(token, options)
    when "invite" then invite(*argv)
    when "invitations" then invitations(argv.first)
    when "revoke"
      path = path_for(argv.first)
      locked(path) { revoke(path, invitation_path(path, argv.last)) }
    end
    0
  end

  def revoke_all(path)
    path.glob("invitations/*/invitation.json").each { |file| revoke(path, file.parent) }
  end

  def serve(directory)
    File.umask(0o077)
    directory = Pathname.new(directory)
    data = JSON.parse(directory.join("invitation.json").read)
    children = []
    %w[TERM INT].each { |signal| Signal.trap(signal) { exit } }
    begin
      children << Process.spawn("/usr/sbin/sshd", "-D", "-e", "-f", directory.join("sshd_config").to_s)
      children << Process.spawn({"TAILCAT_ADDR_FILE" => directory.join("address").to_s},
                                "tailcat", "serve", "--key=new", data.fetch("port").to_s)
      Process.wait2 # If either bridge component fails, systemd stops the rest.
      raise Error, "invitation bridge exited"
    ensure
      children.each do |pid|
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
        nil
      end
    end
  end

  def gateway(directory)
    directory = Pathname.new(directory)
    data = JSON.parse(directory.join("invitation.json").read)
    raise Error, "invitation revoked" unless data.fetch("status") == "active"
    raise Error, "remote commands are not supported" unless ENV.fetch("SSH_ORIGINAL_COMMAND", "").empty?

    ENV["AI_SESSION_DIR"] = data.fetch("session_root")
    attach(data.fetch("session"), participant: data.fetch("participant"))
  end

  private

  def command(*args)
    output, error, status = Open3.capture3(*args)
    raise Error, "#{args.first}: #{error.strip}" unless status.success?

    output
  end

  def invitation_path(path, participant)
    path_for(participant) # Reuse the restricted name syntax for directory names.
    path.join("invitations", participant)
  end

  def active?(data)
    system("systemctl", "--user", "is-active", "--quiet", data.fetch("unit"))
  end

  def invite(name, participant)
    path = path_for(name)
    directory = invitation_path(path, participant)
    locked(path) do
      metadata = load(path)
      raise Error, "session is not running" unless metadata.fetch("status") == "running" && container_state(metadata) == "running"
      if directory.exist?
        data = JSON.parse(directory.join("invitation.json").read)
        raise Error, "invitation is inactive; use a new participant name" unless data.fetch("status") == "active" && active?(data)
      else
        create_invitation(path, directory, metadata, participant)
      end
      puts directory.join("token").read
    end
  end

  def create_invitation(path, directory, metadata, participant)
    user = Etc.getpwuid.name
    linger = command("loginctl", "show-user", user, "--property=Linger", "--value").strip
    raise Error, "enable persistent user services first: sudo loginctl enable-linger #{user}" unless linger == "yes"

    directory.mkpath
    directory.chmod(0o700)
    %w[host_key identity].each do |file|
      command("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", directory.join(file).to_s)
    end
    # The container may edit the working repository. Execute a private snapshot
    # of gateway code that is never mounted into the agent container.
    directory.join("code").mkdir
    %w[session.rb remote.rb].each { |file| FileUtils.cp(Pathname.new(__dir__).join(file), directory.join("code", file)) }
    port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
    previews = preview_ports(metadata)
    data = {"session" => metadata.fetch("name"), "session_root" => root.to_s,
            "participant" => participant, "status" => "active", "port" => port,
            "unit" => "ai-invite-#{SecureRandom.hex(12)}", "user" => user}
    write_json(directory.join("invitation.json"), data)
    directory.join("authorized_keys").write("restrict,pty,port-forwarding #{directory.join('identity.pub').read}")
    gateway = [RbConfig.ruby, directory.join("code/remote.rb").to_s, "gateway", directory.to_s].shelljoin
    permitted = previews.empty? ? "none" : previews.values.map { |value| "127.0.0.1:#{value}" }.join(" ")
    directory.join("sshd_config").write(<<~CONFIG)
      ListenAddress 127.0.0.1
      Port #{port}
      HostKey #{directory.join('host_key').to_s.to_json}
      PidFile #{directory.join('sshd.pid').to_s.to_json}
      AuthorizedKeysFile #{directory.join('authorized_keys').to_s.to_json}
      AllowUsers #{user}
      AuthenticationMethods publickey
      PubkeyAuthentication yes
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      UsePAM no
      PermitRootLogin yes
      PermitUserEnvironment no
      PermitUserRC no
      AllowAgentForwarding no
      X11Forwarding no
      PermitTunnel no
      AllowStreamLocalForwarding no
      AllowTcpForwarding local
      PermitOpen #{permitted}
      PermitListen none
      MaxAuthTries 3
      LoginGraceTime 20
      ForceCommand #{gateway}
      LogLevel VERBOSE
    CONFIG
    command("/usr/sbin/sshd", "-t", "-f", directory.join("sshd_config").to_s)
    begin
      command("systemd-run", "--user", "--quiet", "--collect", "--unit", data.fetch("unit"),
              "--property=KillMode=control-group", "--property=TimeoutStopSec=5", "--property=UMask=0077",
              "--setenv=PATH=#{ENV.fetch('PATH')}", RbConfig.ruby,
              directory.join("code/remote.rb").to_s, "serve", directory.to_s)
      Timeout.timeout(45) do
        loop do
          raise Error, "bridge failed; inspect journalctl --user -u #{data.fetch('unit')}" unless active?(data)
          break if directory.join("address").file? && !directory.join("address").read.strip.empty?
          sleep 0.1
        end
        # Tailcat writes its address before its DERP connection is established.
        # Verify a round trip before handing out an immediately usable token.
        loop do
          _, _, status = Open3.capture3("tailcat", "ping", "--timeout=3s", directory.join("address").read.strip)
          break if status.success?
          raise Error, "invitation bridge stopped" unless active?(data)
        end
      end
      token = {"id" => SecureRandom.hex(16), "session" => metadata.fetch("name"),
               "participant" => participant, "address" => directory.join("address").read.strip,
               "port" => port, "user" => user, "host_key" => public_key(directory.join("host_key.pub").read),
               "identity" => directory.join("identity").read, "previews" => previews}
      directory.join("token").write(PREFIX + Base64.urlsafe_encode64(JSON.generate(token), padding: false) + "\n")
      log(path, "invitation_created", participant: participant)
      docker("exec", metadata.fetch("container"), "tmux", "-L", "ai", "set", "-g", "status-left",
             " #{metadata.fetch('name')} | shared ")
    rescue StandardError
      revoke(path, directory)
      raise
    end
  rescue Timeout::Error
    raise Error, "Tailcat did not become ready within 45 seconds"
  end

  def preview_ports(metadata)
    info = JSON.parse(docker("inspect", metadata.fetch("container")).first).first
    info.fetch("NetworkSettings").fetch("Ports").each_with_object({}) do |(port, bindings), result|
      next unless port.end_with?("/tcp")
      binding = (bindings || []).find { |entry| entry.fetch("HostIp") == "127.0.0.1" }
      result[port.delete_suffix("/tcp")] = Integer(binding.fetch("HostPort")) if binding
    end
  end

  def write_json(file, data)
    temporary = Pathname.new("#{file}.tmp")
    temporary.write(JSON.pretty_generate(data) + "\n")
    temporary.rename(file)
  end

  def public_key(value)
    parts = value.split
    raise Error, "invalid SSH host key" unless parts.size >= 2 && parts[0] == "ssh-ed25519" && parts[1].match?(/\A[A-Za-z0-9+\/=]+\z/)

    parts.first(2).join(" ")
  end

  def invitations(name)
    path = path_for(name)
    puts "PARTICIPANT\tSTATUS"
    path.glob("invitations/*/invitation.json").sort.each do |file|
      data = JSON.parse(file.read)
      status = data.fetch("status")
      status = "offline" if status == "active" && !active?(data)
      puts "#{data.fetch('participant')}\t#{status}"
    end
    puts "Redisplay an invitation: bin/ai session invite #{name} PARTICIPANT"
  end

  def revoke(path, directory)
    data = JSON.parse(directory.join("invitation.json").read)
    return if data.fetch("status") == "revoked"

    # Remove credentials before disconnecting the entire service cgroup.
    directory.join("authorized_keys").write("")
    command("systemctl", "--user", "stop", data.fetch("unit")) if active?(data)
    data["status"] = "revoked"
    write_json(directory.join("invitation.json"), data)
    %w[token identity identity.pub].each { |file| directory.join(file).delete if directory.join(file).exist? }
    log(path, "invitation_revoked", participant: data.fetch("participant"))
  end

  def decode(token)
    raise Error, "invalid invitation" unless token.start_with?(PREFIX) && token.bytesize < 16_384
    data = JSON.parse(Base64.urlsafe_decode64(token.delete_prefix(PREFIX)))
    raise Error, "invalid invitation identity" unless data.fetch("identity").is_a?(String) &&
      data.fetch("identity").start_with?("-----BEGIN OPENSSH PRIVATE KEY-----\n")
    raise Error, "invalid invitation ID" unless data.fetch("id").match?(/\A[0-9a-f]{32}\z/)
    raise Error, "invalid Tailcat address" unless data.fetch("address").match?(/\Atc[A-Za-z0-9_-]+\z/)
    raise Error, "invalid SSH user" unless data.fetch("user").match?(/\A[a-zA-Z_][a-zA-Z0-9_-]*\z/)
    valid_port(data.fetch("port"))
    public_key(data.fetch("host_key"))
    data.fetch("previews").each { |container, host| valid_port(container); valid_port(host) }
    data
  rescue KeyError, JSON::ParserError, TypeError, NoMethodError
    raise Error, "invalid invitation"
  end

  def valid_port(value)
    raise Error, "invalid port" unless value.to_s.match?(/\A[0-9]+\z/) && (1..65535).cover?(value.to_i)
    value.to_i
  end

  def client_files(token)
    data = decode(token)
    directory = Pathname.new(ENV.fetch("XDG_CONFIG_HOME", "#{Dir.home}/.config")).join("ai/session-joins", data.fetch("id"))
    directory.mkpath
    directory.chmod(0o700)
    directory.join("identity").open("w", 0o600) { |file| file.write(data.fetch("identity")) }
    directory.join("known_hosts").write("ai-session-#{data.fetch('id')} #{public_key(data.fetch('host_key'))}\n")
    [data, directory]
  end

  def require_program(name, hint)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
      path = File.expand_path(File.join(directory, name))
      return path if File.file?(path) && File.executable?(path)
    end
    raise Error, "#{name} was not found on PATH; #{hint}"
  end

  def ssh_command(data, directory, ssh:, tailcat:)
    # SSH runs ProxyCommand through the user's shell, whose startup files may
    # change PATH. Use the executable we checked, escaping SSH's percent tokens.
    proxy = [tailcat, "--key=new", data.fetch("address"), data.fetch("port").to_s].shelljoin.gsub("%", "%%")
    [ssh, "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
     "-o", "IdentityAgent=none", "-o", "StrictHostKeyChecking=yes",
     "-o", "UserKnownHostsFile=#{directory.join('known_hosts').to_s.to_json}", "-o", "GlobalKnownHostsFile=/dev/null",
     "-o", "HostKeyAlias=ai-session-#{data.fetch('id')}", "-o", "ProxyCommand=#{proxy}",
     "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=2", "-o", "ExitOnForwardFailure=yes",
     "-i", directory.join("identity").to_s, "-l", data.fetch("user")]
  end

  def preview_forwards(data, mappings)
    mappings.map do |mapping|
      parts = mapping.split(":", -1)
      raise Error, "use PORT or LOCAL_PORT:CONTAINER_PORT" unless (1..2).cover?(parts.length)
      local = valid_port(parts.first)
      container = valid_port(parts.last).to_s
      host = data.fetch("previews")[container]
      unless host
        available = data.fetch("previews").keys.sort_by(&:to_i).join(", ")
        available = "none" if available.empty?
        raise Error, "container port #{container} was not published by this session. " \
                     "Available container ports: #{available}. " \
                     "Publish app ports with session start --port, not VM --ports."
      end
      [local, container, host]
    end
  end

  def join_container(argument, options)
    engine = options.fetch(:engine)
    executable = require_program(engine, "install #{engine} and start its container engine")
    raise Error, "join requires a terminal" unless $stdin.tty? && $stdout.tty?
    raise Error, "--#{engine} requires an invitation file: join --#{engine} @alice.invite" unless argument.start_with?("@")
    raise Error, "--#{engine} manages preview binding; omit --bind" if options[:explicit_bind]

    invitation = Pathname.new(File.expand_path(argument.delete_prefix("@"))).realpath
    raise Error, "invitation mount paths cannot contain commas" if invitation.to_s.include?(",")
    data = decode(invitation.open { |file| file.read(16_384).to_s.strip })
    forwards = preview_forwards(data, options.fetch(:ports))
    args = [executable, "run", "--rm", "--init", "-it", "--label", "ai.session.client=#{data.fetch('id')}",
            "--mount", "type=bind,src=#{invitation},dst=/invitation,readonly"]
    forwards.each { |local, _, _| args.concat(["--publish", "127.0.0.1:#{local}:#{local}"]) }
    args.concat(["--entrypoint", "ai-join", options.fetch(:image, DEFAULT_IMAGE), "@/invitation", "--bind", "0.0.0.0"])
    forwards.each { |local, container, _| args.concat(["--port", "#{local}:#{container}"]) }
    result = run_terminal(*args)
    raise Error, "#{engine} join ended with status #{result}" unless result.zero?
  end

  def join(token, options)
    tailcat = require_program("tailcat", "install Tailcat on this machine (macOS: brew install tailcat)")
    ssh = require_program("ssh", "install the OpenSSH client on this machine")
    raise Error, "join requires a terminal" unless $stdin.tty? && $stdout.tty?
    data, directory = client_files(token)
    args = ssh_command(data, directory, ssh: ssh, tailcat: tailcat)
    preview_forwards(data, options.fetch(:ports)).each do |local, _, host|
      args.concat(["-L", "#{options.fetch(:bind)}:#{local}:127.0.0.1:#{host}"])
      puts "App preview: http://127.0.0.1:#{local} (while attached)"
    end
    puts "Joining shared terminal. Detach with Ctrl+b, then d."
    $stdout.flush
    result = run_terminal(*args, "-tt", "session")
    raise Error, "connection ended with status #{result}" unless result.zero?
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    bridge = SessionRemote.new
    case ARGV.shift
    when "serve" then bridge.serve(ARGV.fetch(0))
    when "gateway" then exit bridge.gateway(ARGV.fetch(0))
    else raise SessionCLI::Error, "invalid bridge command"
    end
  rescue SessionCLI::Error, SystemCallError, ArgumentError => e
    warn "ai session: #{e.message}"
    exit 1
  end
end
