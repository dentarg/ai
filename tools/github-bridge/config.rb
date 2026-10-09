require "fileutils"
require "optparse"
require "tempfile"
require_relative "broker"

module GitHubBridge
  class Config
    def self.run(args)
      path = Policy.path
      parser = OptionParser.new do |options|
        options.banner = <<~HELP
          Usage: github-bridge [--file PATH] COMMAND [arguments]

          init PROFILE ACCOUNT OP_REFERENCE SCOPE...  Configure read-only access
          allow PROFILE OPERATION...                 Replace allowed operations
          show PROFILE                               Show a profile
          check PROFILE                              Validate a profile
          list                                       List profile names

          Scope: OWNER/REPO or 'ORG/*' (quote wildcards).

          Operations: #{OPERATIONS.join(', ')}
          Changes apply to newly started bridge sessions.
        HELP
        options.on("--file PATH", "Default: #{path}") { |value| path = value }
        options.on("-h", "--help") { puts options; return }
      end
      parser.parse!(args)
      command = args.shift
      valid = (command == "init" && args.size >= 4) || (command == "allow" && args.size >= 2) || (%w[show check].include?(command) && args.size == 1) || (command == "list" && args.empty?)
      raise parser.to_s unless valid
      path = File.expand_path(path)
      raise "policy must not be a symlink" if File.symlink?(path)
      if File.exist?(path)
        stat = File.stat(path)
        raise "unsafe policy ownership or permissions" unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o022).zero?
      end
      original = File.exist?(path) ? File.read(path) : nil
      document = original ? JSON.parse(original) : { "profiles" => {} }
      profiles = Policy.validate_profiles(document)
      if command == "list"
        puts profiles.keys.sort
        return
      end
      name = args.shift
      raise "invalid profile name" unless name.match?(PROFILE)
      case command
      when "init"
        profiles[name] = { "account" => args.shift, "token" => args.shift,
                           "repositories" => args, "operations" => READ_OPERATIONS }
      when "allow"
        profile = profiles.fetch(name) { raise "unknown GitHub profile: #{name}" }
        profile["operations"] = args
      when "show", "check"
        Policy.load(path, name)
        puts(command == "show" ? JSON.pretty_generate(profiles.fetch(name)) : "Policy valid")
        return
      end
      Policy.validate_profiles(document)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      Tempfile.create([".github-bridge-", ".json"], File.dirname(path)) do |file|
        file.chmod(0o600)
        file.write(JSON.pretty_generate(document) + "\n")
        file.flush
        file.fsync
        current = File.exist?(path) ? File.read(path) : nil
        raise "policy changed; refusing to overwrite" if File.symlink?(path) || current != original
        File.rename(file.path, path)
      end
      puts "Saved #{path}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    GitHubBridge::Config.run(ARGV)
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
