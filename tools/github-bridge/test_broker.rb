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

  def test_description_edits_validate_the_exact_request_before_host_approval
    policy = GitHubBridge::Policy.new(
      "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
      "repositories" => ["owner/repo"], "operations" => ["pr-edit-body"],
    )
    calls, approvals = [], []
    allowed = false
    broker = GitHubBridge::Broker.new(policy: policy, token: "session",
      executor: ->(request) { calls << request; "ok" },
      approver: ->(request) { approvals << request; allowed }, logger: ->(*) {})
    request = { "operation" => "pr-edit-body", "repository" => "owner/repo", "number" => 12, "body" => "New description\n" }
    assert_equal 401, broker.call(request, "wrong").status
    assert_equal 403, broker.call(request.merge("repository" => "other/repo"), "session").status
    [nil, 0, -1, 2**31, "12"].each do |number|
      assert_equal 400, broker.call(request.merge("number" => number), "session").status
    end
    [nil, 42, "x" * 8193, "bad\u0000"].each do |body|
      assert_equal 400, broker.call(request.merge("body" => body), "session").status
    end
    %w[title state base maintainer_can_modify].each do |key|
      assert_equal 400, broker.call(request.merge(key => "changed"), "session").status
    end
    assert_empty approvals
    assert_equal 403, broker.call(request, "session").status
    assert_equal [request], approvals
    assert_empty calls
    allowed = true
    [request, request.merge("body" => ""), request.merge("body" => "x" * 8192)].each do |edit|
      assert_equal 200, broker.call(edit, "session").status
      assert_equal edit, calls.last
      assert_equal edit, approvals.last
    end
  end

  def test_new_reads_require_policy_permission_and_strict_arguments_without_approval
    operations = %w[pr-comments pr-reviews pr-review-comments issue-list issue-view issue-comments issue-timeline]
    policy = GitHubBridge::Policy.new(
      "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
      "repositories" => ["owner/repo"], "operations" => operations,
    )
    calls = []
    broker = GitHubBridge::Broker.new(policy: policy, token: "session",
      executor: ->(request) { calls << request; "[]" },
      approver: ->(*) { flunk "reads must not request approval" }, logger: ->(*) {})
    operations.each do |operation|
      request = { "operation" => operation, "repository" => "owner/repo" }
      request["number"] = 12 unless operation == "issue-list"
      assert_equal 401, broker.call(request, "wrong").status
      assert_equal 403, broker.call(request.merge("repository" => "other/repo"), "session").status
      assert_equal 400, broker.call(request.merge("url" => "https://example.com"), "session").status
      if operation == "issue-list"
        assert_equal 400, broker.call(request.merge("number" => 12), "session").status
      else
        [nil, 0, -1, 2**31, "12"].each do |number|
          assert_equal 400, broker.call(request.merge("number" => number), "session").status
        end
      end
      assert_equal 200, broker.call(request, "session").status
    end
    assert_equal operations.size, calls.size
    restricted = GitHubBridge::Policy.new(
      "account" => policy.account, "token" => policy.token,
      "repositories" => policy.repositories, "operations" => ["pr-view"],
    )
    broker = GitHubBridge::Broker.new(policy: restricted, token: "session",
      executor: ->(*) { flunk "unauthorized read" }, approver: ->(*) { flunk "unexpected approval" }, logger: ->(*) {})
    operations.each do |operation|
      assert_equal 403, broker.call({ "operation" => operation, "repository" => "owner/repo", "number" => 12 }, "session").status
    end
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
    assert_equal 403, broker.call(request.merge("repository" => "company/repo", "operation" => "pr-edit-body", "body" => "edit"), "session").status
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
