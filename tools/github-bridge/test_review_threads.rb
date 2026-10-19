require "minitest/autorun"
require "tmpdir"
require_relative "executor"

class GitHubReviewThreadsTest < Minitest::Test
  def setup
    @calls = []
    @responses = []
    calls, responses = @calls, @responses
    runner = Object.new
    runner.define_singleton_method(:call) do |argv, **options|
      calls << [argv, options]
      raise "unexpected request" if responses.empty?

      JSON.generate(responses.shift)
    end
    @threads = GitHubBridge::ReviewThreads.new(gh: "/host/gh", runner: runner, env: {}, directory: Dir.tmpdir)
    @request = { "operation" => "pr-review-reply", "repository" => "owner/repo", "number" => 12,
                 "thread_id" => "PRRT_example", "body" => "Fixed $(command) and `code`\n" }
  end

  def lookup(repository: "owner/repo", number: 12)
    { "data" => { "node" => { "id" => "PRRT_example",
      "pullRequest" => { "number" => number, "repository" => { "nameWithOwner" => repository } } } } }
  end

  def test_resolution_errors_identify_the_failing_graphql_step
    @responses.concat([lookup, { "errors" => [{ "type" => "FORBIDDEN", "message" => "Resource not accessible by integration" }] }])
    error = assert_raises(GitHubBridge::RequestError) { @threads.call(@request.merge("operation" => "pr-review-resolve")) }
    assert_equal "review_thread_resolve", error.details.fetch(:stage)
    assert_equal "FORBIDDEN", error.details.fetch(:github_error_type)
    assert_equal "Resource not accessible by integration", error.details.fetch(:error_message)

    @responses << { "errors" => [{ "type" => "NOT_FOUND", "message" => "Could not resolve to a node" }] }
    error = assert_raises(GitHubBridge::RequestError) { @threads.call(@request.merge("operation" => "pr-review-resolve")) }
    assert_equal "review_thread_lookup", error.details.fetch(:stage)
    assert_equal "NOT_FOUND", error.details.fetch(:github_error_type)
  end

  def test_thread_writes_check_repository_and_pr_before_mutating
    %w[pr-review-reply pr-review-resolve].each do |operation|
      [lookup(repository: "other/repo"), lookup(number: 13), { "data" => { "node" => nil } },
       { "data" => { "node" => {} } }, { "errors" => [{ "message" => "denied" }], "data" => { "node" => nil } }].each do |response|
        @responses << response
        @calls.clear
        assert_raises(RuntimeError) { @threads.call(@request.merge("operation" => operation)) }
        assert_equal 1, @calls.size
        assert_equal GitHubBridge::ReviewThreads::LOOKUP, JSON.parse(@calls.last[1][:input]).fetch("query")
      end
    end
  end

  def test_reply_and_resolution_use_fixed_mutations_and_preserve_body
    comment = { "id" => "PRRC_reply", "url" => "https://github.com/owner/repo/pull/12#discussion_r1", "body" => @request["body"] }
    @responses.concat([lookup(repository: "OWNER/REPO"), { "data" => { "addPullRequestReviewThreadReply" => { "comment" => comment } } }])
    assert_equal comment, @threads.call(@request)
    argv, options = @calls.last
    assert_equal ["/host/gh", "api", "--hostname", "github.com", "graphql", "--input", "-"], argv
    assert_equal({ "query" => GitHubBridge::ReviewThreads::REPLY,
                   "variables" => { "id" => "PRRT_example", "body" => @request["body"] } }, JSON.parse(options[:input]))
    thread = { "id" => "PRRT_example", "isResolved" => true }
    @responses.concat([lookup, { "data" => { "resolveReviewThread" => { "thread" => thread } } }])
    assert_equal thread, @threads.call(@request.merge("operation" => "pr-review-resolve"))
    assert_equal({ "query" => GitHubBridge::ReviewThreads::RESOLVE,
                   "variables" => { "id" => "PRRT_example" } }, JSON.parse(@calls.last[1][:input]))
    @responses.concat([lookup, { "errors" => [{ "message" => "denied" }], "data" => { "resolveReviewThread" => nil } }])
    assert_raises(RuntimeError) { @threads.call(@request.merge("operation" => "pr-review-resolve")) }
  end

  def test_thread_listing_paginates_and_rejects_partial_or_oversized_results
    page = ->(nodes, more, cursor) {
      { "data" => { "repository" => { "pullRequest" => { "reviewThreads" => {
        "nodes" => nodes, "pageInfo" => { "hasNextPage" => more, "endCursor" => cursor },
      } } } } }
    }
    request = @request.slice("repository", "number").merge("operation" => "pr-review-threads")
    @responses.concat([page.call([{ "id" => "first" }], true, "next"), page.call([{ "id" => "second" }], false, nil)])
    assert_equal [{ "id" => "first" }, { "id" => "second" }], @threads.call(request)
    assert_equal({ "owner" => "owner", "name" => "repo", "number" => 12, "cursor" => "next" },
                 JSON.parse(@calls.last[1][:input]).fetch("variables"))
    @responses.concat([page.call([], true, "next"), { "errors" => [{ "message" => "failure" }] }])
    assert_raises(RuntimeError) { @threads.call(request) }
    @responses.concat([page.call([], true, "same"), page.call([], true, "same")])
    assert_raises(RuntimeError) { @threads.call(request) }
    @responses << page.call([{ "body" => "x" * (2 * 1024 * 1024) }], false, nil)
    assert_raises(RuntimeError) { @threads.call(request) }
  end
end
