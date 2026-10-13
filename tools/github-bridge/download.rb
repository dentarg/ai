require "tempfile"

module GitHubBridge
  class Download
    MAX_BYTES = 100 * 1024 * 1024

    attr_reader :file, :content_type

    def initialize(zip: false)
      @content_type = zip ? "application/zip" : "application/octet-stream"
      @file = Tempfile.new("github-download-")
      @file.binmode
      yield @file
      @file.flush
      @file.rewind
      if zip && !["PK\x03\x04".b, "PK\x05\x06".b].include?(@file.read(4))
        raise "invalid ZIP response"
      end

      @file.rewind
      complete = true
    ensure
      close unless complete
    end

    def close
      @file&.close!
    end
  end
end
