require "minitest/autorun"
require "stringio"
require_relative "asset"

class GitHubAssetTest < Minitest::Test
  def test_receiving_an_asset_preserves_bytes_and_cleans_up_the_private_file
    bytes = "\x89PNG\r\n\x1a\n\x00\xff".b
    asset = GitHubBridge::Asset.new(StringIO.new(bytes), name: "screenshot.png", content_type: "image/png", size: bytes.bytesize)
    path = asset.file.path
    assert_equal bytes, asset.file.read
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal({ "name" => "screenshot.png", "content_type" => "image/png", "size" => bytes.bytesize,
                   "sha256" => Digest::SHA256.hexdigest(bytes) }, asset.summary)
    assert_equal "![screenshot.png](https://github.com/user-attachments/assets/example)",
                 asset.markdown("https://github.com/user-attachments/assets/example")
    asset.close
    refute File.exist?(path)
  ensure
    asset&.close
  end

  def test_metadata_rejects_paths_unsupported_types_and_oversized_files
    klass = GitHubBridge::Asset
    %w[../secret.png /etc/file.png folder/file.png file.txt].each do |name|
      refute klass.valid_metadata?(name, "image/png", 1)
    end
    ["bad\n.png", "bad\u0000.png", "x" * 256 + ".png", "dir\\file.png", "\xff.png".b.force_encoding("UTF-8")].each do |name|
      refute klass.valid_metadata?(name, "image/png", 1)
    end
    refute klass.valid_metadata?("file.png", "video/mp4", 1)
    refute klass.valid_metadata?("file.png", "image/png", 0)
    refute klass.valid_metadata?("file.png", "image/png", klass::MAX_IMAGE_BYTES + 1)
    assert klass.valid_metadata?("file.PNG", "image/png", klass::MAX_IMAGE_BYTES)
    assert klass.valid_metadata?("file.webm", "video/webm", klass::MAX_VIDEO_BYTES)
    refute klass.valid_metadata?("file.webm", "video/webm", klass::MAX_VIDEO_BYTES + 1)
    asset = klass.allocate
    assert_raises(ArgumentError) { asset.send(:initialize, StringIO.new("short"), name: "file.png", content_type: "image/png", size: 10) }
    assert asset.file.closed?
    assert_nil asset.file.path
  end

  def test_video_markdown_is_a_bare_url_and_image_alt_text_is_escaped
    url = "https://github.com/user-attachments/assets/test"
    video = GitHubBridge::Asset.new(StringIO.new("video"), name: "clip.mp4", content_type: "video/mp4", size: 5)
    assert_equal url, video.markdown(url)
    image = GitHubBridge::Asset.new(StringIO.new("image"), name: "a[b].png", content_type: "image/png", size: 5)
    assert_equal '![a\[b\].png](https://github.com/user-attachments/assets/test)', image.markdown(url)
  ensure
    video&.close
    image&.close
  end
end
