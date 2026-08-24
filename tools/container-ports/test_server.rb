#!/usr/bin/env ruby

require "fileutils"
require "minitest/autorun"
require "tmpdir"

require_relative "server"

class ContainerPortsTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @repo = File.join(@tmpdir, "repo")
    system("git", "init", "--quiet", "--initial-branch=feature/current", @repo) ||
      raise("failed to initialize test repository")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_reads_current_branch_from_cwd
    assert_equal "feature/current", current_git_branch(@repo)
  end

  def test_queries_each_working_directory_once
    containers = 2.times.map do
      Container.new(labels: { "cwd" => @repo })
    end
    lookups = []
    reader = Object.new
    reader.define_singleton_method(:current_git_branch) do |path|
      lookups << path
      "feature/current"
    end

    reader.send(:attach_git_branches, containers)

    assert_equal [@repo], lookups
    assert_equal ["feature/current", "feature/current"], containers.map(&:branch)
  end

  def test_expands_home_relative_cwd
    original_home = ENV["HOME"]
    ENV["HOME"] = @tmpdir

    assert_equal @repo, resolve_cwd("~/repo")
  ensure
    ENV["HOME"] = original_home
  end

  def test_renders_branch_below_cwd
    html = render_cwd({ "cwd" => "~/example" }, "feature/current")

    assert_equal(
      '<code class="cwd"><span class="cwd-parent">~/</span>' \
        '<span class="cwd-name">example</span></code>' \
        '<code class="branch">feature/current</code>',
      html,
    )
  end

  def test_renders_main_branch_with_subdued_style
    html = render_cwd({ "cwd" => "~/example" }, "main")

    assert_includes html, '<code class="branch branch-main">main</code>'
  end

  def test_uses_agent_label_before_process_fallback
    labeled = Container.new(
      id: "new",
      labels: { "agent" => "codex" },
    )
    legacy = Container.new(id: "old", labels: {})
    lookups = []
    detector = Object.new
    detector.define_singleton_method(:running_agents) do |container_id|
      lookups << container_id
      ["Claude"]
    end

    detector.send(:attach_agents, [labeled, legacy])

    assert_equal ["old"], lookups
    assert_equal "Codex", labeled.agent
    assert_equal "Claude", legacy.agent
  end

  def test_detects_node_based_agents
    assert_equal(
      "Gemini",
      agent_from_command("node /usr/lib/node_modules/@google/gemini-cli/index.js"),
    )
  end

  def test_renders_distinct_agent_classes
    AGENT_CLASSES.each do |agent, css_class|
      assert_includes render_agent(agent), "agent #{css_class}"
    end
  end

  def test_renders_image_below_name
    container = Container.new(
      id: "abc123",
      name: "example",
      image: "ai:latest",
      status: "Up",
      ports: [],
      labels: { "cwd" => "~/example" },
      agent: "Claude",
    )

    html = render_row(container)

    assert_match(
      %r{<code>example</code>.*<span class="image">ai:latest</span>}m,
      html,
    )
    assert_includes html, '<td data-sort-value="example">'
    assert_includes html, '<td data-sort-value="~/example">'
    assert_includes html, '<span class="agent agent-claude">Claude</span>'
  end

  def test_renders_sortable_headers
    html = render_table([])

    assert_includes(
      html,
      '<button type="button" data-sort-type="text">Cwd</button>',
    )
    assert_includes(
      html,
      '<button type="button" data-sort-type="text">Agent</button>',
    )
    assert_includes(
      html,
      '<button type="button" data-sort-type="number">Ports</button>',
    )
  end

  def test_formats_running_container_count
    assert_equal "0 containers running", container_count_label(:ok, [])
    assert_equal "1 container running", container_count_label(:ok, [Object.new])
    assert_equal "2 containers running", container_count_label(:ok, [Object.new, Object.new])
    assert_equal "Container count unavailable", container_count_label(:error, "failure")
  end
end
