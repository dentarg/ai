require "digest"
require "tempfile"

module GitHubBridge
  class Asset
    CONTENT_TYPES = {
      ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
      ".gif" => "image/gif", ".webp" => "image/webp", ".svg" => "image/svg+xml",
      ".mp4" => "video/mp4", ".mov" => "video/quicktime", ".webm" => "video/webm",
    }.freeze
    MAX_IMAGE_BYTES = 10 * 1024 * 1024
    MAX_VIDEO_BYTES = 100 * 1024 * 1024

    attr_reader :name, :content_type, :size, :sha256, :file

    def self.valid_metadata?(name, content_type, size)
      return false unless name.is_a?(String) && name.valid_encoding? && name.bytesize.between?(1, 255)
      return false if name.match?(%r{[\x00-\x1f\x7f/\\]}) || %w[. ..].include?(name)
      return false unless CONTENT_TYPES[File.extname(name).downcase] == content_type && content_type

      maximum = content_type.start_with?("video/") ? MAX_VIDEO_BYTES : MAX_IMAGE_BYTES
      size.is_a?(Integer) && size.between?(1, maximum)
    end

    def initialize(connection, name:, content_type:, size:)
      raise ArgumentError, "invalid asset metadata" unless self.class.valid_metadata?(name, content_type, size)

      @name, @content_type, @size = name, content_type, size
      @file = Tempfile.new("github-asset-")
      @file.binmode
      digest = Digest::SHA256.new
      remaining = size
      while remaining.positive?
        chunk = connection.read([remaining, 64 * 1024].min)
        raise ArgumentError, "incomplete asset" unless chunk && !chunk.empty?

        @file.write(chunk)
        digest.update(chunk)
        remaining -= chunk.bytesize
      end
      @file.flush
      @file.rewind
      @sha256 = digest.hexdigest
    ensure
      close unless @sha256
    end

    def summary
      { "name" => name, "content_type" => content_type, "size" => size, "sha256" => sha256 }
    end

    def markdown(url)
      return url if content_type.start_with?("video/")

      alt = name.gsub(/[\\\[\]]/) { |character| "\\#{character}" }
      "![#{alt}](#{url})"
    end

    def close
      @file&.close!
    end
  end
end
