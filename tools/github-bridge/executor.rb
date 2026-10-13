require "open3"
require "timeout"
require "uri"
require_relative "broker"
require_relative "review_threads"
require_relative "actions"

module GitHubBridge
  class Runner
    def call(argv, env:, directory:, input: "", timeout: 60, limit: 2 * 1024 * 1024, destination: nil)
      Open3.popen3(env, *argv, chdir: directory, unsetenv_others: true, pgroup: true) do |stdin, stdout, stderr, process|
        begin
          Timeout.timeout(timeout) do
            if input.respond_to?(:read)
              IO.copy_stream(input, stdin)
            else
              stdin.write(input)
            end
            stdin.close
            streams = [stdout, stderr]
            output = destination || +"".b
            bytes = 0
            until streams.empty?
              IO.select(streams).first.each do |stream|
                chunk = stream.read_nonblock(16 * 1024, exception: false)
                next if chunk == :wait_readable
                if chunk.nil?
                  streams.delete(stream)
                  next
                end
                bytes += chunk.bytesize
                raise "command output limit exceeded" if bytes > limit
                output << chunk if stream == stdout
              end
            end
            raise "command failed" unless process.value.success?
            output
          end
        ensure
          # Also stop descendants that outlive their parent or hold its pipes.
          begin
            Process.kill("KILL", -process.pid)
          rescue Errno::ESRCH
            nil
          end
        end
      end
    end
  end

  class Executor
    def initialize(policy:, gh:, op:, directory:, runner: Runner.new)
      @policy, @gh, @op, @directory, @runner = policy, gh, op, directory, runner
    end

    def call(request)
      token = @runner.call(
        [@op, "read", "--account", @policy.account, @policy.token],
        env: { "HOME" => Dir.home, "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin" },
        directory: @directory, limit: 4096,
      ).strip
      raise "invalid token" unless token.match?(/\A[A-Za-z0-9_]+\z/)

      env = {
        "HOME" => @directory, "GH_CONFIG_DIR" => @directory, "GH_TOKEN" => token,
        "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin", "GH_PROMPT_DISABLED" => "1",
        "GH_PAGER" => "cat", "NO_COLOR" => "1", "GH_NO_UPDATE_NOTIFIER" => "1",
      }
      operation = request.fetch("operation")
      if CI_OPERATIONS.include?(operation)
        result = Actions.new(gh: @gh, runner: @runner, env: env, directory: @directory).call(request)
        # Downloads must remain byte-for-byte intact, including compressed data.
        return result.is_a?(Download) ? result : result.gsub(token, "[REDACTED]")
      end
      if operation == "asset-upload"
        return upload_asset(request, env).gsub(token, "[REDACTED]")
      end
      if %w[pr-review-threads pr-review-reply pr-review-resolve].include?(operation)
        result = ReviewThreads.new(gh: @gh, runner: @runner, env: env, directory: @directory).call(request)
        return (JSON.generate(result) + "\n").gsub(token, "[REDACTED]")
      end
      repository = "repos/#{request.fetch('repository')}"
      number = request["number"]
      endpoint, paginated = case operation
      when "pr-list" then ["#{repository}/pulls?state=open&per_page=30", false]
      when "pr-view", "pr-diff", "pr-edit-body" then ["#{repository}/pulls/#{number}", false]
      when "pr-create" then ["#{repository}/pulls", false]
      when "pr-comments", "issue-comments" then ["#{repository}/issues/#{number}/comments?per_page=100", true]
      when "pr-comment" then ["#{repository}/issues/#{number}/comments", false]
      when "pr-reviews" then ["#{repository}/pulls/#{number}/reviews?per_page=100", true]
      when "pr-review-comments" then ["#{repository}/pulls/#{number}/comments?per_page=100", true]
      when "issue-list" then ["#{repository}/issues?state=all&per_page=100", true]
      when "issue-create" then ["#{repository}/issues", false]
      when "issue-view" then ["#{repository}/issues/#{number}", false]
      when "issue-timeline" then ["#{repository}/issues/#{number}/timeline?per_page=100", true]
      else raise "unsupported operation"
      end
      accept = operation == "pr-diff" ? "application/vnd.github.diff" : "application/vnd.github+json"
      method = { "pr-create" => "POST", "pr-edit-body" => "PATCH", "issue-create" => "POST", "pr-comment" => "POST" }.fetch(operation, "GET")
      argv = [@gh, "api", "--hostname", "github.com", "--method", method, "-H", "Accept: #{accept}", endpoint]
      argv += ["--paginate", "--slurp"] if paginated
      input = ""
      if operation == "pr-create"
        argv += ["--input", "-"]
        input = JSON.generate(request.slice("head", "base", "title", "body").merge("draft" => true, "maintainer_can_modify" => false))
      end
      if %w[pr-edit-body pr-comment].include?(operation)
        argv += ["--input", "-"]
        input = JSON.generate(request.slice("body"))
      end
      if operation == "issue-create"
        argv += ["--input", "-"]
        input = JSON.generate(request.slice("title", "body"))
      end
      if operation == "pr-comment"
        # GitHub shares this write endpoint with issues; require a real PR first.
        @runner.call([@gh, "api", "--hostname", "github.com", "--method", "GET", "#{repository}/pulls/#{number}"],
                     env: env, directory: @directory)
      end
      output = @runner.call(argv, env: env, directory: @directory, input: input)
      if paginated
        records = JSON.parse(output).flatten(1)
        # GitHub's issues endpoint includes pull requests.
        records.reject! { |record| record.key?("pull_request") } if operation == "issue-list"
        output = JSON.generate(records) + "\n"
      end
      output.gsub(token, "[REDACTED]")
    end

    private

    def upload_asset(request, env)
      asset = request.fetch("asset")
      details = @runner.call([@gh, "api", "--hostname", "github.com", "--method", "GET", "repos/#{request.fetch('repository')}"],
                             env: env, directory: @directory)
      repository = JSON.parse(details)
      unless repository.fetch("id").is_a?(Integer) && repository.fetch("id").positive? && repository.dig("permissions", "push") == true
        raise "asset uploads require repository write access"
      end
      query = URI.encode_www_form("name" => asset.name, "content_type" => asset.content_type, "repository_id" => repository.fetch("id"))
      # This is the same endpoint used by gh's --attach implementation.
      endpoint = "https://uploads.github.com/user-attachments/assets?#{query}"
      asset.file.rewind
      output = @runner.call([@gh, "api", "--hostname", "github.com", "--method", "POST",
                             "-H", "Content-Type: application/octet-stream", "-H", "Accept: application/vnd.github+json",
                             "-H", "Content-Length: #{asset.size}",
                             endpoint, "--input", "-"], env: env, directory: @directory, input: asset.file)
      url = JSON.parse(output).fetch("url")
      unless url.is_a?(String) && url.match?(%r{\Ahttps://github\.com/user-attachments/assets/[A-Za-z0-9-]+\z})
        raise "invalid asset URL"
      end
      JSON.generate("url" => url, "markdown" => asset.markdown(url)) + "\n"
    end
  end

  class Approver
    def initialize(project, directory:, runner: Runner.new)
      @project, @directory, @runner = project, directory, runner
    end

    def call(request)
      action = case request.fetch("operation")
      when "pr-create" then "Create this draft PR?"
      when "pr-edit-body" then "Replace this PR description?"
      when "issue-create" then "Create this issue?"
      when "pr-comment" then "Post this PR discussion comment?"
      when "pr-review-reply" then "Reply to this PR review thread?"
      when "pr-review-resolve" then "Resolve this PR review thread?"
      when "asset-upload" then "Upload this asset to GitHub?"
      else raise "unsupported approval operation"
      end
      details = request.transform_values { |value| value.is_a?(Asset) ? value.summary : value }
      message = "Project: #{@project}\n\n#{action}\n#{JSON.pretty_generate(details)}"
      script = <<~APPLESCRIPT
        on run arguments
          set decision to display dialog (item 1 of arguments) buttons {"Deny", "Allow"} default button "Deny" cancel button "Deny" with title "AI GitHub request" giving up after 60
          if gave up of decision then error "Approval timed out"
        end run
      APPLESCRIPT
      @runner.call(["/usr/bin/osascript", "-", message], env: { "HOME" => Dir.home },
                   directory: @directory, input: script, timeout: 65, limit: 4096)
      true
    rescue StandardError
      false
    end
  end
end
