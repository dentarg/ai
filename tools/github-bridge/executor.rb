require "open3"
require "timeout"
require_relative "broker"

module GitHubBridge
  class Runner
    def call(argv, env:, directory:, input: "", timeout: 60, limit: 2 * 1024 * 1024)
      Open3.popen3(env, *argv, chdir: directory, unsetenv_others: true, pgroup: true) do |stdin, stdout, stderr, process|
        begin
          Timeout.timeout(timeout) do
            stdin.write(input)
            stdin.close
            streams = [stdout, stderr]
            output = +"".b
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

      operation = request.fetch("operation")
      repository = "repos/#{request.fetch('repository')}"
      number = request["number"]
      endpoint, paginated = case operation
      when "pr-list" then ["#{repository}/pulls?state=open&per_page=30", false]
      when "pr-view", "pr-diff", "pr-edit-body" then ["#{repository}/pulls/#{number}", false]
      when "pr-create" then ["#{repository}/pulls", false]
      when "pr-comments", "issue-comments" then ["#{repository}/issues/#{number}/comments?per_page=100", true]
      when "pr-reviews" then ["#{repository}/pulls/#{number}/reviews?per_page=100", true]
      when "pr-review-comments" then ["#{repository}/pulls/#{number}/comments?per_page=100", true]
      when "issue-list" then ["#{repository}/issues?state=all&per_page=100", true]
      when "issue-view" then ["#{repository}/issues/#{number}", false]
      when "issue-timeline" then ["#{repository}/issues/#{number}/timeline?per_page=100", true]
      else raise "unsupported operation"
      end
      accept = operation == "pr-diff" ? "application/vnd.github.diff" : "application/vnd.github+json"
      method = { "pr-create" => "POST", "pr-edit-body" => "PATCH" }.fetch(operation, "GET")
      argv = [@gh, "api", "--hostname", "github.com", "--method", method, "-H", "Accept: #{accept}", endpoint]
      argv += ["--paginate", "--slurp"] if paginated
      input = ""
      if operation == "pr-create"
        argv += ["--input", "-"]
        input = JSON.generate(request.slice("head", "base", "title", "body").merge("draft" => true, "maintainer_can_modify" => false))
      end
      if operation == "pr-edit-body"
        argv += ["--input", "-"]
        input = JSON.generate(request.slice("body"))
      end
      env = {
        "HOME" => @directory, "GH_CONFIG_DIR" => @directory, "GH_TOKEN" => token,
        "PATH" => "/usr/bin:/bin:/usr/sbin:/sbin", "GH_PROMPT_DISABLED" => "1",
        "GH_PAGER" => "cat", "NO_COLOR" => "1", "GH_NO_UPDATE_NOTIFIER" => "1",
      }
      output = @runner.call(argv, env: env, directory: @directory, input: input)
      if paginated
        records = JSON.parse(output).flatten(1)
        # GitHub's issues endpoint includes pull requests.
        records.reject! { |record| record.key?("pull_request") } if operation == "issue-list"
        output = JSON.generate(records) + "\n"
      end
      output.gsub(token, "[REDACTED]")
    end
  end

  class Approver
    def initialize(project, directory:, runner: Runner.new)
      @project, @directory, @runner = project, directory, runner
    end

    def call(request)
      action = request.fetch("operation") == "pr-edit-body" ? "Replace this PR description?" : "Create this draft PR?"
      message = "Project: #{@project}\n\n#{action}\n#{JSON.pretty_generate(request)}"
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
