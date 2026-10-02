require "minitest/autorun"
require_relative "broker"

class GitHubBrokerTest < Minitest::Test
  def test_only_authorized_validated_requests_reach_the_executor
    policy = GitHubBridge::Policy.new(
      "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
      "repositories" => ["owner/repo"], "operations" => %w[pr-view pr-diff pr-create],
    )
    calls = []
    executor = Object.new
    executor.define_singleton_method(:call) { |request| calls << request; "result\n" }
    approvals = []
    allowed = false
    approver = ->(request) { approvals << request; allowed }
    broker = GitHubBridge::Broker.new(policy: policy, token: "session-token",
                                     executor: executor, approver: approver, logger: ->(*) {})
    request = { "operation" => "pr-view", "repository" => "owner/repo", "number" => 12 }
    assert_equal 401, broker.call(request, "wrong-token").status
    assert_equal 403, broker.call(request.merge("repository" => "other/repo"), "session-token").status
    assert_equal 400, broker.call(request.merge("number" => "../../secrets"), "session-token").status
    assert_equal 400, broker.call(request.merge("args" => ["--hostname", "evil.test"]), "session-token").status
    assert_equal 403, broker.call(request.merge("operation" => "pr-merge"), "session-token").status
    assert_empty calls
    assert_empty approvals
    assert_equal 200, broker.call(request, "session-token").status
    assert_equal [request], calls

    create = { "operation" => "pr-create", "repository" => "owner/repo",
               "head" => "feature", "base" => "main", "title" => "Change", "body" => "Details" }
    assert_equal 403, broker.call(create, "session-token").status
    assert_equal [request], calls
    assert_equal [create], approvals
    allowed = true
    assert_equal 200, broker.call(create, "session-token").status
    assert_equal [request, create], calls
  end

  def test_owner_scopes_only_allow_concrete_repositories_within_that_owner
    policy = GitHubBridge::Policy.new(
      "account" => "my.1password.com", "token" => "op://Work/GitHub/token",
      "repositories" => ["company/*", "second/*", "personal/one"], "operations" => ["pr-view"],
    )
    calls = []
    broker = GitHubBridge::Broker.new(policy: policy, token: "session", executor: ->(request) { calls << request; "ok" },
                                     approver: ->(*) { flunk "unexpected approval" }, logger: ->(*) {})
    request = { "operation" => "pr-view", "number" => 1 }
    %w[company/new COMPANY/Repo second/new personal/ONE].each do |repository|
      assert_equal 200, broker.call(request.merge("repository" => repository), "session").status
    end
    %w[company-other/repo other/company personal/two company/* company/../other company/repo?x company/repo/extra].each do |repository|
      assert_equal 403, broker.call(request.merge("repository" => repository), "session").status
    end
    assert_equal 403, broker.call(request.merge("repository" => "company/repo", "operation" => "pr-create"), "session").status
    assert_equal 400, broker.call(request.merge("repository" => "company/repo", "profile" => "other"), "session").status
    assert_equal 4, calls.size
  end

  def test_command_failures_do_not_disclose_subprocess_details
    policy = GitHubBridge::Policy.new(
      "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
      "repositories" => ["owner/repo"], "operations" => ["pr-view"],
    )
    executor = Object.new
    executor.define_singleton_method(:call) { |_| raise "sensitive command output" }
    logs = []
    broker = GitHubBridge::Broker.new(policy: policy, token: "session-token", executor: executor,
                                     approver: ->(*) { false }, logger: ->(*fields) { logs << fields })
    response = broker.call({ "operation" => "pr-view", "repository" => "owner/repo", "number" => 1 }, "session-token")
    assert_equal 502, response.status
    refute_includes response.body, "sensitive"
    refute_includes logs.inspect, "sensitive"
  end
end
