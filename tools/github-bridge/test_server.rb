require "minitest/autorun"
require "net/http"
require "open3"
require_relative "server"

class GitHubServerTest < Minitest::Test
  def test_ci_downloads_preserve_bytes_and_never_publish_failed_or_overwritten_files
    Dir.mktmpdir do |directory|
      calls, paths = [], []
      bytes = "PK\x03\x04\x00\xffsecret_token".b
      policy = GitHubBridge::Policy.new(
        "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
        "repositories" => ["owner/repo"], "operations" => %w[job-log artifact-download run-logs],
      )
      executor = lambda do |request|
        calls << request
        if request["operation"] == "job-log"
          "Build failed\n"
        else
          GitHubBridge::Download.new do |file|
            paths << file.path
            file.write(bytes)
          end
        end
      end
      broker = GitHubBridge::Broker.new(policy: policy, token: "session-token", executor: executor,
        approver: ->(*) { flunk "unexpected approval" }, logger: ->(*) {})
      certificate, key = OnePasswordBridge.certificate
      server = GitHubBridge::Server.new(broker: broker, certificate: certificate, private_key: key, bind: "127.0.0.1")
      thread = Thread.new { server.run }
      ca = File.join(directory, "ca.pem")
      File.write(ca, certificate.to_pem)
      env = { "GH_BRIDGE_URL" => "https://127.0.0.1:#{server.port}", "GH_BRIDGE_TOKEN" => "session-token", "GH_BRIDGE_CA" => ca }
      client = File.expand_path("../gh-host.sh", __dir__)
      output, error, status = Open3.capture3(env, client, "job-log", "owner/repo", "50000000000")
      assert status.success?, error
      assert_equal "Build failed\n", output
      assert_equal 50_000_000_000, calls.last.fetch("job_id")
      %w[artifact-download run-logs].each do |operation|
        destination = File.join(directory, "#{operation} archive.zip")
        _, error, status = Open3.capture3(env, client, operation, "owner/repo", "37604537230", destination)
        assert status.success?, error
        assert_equal bytes, File.binread(destination)
        key = operation == "run-logs" ? "run_id" : "artifact_id"
        assert_equal({ "operation" => operation, "repository" => "owner/repo", key => 37_604_537_230 }, calls.last)
        count = calls.size
        _, _, status = Open3.capture3(env, client, operation, "owner/repo", "37604537230", destination)
        refute status.success?
        assert_equal count, calls.size
        assert_equal bytes, File.binread(destination)
      end
      rejected = File.join(directory, "rejected.zip")
      _, _, status = Open3.capture3(env, client, "artifact-download", "other/repo", "123", rejected)
      refute status.success?
      refute File.exist?(rejected)
      assert_empty Dir.glob(File.join(directory, ".gh-host-download.*"))
    ensure
      server&.close
      thread&.join
      paths.each { |path| refute File.exist?(path) }
    end
  end

  def test_asset_client_sends_bytes_and_requires_host_approval_without_host_paths
    Dir.mktmpdir do |directory|
      calls, approvals, paths = [], [], []
      allowed = false
      policy = GitHubBridge::Policy.new(
        "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
        "repositories" => ["owner/repo"], "operations" => ["asset-upload"],
      )
      broker = GitHubBridge::Broker.new(policy: policy, token: "session-token",
        executor: ->(request) { calls << request.fetch("asset").file.read; '{"url":"https://github.com/user-attachments/assets/test"}' },
        approver: ->(request) {
          approvals << request.fetch("asset").summary
          paths << request.fetch("asset").file.path
          allowed
        }, logger: ->(*) {})
      certificate, key = OnePasswordBridge.certificate
      server = GitHubBridge::Server.new(broker: broker, certificate: certificate, private_key: key, bind: "127.0.0.1")
      thread = Thread.new { server.run }
      ca = File.join(directory, "ca.pem")
      File.write(ca, certificate.to_pem)
      env = { "GH_BRIDGE_URL" => "https://127.0.0.1:#{server.port}", "GH_BRIDGE_TOKEN" => "session-token", "GH_BRIDGE_CA" => ca }
      client = File.expand_path("../gh-host.sh", __dir__)
      bytes = "\x89PNG\r\n\x00\xff".b * 4096
      file = File.join(directory, "a screenshot #1.png")
      File.binwrite(file, bytes)
      _, _, status = Open3.capture3(env, client, "asset-upload", "owner/repo", file)
      refute status.success?
      assert_empty calls
      assert_equal "a screenshot #1.png", approvals.last.fetch("name")
      assert_equal Digest::SHA256.hexdigest(bytes), approvals.last.fetch("sha256")
      allowed = true
      output, error, status = Open3.capture3(env, client, "asset-upload", "owner/repo", file)
      assert status.success?, error
      assert_equal "https://github.com/user-attachments/assets/test", JSON.parse(output).fetch("url")
      assert_equal [bytes], calls
      _, _, status = Open3.capture3(env, client, "asset-upload", "other/repo", file)
      refute status.success?
      _, _, status = Open3.capture3(env.merge("GH_BRIDGE_TOKEN" => "wrong"), client, "asset-upload", "owner/repo", file)
      refute status.success?
      assert_equal 2, approvals.size
      assert_equal 1, calls.size
      # JSON requests cannot turn a guest-supplied path into a host file read.
      response = broker.call({ "operation" => "asset-upload", "repository" => "owner/repo", "asset" => { "path" => "/etc/passwd" } }, "session-token")
      assert_equal 400, response.status
    ensure
      server&.close
      thread&.join
      paths.each { |path| refute File.exist?(path) }
    end
  end

  def test_review_client_lists_threads_and_requires_approval_for_writes
    Dir.mktmpdir do |directory|
      calls, approvals = [], []
      allowed = false
      policy = GitHubBridge::Policy.new(
        "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
        "repositories" => ["owner/repo"], "operations" => %w[pr-review-threads pr-comment pr-review-reply pr-review-resolve],
      )
      broker = GitHubBridge::Broker.new(policy: policy, token: "session-token",
        executor: ->(request) { calls << request; JSON.generate(request) },
        approver: ->(request) { approvals << request; allowed }, logger: ->(*) {})
      certificate, key = OnePasswordBridge.certificate
      server = GitHubBridge::Server.new(broker: broker, certificate: certificate, private_key: key, bind: "127.0.0.1")
      thread = Thread.new { server.run }
      ca = File.join(directory, "ca.pem")
      File.write(ca, certificate.to_pem)
      env = { "GH_BRIDGE_URL" => "https://127.0.0.1:#{server.port}", "GH_BRIDGE_TOKEN" => "session-token", "GH_BRIDGE_CA" => ca }
      client = File.expand_path("../gh-host.sh", __dir__)
      output, error, status = Open3.capture3(env, client, "pr-review-threads", "owner/repo", "12")
      assert status.success?, error
      assert_equal({ "operation" => "pr-review-threads", "repository" => "owner/repo", "number" => 12 }, JSON.parse(output))
      assert_empty approvals
      body = "Fixed $(command), `code`, and @/etc/passwd\n"
      %w[pr-comment pr-review-reply pr-review-resolve].each do |operation|
        allowed = false
        before = calls.size
        args = [operation, "owner/repo", "12"]
        args << "PRRT_example" unless operation == "pr-comment"
        _, _, status = Open3.capture3(env, client, *args, stdin_data: body)
        refute status.success?
        assert_equal before, calls.size
        allowed = true
        output, error, status = Open3.capture3(env, client, *args, stdin_data: body)
        assert status.success?, error
        expected = { "operation" => operation, "repository" => "owner/repo", "number" => 12, "thread_id" => "PRRT_example" }
        expected.delete("thread_id") if operation == "pr-comment"
        expected["body"] = body unless operation == "pr-review-resolve"
        assert_equal expected, JSON.parse(output)
        assert_equal expected, approvals.last
      end
    ensure
      server&.close
      thread&.join
    end
  end

  def test_issue_client_preserves_title_and_stdin_and_waits_for_approval
    Dir.mktmpdir do |directory|
      calls, approvals = [], []
      allowed = false
      policy = GitHubBridge::Policy.new(
        "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
        "repositories" => ["owner/repo"], "operations" => ["issue-create"],
      )
      broker = GitHubBridge::Broker.new(policy: policy, token: "session-token",
        executor: ->(request) { calls << request; JSON.generate(request.slice("title", "body")) },
        approver: ->(request) { approvals << request; allowed }, logger: ->(*) {})
      certificate, key = OnePasswordBridge.certificate
      server = GitHubBridge::Server.new(broker: broker, certificate: certificate, private_key: key, bind: "127.0.0.1")
      thread = Thread.new { server.run }
      ca = File.join(directory, "ca.pem")
      File.write(ca, certificate.to_pem)
      env = { "GH_BRIDGE_URL" => "https://127.0.0.1:#{server.port}", "GH_BRIDGE_TOKEN" => "session-token", "GH_BRIDGE_CA" => ca }
      client = File.expand_path("../gh-host.sh", __dir__)
      title = "Literal $(command) and `code`"
      body = "## Bug\n\nLiteral $(command), `code`, and @/etc/passwd\n"
      _, _, status = Open3.capture3(env, client, "issue-create", "owner/repo", title, stdin_data: body)
      refute status.success?
      assert_empty calls
      assert_equal body, approvals.last.fetch("body")
      allowed = true
      [body, ""].each do |description|
        output, error, status = Open3.capture3(env, client, "issue-create", "owner/repo", title, stdin_data: description)
        assert status.success?, error
        assert_equal({ "title" => title, "body" => description }, JSON.parse(output))
        assert_equal({ "operation" => "issue-create", "repository" => "owner/repo", "title" => title, "body" => description }, calls.last)
      end
      _, _, status = Open3.capture3(env, client, "issue-create", "owner/repo", title, "extra", stdin_data: body)
      refute status.success?
      assert_equal 2, calls.size
      assert_equal 3, approvals.size
    ensure
      server&.close
      thread&.join
    end
  end

  def test_certificate_supports_a_45_day_session
    started_at = Time.now
    certificate, = OnePasswordBridge.certificate
    store = OpenSSL::X509::Store.new
    store.add_cert(certificate)
    store.purpose = OpenSSL::X509::PURPOSE_SSL_SERVER
    store.time = started_at + 45 * 24 * 60 * 60 - 1

    assert store.verify(certificate), store.error_string
  end

  def test_description_client_preserves_stdin_and_waits_for_approval
    Dir.mktmpdir do |directory|
      calls, approvals = [], []
      allowed = false
      policy = GitHubBridge::Policy.new(
        "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
        "repositories" => ["owner/repo"], "operations" => ["pr-edit-body"],
      )
      broker = GitHubBridge::Broker.new(policy: policy, token: "session-token",
        executor: ->(request) { calls << request; JSON.generate(request.slice("body")) },
        approver: ->(request) { approvals << request; allowed }, logger: ->(*) {})
      certificate, key = OnePasswordBridge.certificate
      server = GitHubBridge::Server.new(broker: broker, certificate: certificate, private_key: key, bind: "127.0.0.1")
      thread = Thread.new { server.run }
      ca = File.join(directory, "ca.pem")
      File.write(ca, certificate.to_pem)
      env = { "GH_BRIDGE_URL" => "https://127.0.0.1:#{server.port}", "GH_BRIDGE_TOKEN" => "session-token", "GH_BRIDGE_CA" => ca }
      client = File.expand_path("../gh-host.sh", __dir__)
      body = "## Description\n\nLiteral $(command), `code`, and @/etc/passwd\n"
      _, _, status = Open3.capture3(env, client, "pr-edit-body", "owner/repo", "12", stdin_data: body)
      refute status.success?
      assert_empty calls
      assert_equal body, approvals.last.fetch("body")
      allowed = true
      [body, ""].each do |description|
        output, error, status = Open3.capture3(env, client, "pr-edit-body", "owner/repo", "12", stdin_data: description)
        assert status.success?, error
        assert_equal({ "body" => description }, JSON.parse(output))
        assert_equal({ "operation" => "pr-edit-body", "repository" => "owner/repo", "number" => 12, "body" => description }, calls.last)
      end
      _, _, status = Open3.capture3(env, client, "pr-edit-body", "owner/repo", "invalid", stdin_data: body)
      refute status.success?
      assert_equal 2, calls.size
      assert_equal 3, approvals.size
    ensure
      server&.close
      thread&.join
    end
  end

  def test_client_tls_authentication_and_invalid_requests
    Dir.mktmpdir do |directory|
      calls = []
      executor = Object.new
      executor.define_singleton_method(:call) { |request| calls << request; "result\n" }
      policy = GitHubBridge::Policy.new(
        "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
        "repositories" => ["owner/repo"], "operations" => ["pr-view"],
      )
      broker = GitHubBridge::Broker.new(policy: policy, token: "session-token", executor: executor,
                                       approver: ->(*) { flunk "unexpected approval" }, logger: ->(*) {})
      certificate, key = OnePasswordBridge.certificate
      server = GitHubBridge::Server.new(broker: broker, certificate: certificate, private_key: key, bind: "127.0.0.1", timeout: 0.2)
      thread = Thread.new { server.run }
      ca = File.join(directory, "ca.pem")
      File.write(ca, certificate.to_pem)
      env = { "GH_BRIDGE_URL" => "https://127.0.0.1:#{server.port}", "GH_BRIDGE_TOKEN" => "session-token", "GH_BRIDGE_CA" => ca }
      client = File.expand_path("../gh-host.sh", __dir__)
      output, error, status = Open3.capture3(env, client, "pr-view", "owner/repo", "12")
      assert status.success?, error
      assert_equal "result\n", output
      assert_equal [{ "operation" => "pr-view", "repository" => "owner/repo", "number" => 12 }], calls
      _, _, status = Open3.capture3(env.merge("GH_BRIDGE_TOKEN" => "wrong-token"), client, "pr-view", "owner/repo", "12")
      refute status.success?
      assert_equal 1, calls.size

      http = Net::HTTP.new("127.0.0.1", server.port, nil)
      http.use_ssl = true
      http.ca_file = ca
      request = Net::HTTP::Post.new("/v1/github")
      request["Authorization"] = "Bearer session-token"
      request["Content-Type"] = "application/json"
      request.body = "x" * (GitHubBridge::Server::MAX_BODY + 1)
      rejected = begin
        http.request(request).code
      rescue Errno::ECONNRESET
        "closed"
      end
      assert_includes ["400", "closed"], rejected
      request.body = "{"
      assert_equal "400", http.request(request).code
      # A client that never starts TLS cannot hold the server indefinitely.
      socket = TCPSocket.new("127.0.0.1", server.port)
      request.body = JSON.generate("operation" => "pr-view", "repository" => "owner/repo", "number" => 12)
      assert_equal "200", http.request(request).code
      assert_equal 2, calls.size
    ensure
      socket&.close
      server&.close
      thread&.join
    end
  end
end
