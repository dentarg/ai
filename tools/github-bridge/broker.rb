require "json"
require "openssl"

module GitHubBridge
  Response = Struct.new(:status, :body)
  READ_OPERATIONS = %w[pr-list pr-view pr-diff pr-comments pr-reviews pr-review-comments
                       issue-list issue-view issue-comments issue-timeline].freeze
  WRITE_OPERATIONS = %w[pr-create pr-edit-body].freeze
  OPERATIONS = (READ_OPERATIONS + WRITE_OPERATIONS).freeze
  REPOSITORY = /\A[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9_][A-Za-z0-9_.-]*\z/

  PROFILE = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
  SCOPE = /\A[A-Za-z0-9][A-Za-z0-9-]*\/(?:[A-Za-z0-9_][A-Za-z0-9_.-]*|\*)\z/

  class Policy
    attr_reader :account, :token, :repositories, :operations

    def self.path
      base = ENV["XDG_CONFIG_HOME"].to_s
      base = File.expand_path("~/.config") unless base.start_with?("/")
      File.join(base, "ai", "github-bridge.json")
    end

    def self.load(path, profile)
      stat = File.lstat(path)
      raise "policy must be a regular file owned by the current user" unless stat.file? && stat.uid == Process.uid
      raise "policy must not be group- or world-writable" unless (stat.mode & 0o022).zero?

      profiles = validate_profiles(JSON.parse(File.read(path)))
      new(profiles.fetch(profile) { raise "unknown GitHub profile: #{profile}" })
    end

    def self.validate_profiles(document)
      profiles = document.is_a?(Hash) && document["profiles"]
      raise "policy must contain named profiles" unless profiles.is_a?(Hash)
      profiles.each do |name, policy|
        raise "invalid profile name" unless name.is_a?(String) && name.match?(PROFILE)
        new(policy)
      end
      profiles
    end

    def allows_repository?(repository)
      return false unless repository.is_a?(String) && repository.match?(REPOSITORY)

      owner = repository.split("/", 2).first
      @repositories.any? do |scope|
        scope.casecmp?(repository) || scope.casecmp?("#{owner}/*")
      end
    end

    def initialize(document)
      raise "policy must be an object" unless document.is_a?(Hash)
      if document.key?("projects")
        raise "checkout-based policy is no longer supported; run github-bridge init to configure host-wide access"
      end

      @account = document.fetch("account")
      @token = document.fetch("token")
      @repositories = document.fetch("repositories")
      @operations = document.fetch("operations")
      raise "invalid 1Password account" unless @account.is_a?(String) && @account.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
      unless @token.is_a?(String) && @token.match?(%r{\Aop://[^/\x00-\x1f]+/[^/\x00-\x1f]+/(?:[^/\x00-\x1f]+/)?[^/\x00-\x1f]+\z})
        raise "invalid 1Password token reference"
      end
      unless @repositories.is_a?(Array) && !@repositories.empty? && @repositories.all? { |repo| repo.is_a?(String) && repo.match?(SCOPE) }
        raise "invalid repositories"
      end
      unless @operations.is_a?(Array) && @operations.all? { |operation| OPERATIONS.include?(operation) }
        raise "invalid operations"
      end
      @repositories.freeze
      @operations.freeze
    end
  end

  class Broker
    def initialize(policy:, token:, executor:, approver:, logger:)
      @policy, @token, @executor, @approver, @logger = policy, token, executor, approver, logger
    end

    def authenticated?(candidate)
      candidate.is_a?(String) && candidate.bytesize == @token.bytesize &&
        OpenSSL.fixed_length_secure_compare(candidate, @token)
    end

    def call(request, token)
      return response(401, "unauthorized") unless authenticated?(token)
      return response(400, "invalid request") unless request.is_a?(Hash)
      operation, repository = request.values_at("operation", "repository")
      unless @policy.operations.include?(operation) && @policy.allows_repository?(repository)
        return response(403, "operation or repository not allowed")
      end
      return response(400, "invalid request") unless valid?(request)
      if WRITE_OPERATIONS.include?(operation) && !@approver.call(request)
        @logger.call("info", "request_denied", operation, repository)
        return response(403, "request denied on host")
      end

      output = @executor.call(request)
      @logger.call("info", "request_completed", operation, repository)
      Response.new(200, output)
    rescue StandardError
      @logger.call("error", "request_failed", operation, repository)
      response(502, "GitHub request failed; check host access and policy")
    end

    private

    def response(status, message)
      @logger.call("warn", "request_rejected", nil, nil) if status >= 400
      Response.new(status, "#{message}\n")
    end

    def valid?(request)
      keys = %w[operation repository]
      case request.fetch("operation")
      when *(READ_OPERATIONS - %w[pr-list issue-list]), "pr-edit-body"
        keys += %w[number]
        return false unless request["number"].is_a?(Integer) && request["number"].between?(1, 2**31 - 1)
        if request["operation"] == "pr-edit-body"
          keys += %w[body]
          return false unless text?(request["body"], 8192)
        end
      when "pr-create"
        keys += %w[head base title body]
        %w[head base].each do |key|
          value = request[key]
          return false unless value.is_a?(String) && value.bytesize.between?(1, 255) && value.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.\/-]*\z/)
        end
        return false unless text?(request["title"], 256) && !request["title"].strip.empty?
        return false unless text?(request["body"], 8192)
      end
      request.keys.sort == keys.sort
    end

    def text?(value, maximum)
      value.is_a?(String) && value.bytesize <= maximum && !value.match?(/[\x00-\x08\x0b-\x1f\x7f]/)
    end
  end
end
