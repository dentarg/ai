require "minitest/autorun"
require "tmpdir"
require_relative "executor"

class GitHubExecutorTest < Minitest::Test
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
