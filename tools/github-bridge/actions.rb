require "json"
require_relative "download"

module GitHubBridge
  class Actions
    MAX_LOG_BYTES = 10 * 1024 * 1024

    def initialize(gh:, runner:, env:, directory:)
      @gh, @runner, @env, @directory = gh, runner, env, directory
    end

    def call(request)
      repository = "repos/#{request.fetch('repository')}/actions"
      run_id = request["run_id"]
      case request.fetch("operation")
      when "run-list"
        endpoint = "#{repository}/runs?per_page=30"
        endpoint += "&head_sha=#{request.fetch('head_sha')}" if request.key?("head_sha")
        JSON.generate(JSON.parse(get(endpoint)).fetch("workflow_runs")) + "\n"
      when "run-view"
        get("#{repository}/runs/#{run_id}")
      when "run-jobs"
        collection("#{repository}/runs/#{run_id}/jobs?filter=latest&per_page=100", "jobs")
      when "run-artifacts"
        collection("#{repository}/runs/#{run_id}/artifacts?per_page=100", "artifacts")
      when "job-log"
        log = get("#{repository}/jobs/#{request.fetch('job_id')}/logs", raw: true, limit: MAX_LOG_BYTES)
        plain_log(log)
      when "run-logs"
        download("#{repository}/runs/#{run_id}/logs", zip: true)
      when "artifact-download"
        download("#{repository}/artifacts/#{request.fetch('artifact_id')}/zip")
      else
        raise "unsupported Actions operation"
      end
    end

    private

    def get(endpoint, paginate: false, raw: false, **options)
      argv = [@gh, "api", "--hostname", "github.com", "--method", "GET",
              "-H", "Accept: application/vnd.github+json"]
      # gh otherwise rejects control bytes even when stdout is a captured pipe.
      argv << "--allow-escape-sequences" if raw
      argv << endpoint
      argv += ["--paginate", "--slurp"] if paginate
      @runner.call(argv, env: @env, directory: @directory, **options)
    end

    def collection(endpoint, key)
      records = JSON.parse(get(endpoint, paginate: true)).flat_map { |page| page.fetch(key) }
      JSON.generate(records) + "\n"
    end

    def download(endpoint, zip: false)
      Download.new(zip: zip) do |file|
        get(endpoint, raw: true, destination: file, limit: Download::MAX_BYTES)
      end
    end

    def plain_log(log)
      text = log.dup.force_encoding(Encoding::UTF_8).scrub
      # Strip CSI, OSC, and other terminal control sequences, then stray controls.
      text.gsub(/\e(?:\[[0-?]*[ -\/]*[@-~]|[\]PX^_].*?(?:\a|\e\\)|[ -\/]*[@-~])/m, "")
          .gsub(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/, "")
    end
  end
end
