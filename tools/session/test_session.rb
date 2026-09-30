require "minitest/autorun"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "pty"
require "tmpdir"
require_relative "remote"

class SessionTerminal
  def initialize(env, *args, command: nil)
    command ||= [File.expand_path("../../bin/ai", __dir__), "session", *args]
    @reader, @writer, @pid = PTY.spawn(env, *command)
    @writer.sync = true
    @output = +"".b
  end

  def write(text)
    @writer.write(text)
  end

  def expect(text)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    until @output.include?(text)
      raise "missing #{text.inspect} in #{@output.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      next unless IO.select([@reader], nil, nil, 0.1)

      @output << @reader.readpartial(65_536)
    end
  rescue EOFError, Errno::EIO
    raise "terminal closed: #{@output.inspect}"
  end

  def close
    @reader.close unless @reader.closed?
    @writer.close unless @writer.closed?
    100.times do
      return if Process.waitpid(@pid, Process::WNOHANG)

      sleep 0.05
    end
    Process.kill("KILL", @pid)
    Process.waitpid(@pid)
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  end
end

class SessionTest < Minitest::Test
  CLI = File.expand_path("../../bin/ai", __dir__)
  IMAGE = ENV.fetch("AI_SESSION_TEST_IMAGE", "ai-session-test:latest")

  def setup
    # OpenSSH checks every ancestor of authorized_keys; /tmp is world-writable.
    @root = Dir.mktmpdir("ai session test ", Dir.home)
    @workspace = File.join(@root, "project with spaces")
    @settings = File.join(@root, "settings")
    FileUtils.mkdir_p([@workspace, @settings])
    @env = {"AI_SESSION_DIR" => File.join(@root, "sessions"), "TERM" => "xterm-256color",
            "XDG_CONFIG_HOME" => File.join(@root, "client")}
    @clients = []
    @sessions = []
  end

  def teardown
    @clients.each(&:close)
    @sessions.each { |name| cli("stop", name, check: false) }
    FileUtils.rm_rf(@root)
  end

  def cli(*args, check: true)
    output, error, status = Open3.capture3(@env, CLI, "session", *args)
    assert status.success?, "#{args.inspect}: #{output}\n#{error}" if check
    [output, error, status]
  end

  def start(name, *command, image: IMAGE, ports: [])
    @sessions << name
    cli("start", name, "--detach", "--image", image,
        "--workspace", @workspace, "--settings", @settings,
        *ports.flat_map { |port| ["--port", port] }, "--", *command)
  end

  def metadata(name)
    JSON.parse(File.read(File.join(@root, "sessions", name, "session.json")))
  end

  def terminal(*args)
    client = SessionTerminal.new(@env, *args)
    @clients << client
    client
  end

  def preview_server
    <<~'RUBY'
      require "socket"
      server = TCPServer.new("0.0.0.0", 3000)
      Thread.new do
        loop do
          client = server.accept
          while (line = client.gets) && line != "\r\n"; end
          body = File.read("index.html")
          client.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
          client.close
        end
      end
      $stdout.sync = true
      puts "PREVIEW-READY"
      STDIN.each_line { |line| puts "received:#{line}" }
    RUBY
  end

  def get_preview(url)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    begin
      Net::HTTP.get(URI(url))
    rescue EOFError, Errno::ECONNREFUSED, Errno::ECONNRESET
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.1
      retry
    end
  end

  def test_failed_bootstrap_removes_container_and_keeps_failure_log
    @sessions << "broken"
    _, _, status = cli("start", "broken", "--detach", "--image", "ubuntu:26.04",
                       "--workspace", @workspace, "--settings", @settings,
                       "--", "true", check: false)
    refute status.success?
    data = metadata("broken")
    assert_equal "failed", data.fetch("status")
    assert_includes cli("logs", "broken").first, "event=session_failed"
    _, _, status = Open3.capture3("docker", "inspect", data.fetch("container"))
    refute status.success?
  end

  def test_preview_port_is_reachable_and_bound_only_to_vm_loopback
    File.write(File.join(@workspace, "index.html"), "shared app preview\n")
    start("preview", "ruby", "-e", preview_server, ports: ["3000"])
    output, status = Open3.capture2("docker", "inspect", metadata("preview").fetch("container"))
    assert status.success?
    bindings = JSON.parse(output).first.fetch("NetworkSettings").fetch("Ports").fetch("3000/tcp")
    assert_equal ["127.0.0.1"], bindings.map { |binding| binding.fetch("HostIp") }
    url = "http://127.0.0.1:#{bindings.first.fetch('HostPort')}"
    assert_includes cli("ports", "preview").first, url
    response = get_preview(url)
    assert_equal "shared app preview\n", response
  end

  def test_shared_terminal_survives_detach_and_preserves_recording
    start("demo", "bash", "--norc", "-c",
          'printf "READY\n"; while IFS= read -r line; do printf "received:%s\n" "$line"; done')
    container = metadata("demo").fetch("container")
    first = terminal("attach", "demo")
    first.expect("READY")
    second = terminal("attach", "demo")
    second.expect("READY")
    first.write("from-first\r")
    first.expect("received:from-first")
    second.expect("received:from-first")
    second.write("from-second\r")
    first.expect("received:from-second")

    @clients.each do |client|
      client.write("\x02d")
      client.expect("detached")
      client.close
    end
    @clients.clear
    assert_includes cli("list").first, "running"
    viewer = terminal("attach", "demo", "--read-only")
    viewer.expect("received:from-second")
    viewer.write("viewer-must-not-write\r")
    capture, status = Open3.capture2("docker", "exec", container, "tmux", "-L", "ai", "capture-pane", "-p")
    assert status.success?
    refute_includes capture, "viewer-must-not-write"

    _, error, status = cli("start", "demo", "--detach", "--", "true", check: false)
    refute status.success?
    assert_includes error, "session already exists"
    cli("stop", "demo")
    assert_includes cli("list").first, "stopped"
    _, _, status = Open3.capture3("docker", "inspect", container)
    refute status.success?
    record = File.join(@root, "sessions/demo/recording")
    assert_includes File.binread(File.join(record, "output")), "received:from-first"
    assert_operator File.size(File.join(record, "timing")), :>, 0
    assert_includes cli("logs", "demo").first, "event=session_stopped"
    cli("replay", "demo", "--max-delay", "0.01")
  end

  def test_remote_invitation_attaches_and_revocation_disconnects
    start("remote", "bash", "--norc", "-c",
          'printf "REMOTE-READY\n"; while IFS= read -r line; do printf "received:%s\n" "$line"; done')
    invitation = cli("invite", "remote", "alice").first.strip
    assert_equal invitation, cli("invite", "remote", "alice").first.strip
    assert_includes cli("invitations", "remote").first, "alice\tactive"
    remote = SessionRemote.new
    data = remote.send(:decode, invitation)
    directory = File.join(@root, "sessions/remote/invitations/alice")
    # Exercise real OpenSSH locally; Tailcat relay connectivity has its own
    # end-to-end check and must not make authentication tests network-dependent.
    known_hosts = File.join(@root, "known_hosts")
    File.write(known_hosts, "ai-session-#{data.fetch('id')} #{data.fetch('host_key')}\n")
    ssh = ["ssh", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
           "-o", "IdentityAgent=none", "-o", "StrictHostKeyChecking=yes",
           "-o", "UserKnownHostsFile=#{known_hosts}", "-o", "HostKeyAlias=ai-session-#{data.fetch('id')}",
           "-p", data.fetch("port").to_s, "-i", File.join(directory, "identity"), "-l", data.fetch("user")]
    client = SessionTerminal.new(@env, command: ssh + ["-tt", "127.0.0.1"])
    @clients << client
    client.expect("REMOTE-READY")
    client.write("from-alice\r")
    client.expect("received:from-alice")
    output, error, status = Open3.capture3(*ssh, "127.0.0.1", "echo VM-SHELL")
    refute status.success?
    assert_includes output + error, "remote commands are not supported"
    _, error, status = Open3.capture3(*ssh, "-W", "127.0.0.1:22", "127.0.0.1")
    refute status.success?
    assert_includes error, "administratively prohibited"
    unknown_key = File.join(@root, "unknown_key")
    assert system("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", unknown_key)
    unauthorized = ssh.dup
    unauthorized[unauthorized.index("-i") + 1] = unknown_key
    _, error, status = Open3.capture3(*unauthorized, "127.0.0.1")
    refute status.success?
    assert_includes error, "Permission denied"
    File.write(known_hosts, "ai-session-#{data.fetch('id')} #{File.read("#{unknown_key}.pub")}\n")
    _, error, status = Open3.capture3(*ssh, "127.0.0.1")
    refute status.success?
    assert_includes error, "Host key verification failed"
    cli("revoke", "remote", "alice")
    client.expect("closed")
    assert_includes cli("invitations", "remote").first, "alice\trevoked"
    assert_includes cli("list").first, "running"
    assert_includes cli("logs", "remote").first, "participant=alice"
    data = JSON.parse(File.read(File.join(directory, "invitation.json")))
    refute system("systemctl", "--user", "is-active", "--quiet", data.fetch("unit"))
    refute File.exist?(File.join(directory, "token"))
    assert_empty File.read(File.join(directory, "authorized_keys"))
  end

  def test_join_over_tailcat
    File.write(File.join(@workspace, "index.html"), "remote app preview\n")
    start("tailcat", "ruby", "-e", preview_server, ports: ["3000"])
    invitation = cli("invite", "tailcat", "bob").first.strip
    invitation_file = File.join(@root, "bob.invite")
    File.write(invitation_file, invitation)
    port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
    client = terminal("join", "@#{invitation_file}", "--port", "#{port}:3000")
    client.expect("PREVIEW-READY")
    assert_equal "remote app preview\n", get_preview("http://127.0.0.1:#{port}")
    client.write("over-tailcat\r")
    client.expect("received:over-tailcat")
    client.write("\x02d")
    client.expect("detached")
    assert_includes cli("logs", "tailcat").first, "participant=bob"
    client.close
    @clients.delete(client)
    reconnected = terminal("join", invitation, "--port", "#{port}:3000")
    reconnected.expect("received:over-tailcat")
    cli("revoke", "tailcat", "bob")
    reconnected.expect("connection ended with status")
    assert_raises(Errno::ECONNREFUSED) { TCPSocket.new("127.0.0.1", port).close }
  end
end
