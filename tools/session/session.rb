require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "securerandom"
require "shellwords"
require "time"

class SessionCLI
  class Error < StandardError; end

  REPO = Pathname.new(__dir__).join("../..").realpath
  DEFAULT_IMAGE = "ghcr.io/dentarg/ai:latest"
  ACTIONS = %w[start attach list stop logs replay ports invite invitations revoke join].freeze

  def self.run(argv)
    new.run(argv)
  rescue Error, ArgumentError, SystemCallError, OptionParser::ParseError => e
    warn "ai session: #{e.message}"
    1
  end

  def run(argv)
    File.umask(0o077)
    argv = argv.dup
    action = argv.shift
    if action.nil? || %w[-h --help].include?(action)
      puts "Usage: ai session <#{ACTIONS.join('|')}> [arguments]"
      return 0
    end
    raise Error, "unknown command: #{action}" unless ACTIONS.include?(action)
    if %w[invite invitations revoke join].include?(action)
      require_relative "remote"
      return SessionRemote.new.run(action, argv)
    end

    command = argv.include?("--") ? argv.slice!(argv.index("--")..)[1..] : []
    options = {image: DEFAULT_IMAGE, workspace: Dir.pwd, settings: "/settings",
               ports: [], max_delay: 2.0}
    parser = OptionParser.new do |p|
      p.banner = "Usage: ai session #{action}#{action == 'list' ? '' : ' NAME'} [options]"
      if action == "start"
        p.banner += " -- COMMAND [arguments]"
        p.on("--image IMAGE", "Container image (default: #{DEFAULT_IMAGE})") { |v| options[:image] = v }
        p.on("--workspace DIRECTORY") { |v| options[:workspace] = v }
        p.on("--settings DIRECTORY") { |v| options[:settings] = v }
        p.on("--detach") { options[:detach] = true }
        p.on("--port PORT", "Publish PORT or VM_PORT:PORT on VM loopback") do |v|
          options[:ports] << published_port(v)
        end
      end
      p.on("--read-only") { options[:read_only] = true } if action == "attach"
      p.on("--max-delay SECONDS", Float) { |v| options[:max_delay] = v } if action == "replay"
      p.on("-h", "--help") { puts p; return 0 }
    end
    parser.parse!(argv)
    expected = action == "list" ? 0 : 1
    raise Error, parser.to_s unless argv.length == expected
    raise Error, "only start accepts a command after --" if action != "start" && !command.empty?

    name = argv.first
    case action
    when "start" then start(name, options, command)
    when "attach" then attach(name, options)
    when "list" then list
    when "stop" then stop(name)
    when "logs" then print path_for(name).join("events.log").read
    when "ports" then ports(name)
    when "replay"
      delay = options.fetch(:max_delay)
      raise Error, "max-delay must be positive and finite" unless delay.positive? && delay.finite?

      path = path_for(name).join("recording")
      return run_terminal("scriptreplay", "--log-out", path.join("output").to_s,
                          "--log-timing", path.join("timing").to_s, "--maxdelay", delay.to_s)
    end || 0
  end

  private

  def root
    history = File.directory?("/history") ? "/history" : File.join(ENV.fetch("AI_DIR", "#{Dir.home}/ai"), "history")
    path = Pathname.new(ENV.fetch("AI_SESSION_DIR", "#{history}/multiplayer")).expand_path
    path.exist? ? path.realpath : path
  end

  def path_for(name)
    raise Error, "session name must be 1–64 letters, digits, underscores or hyphens" unless
      name&.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/)

    root.join(name)
  end

  def locked(path)
    path.join(".lock").open("a") do |file|
      file.flock(File::LOCK_EX)
      yield
    end
  end

  def save(path, metadata)
    temporary = path.join("session.json.tmp")
    temporary.write(JSON.pretty_generate(metadata) + "\n")
    temporary.rename(path.join("session.json"))
  end

  def load(path)
    JSON.parse(path.join("session.json").read)
  end

  def log(path, event, **fields)
    fields = {at: "info", event: event, time: Time.now.utc.iso8601(6), **fields}
    line = fields.map do |key, value|
      value = value.to_s
      "#{key}=#{value.match?(/\A[\w.:\/+_-]+\z/) ? value : value.to_json}"
    end.join(" ")
    path.join("events.log").open("a", 0o600) { |file| file.syswrite(line + "\n") }
  end

  def docker(*args, check: true)
    stdout, stderr, status = Open3.capture3("docker", *args)
    raise Error, stderr.strip.empty? ? "Docker command failed" : stderr.strip if check && !status.success?

    [stdout, status.success?]
  end

  def container_state(metadata)
    output, success = docker("inspect", metadata.fetch("container"), check: false)
    unless success
      # A failed daemon connection does not mean the session was removed.
      docker("info", "--format", "{{.ServerVersion}}")
      return "missing"
    end
    info = JSON.parse(output).first
    raise Error, "container does not belong to this session" unless
      info.fetch("Config").fetch("Labels", {})["ai.session.id"] == metadata.fetch("id")

    info.fetch("State").fetch("Status")
  end

  def published_port(value)
    raise Error, "use CONTAINER_PORT or VM_PORT:CONTAINER_PORT" unless value.match?(/\A[0-9]+(?::[0-9]+)?\z/)

    ports = value.split(":").map(&:to_i)
    raise Error, "ports must be between 1 and 65535" unless ports.all? { |port| (1..65535).cover?(port) }

    "127.0.0.1:#{ports.length == 1 ? ':' : ''}#{ports.join(':')}"
  end

  def start(name, options, command)
    raise Error, "start sessions inside the Linux sandbox VM" unless RUBY_PLATFORM.include?("linux")
    raise Error, "supply the agent command after -- (for example: -- c myprofile)" if command.empty?

    workspace = Pathname.new(options.fetch(:workspace)).realpath
    settings = Pathname.new(options.fetch(:settings)).realpath
    raise Error, "workspace and settings must be directories" unless workspace.directory? && settings.directory?

    path = path_for(name)
    raise Error, "session already exists: #{name}" if path.exist?
    if [workspace, settings].any? { |mount| path.ascend.any? { |ancestor| ancestor == mount } }
      raise Error, "session state must be outside the workspace and settings mounts"
    end
    raise Error, "Docker bind mount paths cannot contain commas" if
      [workspace, settings, path, REPO].any? { |source| source.to_s.include?(",") }

    image = options.fetch(:image)
    unless docker("image", "inspect", image, check: false).last
      puts "Pulling #{image}..."
      docker("pull", image)
    end
    path.parent.mkpath
    path.mkdir(0o700) # Reserve the name without overwriting any previous history.
    locked(path) do
      identifier = SecureRandom.hex(16)
      metadata = {"id" => identifier, "name" => name, "container" => "ai-session-#{identifier}",
                  "image" => image, "workspace" => workspace.to_s, "status" => "starting"}
      save(path, metadata)
      begin
        prepare(path)
        docker(*container_command(path, metadata, settings, options))
        agent = ["bash", "-ic", "exec #{command.shelljoin}"].shelljoin
        recorder = ["script", "--quiet", "--flush", "--return", "--log-out", "/recording/output",
                    "--log-timing", "/recording/timing", "--command", agent].shelljoin
        docker("exec", metadata.fetch("container"), "tmux", "-L", "ai",
               "-f", "/session-config/tmux.conf", "new-session", "-d", "-s", name,
               "-x", "120", "-y", "40", recorder)
        metadata["status"] = "running"
        save(path, metadata)
        log(path, "session_started", session: name)
      rescue StandardError, Interrupt
        docker("rm", "--force", metadata.fetch("container"), check: false)
        metadata["status"] = "failed"
        save(path, metadata)
        log(path, "session_failed", session: name)
        raise
      end
    end
    puts "Session ready: #{name}\nAttach: bin/ai session attach #{name}"
    $stdout.flush
    options[:detach] ? 0 : attach(name, options)
  end

  def prepare(path)
    %w[history recording config commandhistory bundle].each { |directory| path.join(directory).mkdir }
    path.join("config/tmux.conf").write(<<~TMUX)
      set -g remain-on-exit on
      set -g history-limit 50000
      set -g window-size latest
      set -g prefix C-b
      set -g assume-paste-time 0
      bind-key d detach-client
      bind-key i display-message -d 0 'Owner commands: ai session invitations #{path.basename}; ai session logs #{path.basename}. Reconnect using your invitation.'
      set -g status-left-length 60
      set -g status-left ' \#S | local session '
      set -g status-right 'info: Ctrl+b i | detach: Ctrl+b d '
    TMUX
  end

  def container_command(path, metadata, settings, options)
    args = ["run", "--detach", "--init", "--name", metadata.fetch("container"),
            "--label", "ai.session.id=#{metadata.fetch('id')}",
            "--security-opt", "no-new-privileges", "--workdir", "/app",
            "--env", "HOME=/workspace", "--env", "TERM=xterm-256color", "--env", "IS_SANDBOX=1",
            "--env", "HOST_DIR=#{File.basename(metadata.fetch('workspace'))}"]
    mounts = [[metadata.fetch("workspace"), "/app", false], [settings, "/settings", true],
              [REPO.join("claude"), "/claude", true], [path.join("history"), "/history", false],
              [path.join("recording"), "/recording", false], [path.join("config"), "/session-config", true],
              [path.join("commandhistory"), "/commandhistory", false], [path.join("bundle"), "/bundle", false]]
    mounts.each do |source, target, readonly|
      args.concat(["--mount", "type=bind,src=#{source},dst=#{target}#{readonly ? ',readonly' : ''}"])
    end
    options.fetch(:ports).each { |port| args.concat(["--publish", port]) }
    args + ["--entrypoint", "sleep", metadata.fetch("image"), "infinity"]
  end

  def run_terminal(*command)
    pid = Process.spawn(*command)
    _, status = Process.wait2(pid)
    status.exitstatus || 128 + status.termsig
  ensure
    if pid && !status
      begin
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  def attach(name, options)
    raise Error, "attach requires a terminal" unless $stdin.tty? && $stdout.tty?

    path = path_for(name)
    metadata = locked(path) do
      data = load(path)
      raise Error, "session is not running" unless data.fetch("status") == "running" && container_state(data) == "running"

      data
    end
    connection = SecureRandom.hex(6)
    readonly = options[:read_only]
    log(path, "terminal_attached", connection: connection, access: readonly ? "read" : "write",
        participant: options.fetch(:participant, "owner"))
    command = ["docker", "exec", "-it", "-e", "TERM=#{ENV.fetch('TERM', 'xterm-256color')}",
               metadata.fetch("container"), "tmux", "-L", "ai", "attach-session", "-t", name]
    command.concat(["-r", "-f", "ignore-size"]) if readonly
    handlers = %w[HUP TERM].to_h { |sig| [sig, Signal.trap(sig) { exit 128 + Signal.list.fetch(sig) }] }
    begin
      run_terminal(*command)
    ensure
      log(path, "terminal_detached", connection: connection)
      handlers.each { |sig, handler| Signal.trap(sig, handler) }
    end
  end

  def stop(name)
    path = path_for(name)
    locked(path) do
      metadata = load(path)
      return 0 if metadata.fetch("status") == "stopped"

      require_relative "remote"
      SessionRemote.new.revoke_all(path)

      container = metadata.fetch("container")
      unless container_state(metadata) == "missing"
        docker("exec", container, "tmux", "-L", "ai", "kill-server", check: false)
        docker("stop", "--time", "5", container)
        docker("rm", container)
      end
      metadata["status"] = "stopped"
      save(path, metadata)
      log(path, "session_stopped", session: name)
    end
    puts "Stopped #{name}. History retained at #{path}"
    0
  end

  def list
    puts "NAME\tSTATUS\tWORKSPACE"
    root.glob("*/session.json").sort.each do |file|
      metadata = load(file.parent)
      status = metadata.fetch("status")
      if status == "running"
        status = container_state(metadata)
        if status == "running"
          pane, success = docker("exec", metadata.fetch("container"), "tmux", "-L", "ai",
                                 "list-panes", "-F", '#{pane_dead}', check: false)
          status = "exited" if !success || pane.strip == "1"
        end
      end
      puts "#{metadata.fetch('name')}\t#{status}\t#{metadata.fetch('workspace')}"
    end
    0
  end

  def ports(name)
    metadata = load(path_for(name))
    raise Error, "session is not running" unless container_state(metadata) == "running"

    info = JSON.parse(docker("inspect", metadata.fetch("container")).first).first
    puts "CONTAINER\tVM URL"
    info.fetch("NetworkSettings").fetch("Ports").sort.each do |port, bindings|
      (bindings || []).each { |binding| puts "#{port}\thttp://127.0.0.1:#{binding.fetch('HostPort')}" }
    end
    0
  end
end

exit SessionCLI.run(ARGV) if $PROGRAM_NAME == __FILE__
