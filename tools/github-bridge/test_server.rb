require "minitest/autorun"
require "net/http"
require "open3"
require_relative "server"

class GitHubServerTest < Minitest::Test
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
