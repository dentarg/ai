require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "config"

class OnePasswordConfigTest < Minitest::Test
  def test_aliases_are_shared_across_working_directories
    Dir.mktmpdir do |dir|
      first = File.join(dir, "first")
      second = File.join(dir, "second")
      Dir.mkdir(first)
      Dir.mkdir(second)
      env = { "XDG_CONFIG_HOME" => File.join(dir, "config") }
      cli = File.expand_path("../../bin/1password-bridge", __dir__)
      assert Open3.capture3(env, cli, "init", "my.1password.com", chdir: first).last.success?
      _, error, status = Open3.capture3(env, cli, "set", "github-token", "op://Agent/GitHub/token", chdir: second)
      assert status.success?, error
      output, error, status = Open3.capture3(env, cli, "show", chdir: first)
      assert status.success?, error
      assert_equal "op://Agent/GitHub/token", JSON.parse(output).fetch("secrets").fetch("github-token")
    end
  end

  def test_default_policy_uses_the_xdg_config_directory
    Dir.mktmpdir do |dir|
      cli = File.expand_path("../../bin/1password-bridge", __dir__)
      [nil, "", "relative", File.join(dir, "custom config")].each do |config_home|
        home = File.join(dir, "home")
        env = { "HOME" => home, "XDG_CONFIG_HOME" => config_home, "AI_DIR" => File.join(dir, "data") }
        base = config_home&.start_with?("/") ? config_home : File.join(home, ".config")
        path = File.join(base, "ai", "1password-bridge.json")

        output, error, status = Open3.capture3(env, cli, "init", "my.1password.com")

        assert status.success?, error
        assert_includes output, path
        assert_equal "my.1password.com", OnePasswordBridge::Policy.load(path).account
        refute File.exist?(File.join(env.fetch("AI_DIR"), "1password-bridge.json"))
      end
    end
  end

  def test_cli_preserves_aliases_and_validates_updates
    Dir.mktmpdir do |dir|
      path = File.join(dir, "policy.json")
      cli = File.expand_path("../../bin/1password-bridge", __dir__)
      run = lambda do |*args|
        Open3.capture3(cli, "--file", path, *args)
      end
      assert run.call("init", "my.1password.com").last.success?
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert run.call("set", "github-token", "op://Agent/GitHub/token").last.success?
      assert run.call("init", "other.1password.com").last.success?
      assert_equal "op://Agent/GitHub/token", OnePasswordBridge::Policy.load(path).reference_for("github-token")
      before = File.read(path)
      refute run.call("set", "bad alias", "op://Agent/GitHub/token").last.success?
      assert_equal before, File.read(path)
      other = File.join(dir, "other")
      Dir.mkdir(other)
      assert Open3.capture3(cli, "--file", path, "init", "my.1password.com", chdir: other).last.success?
      assert_equal ["github-token"], JSON.parse(File.read(path)).fetch("secrets").keys
      assert run.call("remove", "github-token").last.success?
      output, _, status = run.call("show")
      assert status.success?
      assert_equal({}, JSON.parse(output).fetch("secrets"))
    end
  end

  def test_editor_updates_are_validated_before_replacing_policy
    Dir.mktmpdir do |dir|
      path = File.join(dir, "policy.json")
      cli = File.expand_path("../../bin/1password-bridge", __dir__)
      args = [cli, "--file", path]
      assert Open3.capture3(*args, "init", "my.1password.com").last.success?
      editor = File.join(dir, "editor.rb")
      File.write(editor, <<~RUBY)
        require "json"
        document = JSON.parse(File.read(ARGV.fetch(0)))
        document["account"] = "updated.1password.com"
        File.write(ARGV.fetch(0), JSON.generate(document))
      RUBY
      env = { "VISUAL" => "#{RbConfig.ruby.shellescape} #{editor.shellescape}" }
      assert Open3.capture3(env, *args, "edit").last.success?
      assert_equal "updated.1password.com", OnePasswordBridge::Policy.load(path).account
      before = File.read(path)
      File.write(editor, 'File.write(ARGV.fetch(0), "invalid JSON")' + "\n")
      refute Open3.capture3(env, *args, "edit").last.success?
      assert_equal before, File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end
end
