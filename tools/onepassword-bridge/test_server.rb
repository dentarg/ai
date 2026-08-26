#!/usr/bin/env ruby

require "fileutils"
require "minitest/autorun"
require "net/http"
require "tmpdir"

require_relative "server"

class OnePasswordBridgeTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @policy_path = File.join(@tmpdir, "policy.json")
    File.write(
      @policy_path,
      JSON.generate(
        "projects" => {
          "/work/example" => {
            "account" => "example.1password.com",
            "secrets" => {
              "github-token" => "op://Agent/GitHub/token",
            },
          },
        },
      ),
    )
    File.chmod(0o600, @policy_path)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_only_resolves_an_authenticated_allowlisted_alias_after_approval
    policy = OnePasswordBridge::Policy.load(@policy_path, "/work/example")
    reads = []
    reader = Object.new
    reader.define_singleton_method(:read) do |account, reference|
      reads << [account, reference]
      "resolved-secret"
    end
    approver = Object.new
    approver.define_singleton_method(:approve?) { |_alias_name| true }
    logs = []
    broker = OnePasswordBridge::Broker.new(
      policy: policy,
      token: "session-token",
      approver: approver,
      reader: reader,
      logger: ->(*fields) { logs << fields },
    )

    unauthorized = broker.resolve("github-token", "wrong-token")
    unknown = broker.resolve("other-token", "session-token")
    allowed = broker.resolve("github-token", "session-token")

    assert_equal 401, unauthorized.status
    assert_equal 404, unknown.status
    assert_equal 200, allowed.status
    assert_equal "resolved-secret", allowed.body
    assert_equal [
      ["example.1password.com", "op://Agent/GitHub/token"],
    ], reads
    assert_equal "secret_read", logs.last[1]
  end

  def test_rejects_a_policy_writable_by_other_users
    File.chmod(0o622, @policy_path)

    error = assert_raises(RuntimeError) do
      OnePasswordBridge::Policy.load(@policy_path, "/work/example")
    end

    assert_equal "policy must not be group- or world-writable", error.message
  end

  def test_tls_endpoint_passes_only_the_alias_and_bearer_token_to_the_broker
    calls = []
    broker = Object.new
    broker.define_singleton_method(:resolve) do |alias_name, token|
      calls << [alias_name, token]
      OnePasswordBridge::Response.new(200, "resolved-secret")
    end
    certificate, private_key = OnePasswordBridge.certificate
    server = OnePasswordBridge::Server.new(
      broker: broker,
      certificate: certificate,
      private_key: private_key,
      bind: "127.0.0.1",
    )
    server_thread = Thread.new { server.run }
    ca_path = File.join(@tmpdir, "ca.pem")
    File.write(ca_path, certificate.to_pem)

    http = Net::HTTP.new("127.0.0.1", server.port)
    http.use_ssl = true
    http.ca_file = ca_path
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    request = Net::HTTP::Post.new("/v1/secrets/github-token")
    request["Authorization"] = "Bearer session-token"
    response = http.request(request)

    assert_equal "200", response.code
    assert_equal "resolved-secret", response.body
    assert_equal [["github-token", "session-token"]], calls
  ensure
    server&.close
    server_thread&.join
  end
end
