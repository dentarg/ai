require "json"

module GitHubBridge
  class CommandError < RuntimeError
    attr_reader :exit_status, :output, :error_output

    def initialize(exit_status:, output:, error_output:)
      super("command failed")
      @exit_status, @output, @error_output = exit_status, output, error_output
    end
  end

  class RequestError < RuntimeError
    MAX_MESSAGE_BYTES = 4096
    attr_reader :details

    def initialize(details)
      super("GitHub request failed")
      @details = details
    end

    def self.graphql(errors, stage:)
      records = Array(errors).select { |error| error.is_a?(Hash) }
      messages = records.map { |error| error["message"] if error["message"].is_a?(String) }.compact
      types = records.map do |error|
        type = error["type"]
        type ||= error["extensions"]["code"] if error["extensions"].is_a?(Hash)
        type if type.is_a?(String)
      end.compact
      new(stage: stage, error_message: messages.join("; "), github_error_type: types.uniq.join(","))
    end

    def self.command(error, stage:)
      details = { stage: stage, error_class: error.class.name, exit_status: error.exit_status }
      error_output = error.error_output.dup.force_encoding(Encoding::UTF_8).scrub
      begin
        response = JSON.parse(error.output.to_s.dup.force_encoding(Encoding::UTF_8).scrub)
        if response.is_a?(Hash)
          details.merge!(graphql(response["errors"], stage: stage).details) if response["errors"].is_a?(Array)
          if details[:error_message].to_s.empty? && response["message"].is_a?(String)
            details[:error_message] = response["message"]
          end
        end
      rescue JSON::ParserError
        # CLI and transport failures may have no JSON response.
      end
      status = error_output[/\(HTTP ([0-9]{3})\)/, 1]
      details[:http_status] = status.to_i if status
      details[:error_message] = [details[:error_message], error_output].compact.reject(&:empty?).uniq.join("; ")
      new(details)
    end

    def redacted(secrets)
      secrets = secrets.select { |secret| secret.is_a?(String) && !secret.empty? }.sort_by { |secret| -secret.bytesize }
      fields = details.transform_values do |value|
        next value unless value.is_a?(String)

        text = value.dup.force_encoding(Encoding::UTF_8).scrub
        secrets.each { |secret| text = text.gsub(secret, "[REDACTED]") }
        text = text.gsub(/[\u0000-\u001f\u007f-\u009f]/, " ")
        text.byteslice(0, MAX_MESSAGE_BYTES).scrub("")
      end
      self.class.new(fields.reject { |_, value| value == "" })
    end
  end
end
