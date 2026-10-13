require "minitest/autorun"
require "tmpdir"
require_relative "executor"

class GitHubActionsTest < Minitest::Test
  def setup
    @calls, @responses = [], []
    calls, responses = @calls, @responses
    runner = Object.new
    runner.define_singleton_method(:call) do |argv, **options|
      calls << [argv, options]
      raise "unexpected request" if responses.empty?

      response = responses.shift
      if options[:destination]
        options[:destination].write(response)
      else
        response
      end
    end
    @actions = GitHubBridge::Actions.new(gh: "/host/gh", runner: runner, env: {}, directory: Dir.tmpdir)
  end

  def test_runs_jobs_and_artifacts_use_fixed_endpoints_and_paginate_collections
    run_id = 37_604_537_230
    @responses << JSON.generate("workflow_runs" => [{ "id" => run_id }])
    request = { "operation" => "run-list", "repository" => "owner/repo" }
    assert_equal [{ "id" => run_id }], JSON.parse(@actions.call(request))
    assert_equal "repos/owner/repo/actions/runs?per_page=30", @calls.last[0].last
    @responses << JSON.generate("workflow_runs" => [])
    assert_equal [], JSON.parse(@actions.call(request.merge("head_sha" => "a" * 40)))
    assert_equal "repos/owner/repo/actions/runs?per_page=30&head_sha=#{'a' * 40}", @calls.last[0].last

    @responses << JSON.generate("id" => run_id, "conclusion" => "failure")
    assert_equal "failure", JSON.parse(@actions.call(request.merge("operation" => "run-view", "run_id" => run_id))).fetch("conclusion")
    assert_equal "repos/owner/repo/actions/runs/#{run_id}", @calls.last[0].last

    { "run-jobs" => ["jobs", "jobs?filter=latest&per_page=100"],
      "run-artifacts" => ["artifacts", "artifacts?per_page=100"] }.each do |operation, (key, suffix)|
      @responses << JSON.generate([{ key => [{ "id" => 1 }] }, { key => [{ "id" => 2 }] }])
      assert_equal [{ "id" => 1 }, { "id" => 2 }], JSON.parse(@actions.call(request.merge("operation" => operation, "run_id" => run_id)))
      assert_equal ["/host/gh", "api", "--hostname", "github.com", "--method", "GET", "-H", "Accept: application/vnd.github+json",
                    "repos/owner/repo/actions/runs/#{run_id}/#{suffix}", "--paginate", "--slurp"], @calls.last[0]
    end
  end

  def test_logs_are_text_and_archives_preserve_binary_bytes_in_private_temporary_files
    @responses << "step\t\e[31mBuild\e[0m\tfailed é\e]52;c;clipboard\a\e[2J\x00\r\n"
    assert_equal "step\tBuild\tfailed é\n", @actions.call("operation" => "job-log", "repository" => "owner/repo", "job_id" => 50_000_000_000)
    assert_includes @calls.last[0], "--allow-escape-sequences"
    assert_equal "repos/owner/repo/actions/jobs/50000000000/logs", @calls.last[0].last
    assert_equal GitHubBridge::Actions::MAX_LOG_BYTES, @calls.last[1][:limit]
    bytes = "PK\x03\x04\x00\xffsecret_token".b
    { "run-logs" => ["run_id", "runs/123/logs"],
      "artifact-download" => ["artifact_id", "artifacts/123/zip"] }.each do |operation, (key, suffix)|
      @responses << bytes
      download = @actions.call("operation" => operation, "repository" => "owner/repo", key => 123)
      path = download.file.path
      assert_equal bytes, download.file.read
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal "repos/owner/repo/actions/#{suffix}", @calls.last[0].last
      assert_includes @calls.last[0], "--allow-escape-sequences"
      assert_equal GitHubBridge::Download::MAX_BYTES, @calls.last[1][:limit]
      download.close
      refute File.exist?(path)
    ensure
      download&.close
    end
  end

  def test_archive_failures_remove_partial_downloads
    @responses << '{"error":"not a ZIP"}'
    assert_raises(RuntimeError) { @actions.call("operation" => "run-logs", "repository" => "owner/repo", "run_id" => 123) }
    assert @calls.last[1][:destination].closed?
    assert_nil @calls.last[1][:destination].path

    download = GitHubBridge::Download.allocate
    assert_raises(RuntimeError) do
      download.send(:initialize) do |file|
        file.write("PK\x03\x04".b)
        raise "interrupted download"
      end
    end
    assert download.file.closed?
    assert_nil download.file.path
  end

  def test_direct_file_artifacts_are_not_required_to_be_zips
    bytes = "<!DOCTYPE html>\n<html>Report</html>\n"
    @responses << bytes
    download = @actions.call("operation" => "artifact-download", "repository" => "owner/repo", "artifact_id" => 123)
    assert_equal bytes, download.file.read
    assert_equal "application/octet-stream", download.content_type
  ensure
    download&.close
  end
end
