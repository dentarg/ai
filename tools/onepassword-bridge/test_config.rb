require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "config"

class OnePasswordConfigTest < Minitest::Test
  def test_cli_preserves_projects_and_validates_updates
    Dir.mktmpdir do |dir|
      path = File.join(dir, "policy.json")
      project = File.realpath(dir)
      cli = File.expand_path("../../bin/1password-bridge", __dir__)
      run = lambda do |*args|
        Open3.capture3(cli, "--file", path, "--project", project, *args)
      end
      assert run.call("init", "my.1password.com").last.success?
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert run.call("set", "github-token", "op://Agent/GitHub/token").last.success?
      assert run.call("init", "other.1password.com").last.success?
      assert_equal "op://Agent/GitHub/token", OnePasswordBridge::Policy.load(path, project).reference_for("github-token")
      before = File.read(path)
      refute run.call("set", "bad alias", "op://Agent/GitHub/token").last.success?
      assert_equal before, File.read(path)
      other = File.join(dir, "other")
      Dir.mkdir(other)
      assert Open3.capture3(cli, "--file", path, "--project", other,
                           "init", "my.1password.com").last.success?
      assert_equal 2, JSON.parse(File.read(path)).fetch("projects").size
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
      args = [cli, "--file", path, "--project", dir]
      assert Open3.capture3(*args, "init", "my.1password.com").last.success?
      editor = File.join(dir, "editor.rb")
      File.write(editor, <<~RUBY)
        require "json"
        document = JSON.parse(File.read(ARGV.fetch(0)))
        document.fetch("projects").values.first["account"] = "updated.1password.com"
        File.write(ARGV.fetch(0), JSON.generate(document))
      RUBY
      env = { "VISUAL" => "#{RbConfig.ruby.shellescape} #{editor.shellescape}" }
      assert Open3.capture3(env, *args, "edit").last.success?
      assert_equal "updated.1password.com", OnePasswordBridge::Policy.load(path, File.realpath(dir)).account
      before = File.read(path)
      File.write(editor, 'File.write(ARGV.fetch(0), "invalid JSON")' + "\n")
      refute Open3.capture3(env, *args, "edit").last.success?
      assert_equal before, File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end
end
