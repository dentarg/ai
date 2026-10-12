require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "executor"

class GitHubExecutorTest < Minitest::Test
  def test_asset_upload_uses_repository_id_and_streams_only_received_bytes
    bytes = "\x89PNG\x00\xff".b
    asset = GitHubBridge::Asset.new(StringIO.new(bytes), name: "screen #1.png", content_type: "image/png", size: bytes.bytesize)
    calls = []
    writable = true
    runner = Object.new
    runner.define_singleton_method(:call) do |argv, **options|
      input = options[:input]
      input = input.read if input.respond_to?(:read)
      calls << [argv, options.merge(input: input)]
      if argv.first == "/host/op"
        "secret_token\n"
      elsif argv.last == "repos/owner/repo"
        JSON.generate("id" => 123, "permissions" => { "push" => writable })
      else
        '{"url":"https://github.com/user-attachments/assets/test-id"}'
      end
    end
    policy = GitHubBridge::Policy.new(
      "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
      "repositories" => ["owner/repo"], "operations" => ["asset-upload"],
    )
    request = { "operation" => "asset-upload", "repository" => "owner/repo", "asset" => asset }
    approver = GitHubBridge::Approver.new("project", directory: Dir.tmpdir, runner: runner)
    assert approver.call(request)
    message = calls.last.first.last
    assert_includes message, "Upload this asset to GitHub?"
    assert_includes message, asset.sha256
    assert_includes message, asset.name
    refute_includes message, asset.file.path
    executor = GitHubBridge::Executor.new(policy: policy, gh: "/host/gh", op: "/host/op", directory: Dir.tmpdir, runner: runner)
    result = JSON.parse(executor.call(request))
    assert_equal "![screen #1.png](https://github.com/user-attachments/assets/test-id)", result.fetch("markdown")
    argv, options = calls.last
    assert_equal ["/host/gh", "api", "--hostname", "github.com", "--method", "POST",
                  "-H", "Content-Type: application/octet-stream", "-H", "Accept: application/vnd.github+json",
                  "-H", "Content-Length: #{bytes.bytesize}",
                  "https://uploads.github.com/user-attachments/assets?name=screen+%231.png&content_type=image%2Fpng&repository_id=123",
                  "--input", "-"], argv
    assert_equal bytes, options[:input]
    writable = false
    calls.clear
    assert_raises(RuntimeError) { executor.call(request) }
    assert_equal 2, calls.size
  ensure
    asset&.close
  end

  def test_discussion_comments_require_a_real_pr_and_send_only_body
    calls = []
    exists = true
    runner = Object.new
    runner.define_singleton_method(:call) do |argv, **options|
      calls << [argv, options]
      raise "not a PR" if argv.last == "repos/owner/repo/pulls/12" && !exists
      argv.first == "/host/op" ? "secret_token\n" : "{}\n"
    end
    policy = GitHubBridge::Policy.new(
      "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
      "repositories" => ["owner/repo"], "operations" => ["pr-comment"],
    )
    request = { "operation" => "pr-comment", "repository" => "owner/repo", "number" => 12, "body" => "Reply\n" }
    executor = GitHubBridge::Executor.new(policy: policy, gh: "/host/gh", op: "/host/op", directory: Dir.tmpdir, runner: runner)
    assert_equal "{}\n", executor.call(request)
    assert_equal ["/host/gh", "api", "--hostname", "github.com", "--method", "GET", "repos/owner/repo/pulls/12"], calls[-2][0]
    assert_equal ["/host/gh", "api", "--hostname", "github.com", "--method", "POST",
                  "-H", "Accept: application/vnd.github+json", "repos/owner/repo/issues/12/comments", "--input", "-"], calls.last[0]
    assert_equal({ "body" => "Reply\n" }, JSON.parse(calls.last[1][:input]))
    exists = false
    calls.clear
    assert_raises(RuntimeError) { executor.call(request) }
    assert_equal 2, calls.size
  end

  def test_issue_creation_sends_only_title_and_body_and_names_the_issue_in_approval
    calls = []
    runner = Object.new
    runner.define_singleton_method(:call) do |argv, **options|
      calls << [argv, options]
      argv.first == "/host/op" ? "secret_token\n" : "{\"html_url\":\"https://github.com/owner/repo/issues/12\"}\n"
    end
    policy = GitHubBridge::Policy.new(
      "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
      "repositories" => ["owner/repo"], "operations" => ["issue-create"],
    )
    request = { "operation" => "issue-create", "repository" => "owner/repo",
                "title" => "Literal $(command)", "body" => "## Bug\n\n`code` and @/etc/passwd\n" }
    approver = GitHubBridge::Approver.new("project", directory: Dir.tmpdir, runner: runner)
    assert approver.call(request)
    assert_includes calls.last.first.last, "Create this issue?"
    assert_includes calls.last.first.last, JSON.pretty_generate(request)
    executor = GitHubBridge::Executor.new(policy: policy, gh: "/host/gh", op: "/host/op", directory: Dir.tmpdir, runner: runner)
    assert_equal "https://github.com/owner/repo/issues/12", JSON.parse(executor.call(request)).fetch("html_url")
    argv, options = calls.last
    assert_equal ["/host/gh", "api", "--hostname", "github.com", "--method", "POST",
                  "-H", "Accept: application/vnd.github+json", "repos/owner/repo/issues", "--input", "-"], argv
    assert_equal request.slice("title", "body"), JSON.parse(options[:input])
  end

  def test_runner_bounds_output_and_time_and_does_not_inherit_environment
    runner = GitHubBridge::Runner.new
    options = { env: {}, directory: Dir.tmpdir }
    assert_equal "missing", runner.call([RbConfig.ruby, "-e", 'print ENV.fetch("PATH", "missing")'], **options)
    assert_raises(RuntimeError) do
      runner.call([RbConfig.ruby, "-e", 'STDOUT.write("x" * 10000)'], **options, limit: 100)
    end
    assert_raises(Timeout::Error) do
      runner.call([RbConfig.ruby, "-e", "sleep 60"], **options, timeout: 0.1)
    end
  end

  def test_read_operations_use_fixed_endpoints_and_paginate_collections
    calls = []
    runner = Object.new
    runner.define_singleton_method(:call) do |argv, **options|
      calls << [argv, options]
      argv.first == "/host/op" ? "secret_token\n" : "[]\n"
    end
    policy = GitHubBridge::Policy.new(
      "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
      "repositories" => ["owner/repo"], "operations" => GitHubBridge::READ_OPERATIONS,
    )
    executor = GitHubBridge::Executor.new(policy: policy, gh: "/host/gh", op: "/host/op", directory: Dir.tmpdir, runner: runner)
    endpoints = {
      "pr-comments" => "issues/12/comments?per_page=100",
      "pr-reviews" => "pulls/12/reviews?per_page=100",
      "pr-review-comments" => "pulls/12/comments?per_page=100",
      "issue-list" => "issues?state=all&per_page=100",
      "issue-view" => "issues/12",
      "issue-comments" => "issues/12/comments?per_page=100",
      "issue-timeline" => "issues/12/timeline?per_page=100",
    }
    endpoints.each do |operation, endpoint|
      assert_equal "[]\n", executor.call("operation" => operation, "repository" => "owner/repo", "number" => 12)
      argv, options = calls.last
      expected = ["/host/gh", "api", "--hostname", "github.com", "--method", "GET",
                  "-H", "Accept: application/vnd.github+json", "repos/owner/repo/#{endpoint}"]
      unless operation == "issue-view"
        expected += ["--paginate", "--slurp"]
      end
      assert_equal expected, argv
      assert_equal "", options[:input]
    end
  end

  def test_paginated_reads_combine_pages_and_exclude_pull_requests_from_issues
    pages = [[{ "id" => 1, "body" => "first secret_token" }],
             [{ "id" => 2, "body" => "second" }, { "id" => 3, "pull_request" => {} }]]
    runner = Object.new
    runner.define_singleton_method(:call) do |argv, **|
      argv.first == "/host/op" ? "secret_token\n" : JSON.generate(pages)
    end
    policy = GitHubBridge::Policy.new(
      "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
      "repositories" => ["owner/repo"], "operations" => GitHubBridge::READ_OPERATIONS,
    )
    executor = GitHubBridge::Executor.new(policy: policy, gh: "/host/gh", op: "/host/op", directory: Dir.tmpdir, runner: runner)
    comments = JSON.parse(executor.call("operation" => "pr-comments", "repository" => "owner/repo", "number" => 12))
    assert_equal [1, 2, 3], comments.map { |comment| comment.fetch("id") }
    assert_equal "first [REDACTED]", comments.first.fetch("body")
    issues = JSON.parse(executor.call("operation" => "issue-list", "repository" => "owner/repo"))
    assert_equal comments.first(2), issues
    pages.clear
    assert_equal [], JSON.parse(executor.call("operation" => "issue-list", "repository" => "owner/repo"))
  end

  def test_description_edit_sends_only_body_as_json_and_names_the_edit_in_approval
    calls = []
    runner = Object.new
    runner.define_singleton_method(:call) do |argv, **options|
      calls << [argv, options]
      argv.first == "/host/op" ? "secret_token\n" : "{}\n"
    end
    policy = GitHubBridge::Policy.new(
      "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
      "repositories" => ["owner/repo"], "operations" => ["pr-edit-body"],
    )
    request = { "operation" => "pr-edit-body", "repository" => "owner/repo", "number" => 12,
                "body" => "## Description\n\nLiteral $(command), `code`, and @/etc/passwd\n" }
    approver = GitHubBridge::Approver.new("project", directory: Dir.tmpdir, runner: runner)
    assert approver.call(request)
    message = calls.last.first.last
    assert_includes message, "Replace this PR description?"
    assert_includes message, JSON.pretty_generate(request)
    refute_includes message, "Create this draft PR?"
    executor = GitHubBridge::Executor.new(policy: policy, gh: "/host/gh", op: "/host/op", directory: Dir.tmpdir, runner: runner)
    assert_equal "{}\n", executor.call(request)
    argv, options = calls.last
    assert_equal ["/host/gh", "api", "--hostname", "github.com", "--method", "PATCH",
                  "-H", "Accept: application/vnd.github+json", "repos/owner/repo/pulls/12", "--input", "-"], argv
    assert_equal({ "body" => request.fetch("body") }, JSON.parse(options[:input]))
  end

  def test_gh_receives_only_fixed_arguments_and_an_isolated_environment
    Dir.mktmpdir do |dir|
      calls = []
      runner = Object.new
      runner.define_singleton_method(:call) do |argv, **options|
        calls << [argv, options]
        argv.first == "/host/op" ? "secret_token\n" : "result secret_token\n"
      end
      policy = GitHubBridge::Policy.new(
        "account" => "my.1password.com", "token" => "op://Agent/GitHub/token",
        "repositories" => ["owner/repo"], "operations" => ["pr-create"],
      )
      executor = GitHubBridge::Executor.new(policy: policy, gh: "/host/gh", op: "/host/op", directory: dir, runner: runner)
      request = { "operation" => "pr-create", "repository" => "owner/repo",
                  "head" => "feature", "base" => "main", "title" => "$(touch /tmp/unsafe)", "body" => "@/etc/passwd" }
      assert_equal "result [REDACTED]\n", executor.call(request)
      assert_equal ["/host/op", "read", "--account", policy.account, policy.token], calls[0][0]
      argv, options = calls[1]
      assert_equal ["/host/gh", "api", "--hostname", "github.com", "--method", "POST",
                    "-H", "Accept: application/vnd.github+json", "repos/owner/repo/pulls", "--input", "-"], argv
      assert_equal request.slice("head", "base", "title", "body").merge("draft" => true, "maintainer_can_modify" => false), JSON.parse(options[:input])
      assert_equal "secret_token", options[:env]["GH_TOKEN"]
      assert_equal dir, options[:env]["GH_CONFIG_DIR"]
      refute options[:env].key?("HTTPS_PROXY")
      assert_equal dir, options[:directory]
    end
  end
end
