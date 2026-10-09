require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "config"

class GitHubConfigTest < Minitest::Test
  def test_one_policy_is_shared_by_unrelated_working_directories
    Dir.mktmpdir do |directory|
      first = File.join(directory, "first")
      second = File.join(directory, "second")
      Dir.mkdir(first)
      Dir.mkdir(second)
      env = { "XDG_CONFIG_HOME" => File.join(directory, "config") }
      cli = File.expand_path("../../bin/github-bridge", __dir__)
      _, error, status = Open3.capture3(env, cli, "init", "work", "my.1password.com",
                                      "op://Agent/GitHub/token", "owner/one", "owner/two", chdir: first)
      assert status.success?, error
      output, error, status = Open3.capture3(env, cli, "show", "work", chdir: second)
      assert status.success?, error
      assert_equal %w[owner/one owner/two], JSON.parse(output).fetch("repositories")
      assert Open3.capture3(env, cli, "allow", "work", "pr-view", "pr-create", chdir: second).last.success?
      output, _, status = Open3.capture3(env, cli, "show", "work", chdir: first)
      assert status.success?
      assert_equal %w[pr-view pr-create], JSON.parse(output).fetch("operations")
    end
  end

  def test_configuration_is_host_only_and_rejects_unsafe_updates
    Dir.mktmpdir do |directory|
      env = { "XDG_CONFIG_HOME" => File.join(directory, "config"), "AI_DIR" => File.join(directory, "data") }
      cli = File.expand_path("../../bin/github-bridge", __dir__)
      run = ->(*args) { Open3.capture3(env, cli, *args) }
      assert run.call("init", "work", "my.1password.com", "op://Agent/GitHub/token", "owner/repo").last.success?
      path = File.join(env.fetch("XDG_CONFIG_HOME"), "ai", "github-bridge.json")
      assert_equal 0o600, File.stat(path).mode & 0o777
      policy = GitHubBridge::Policy.load(path, "work")
      assert_equal GitHubBridge::READ_OPERATIONS, policy.operations
      before = File.read(path)
      refute run.call("allow", "work", "api").last.success?
      assert_equal before, File.read(path)
      assert run.call("allow", "work", "pr-view", "pr-create").last.success?
      assert_equal %w[pr-view pr-create], GitHubBridge::Policy.load(path, "work").operations
      assert run.call("check", "work").last.success?
      File.chmod(0o666, path)
      refute run.call("check", "work").last.success?
      assert_raises(RuntimeError) { GitHubBridge::Policy.load(path, "work") }
      refute File.exist?(env.fetch("AI_DIR"))
    end
  end

  def test_profiles_keep_credentials_scopes_and_operations_separate
    Dir.mktmpdir do |directory|
      path = File.join(directory, "policy.json")
      cli = File.expand_path("../../bin/github-bridge", __dir__)
      run = ->(*args) { Open3.capture3(cli, "--file", path, *args) }
      assert run.call("init", "work", "my.1password.com", "op://Work/GitHub/token", "company/*", "second/*").last.success?
      assert run.call("init", "personal", "my.1password.com", "op://Personal/GitHub/token", "me/repo").last.success?
      assert run.call("allow", "work", "pr-create").last.success?
      work = GitHubBridge::Policy.load(path, "work")
      personal = GitHubBridge::Policy.load(path, "personal")
      assert_equal "op://Work/GitHub/token", work.token
      assert_equal ["pr-create"], work.operations
      assert_equal "op://Personal/GitHub/token", personal.token
      assert_equal GitHubBridge::READ_OPERATIONS, personal.operations
      assert work.allows_repository?("company/new-repo")
      assert work.allows_repository?("SECOND/repo")
      refute work.allows_repository?("me/repo")
      refute personal.allows_repository?("company/repo")
      before = File.read(path)
      refute run.call("allow", "missing", "pr-create").last.success?
      refute run.call("init", "work", "my.1password.com", "op://Work/GitHub/token", "*").last.success?
      assert_equal before, File.read(path)
      assert_raises(RuntimeError) { GitHubBridge::Policy.load(path, "missing") }
      assert_equal "personal\nwork\n", run.call("list").first
      assert run.call("init", "work", "my.1password.com", "op://Work/New/token", "company/one").last.success?
      assert_equal personal.token, GitHubBridge::Policy.load(path, "personal").token
    end
  end
end
