#!/usr/bin/env ruby

require "fileutils"
require "optparse"
require "shellwords"
require "tempfile"
require_relative "server"

module OnePasswordBridge
  class Config
    def self.validate(document)
      Policy.from_document(document)
    end

    def self.run(args)
      config_home = ENV["XDG_CONFIG_HOME"].to_s
      config_home = File.expand_path("~/.config") unless config_home.start_with?("/")
      path = File.join(config_home, "ai", "1password-bridge.json")
      parser = OptionParser.new do |options|
        options.banner = <<~HELP
          Usage: 1password-bridge [options] COMMAND [arguments]

          init ACCOUNT          Create the host policy or update its account
          set ALIAS OP_REFERENCE Add or update a secret reference
          remove ALIAS          Remove a secret alias
          show                  Print the host configuration
          edit                  Edit the entire policy using VISUAL or EDITOR

          Changes apply to newly started bridge sessions.
        HELP
        options.on("--file PATH", "Policy file (default: #{path})") { |value| path = value }
        options.on("-h", "--help") { puts options; return }
      end
      parser.parse!(args)
      command = args.shift
      arity = { "init" => 1, "set" => 2, "remove" => 1, "show" => 0, "edit" => 0 }
      raise parser.to_s unless arity.key?(command) && args.length == arity[command]

      path = File.expand_path(path)
      raise "policy must not be a symlink" if File.symlink?(path)
      if File.exist?(path)
        stat = File.stat(path)
        raise "policy must be owned by the current user" unless stat.uid == Process.uid
        raise "policy must not be group- or world-writable" unless (stat.mode & 0o022).zero?
      end
      original = File.exist?(path) ? File.read(path) : nil
      document = original ? JSON.parse(original) : { "secrets" => {} }
      if command == "init"
        # Do not silently combine aliases from old checkout-specific policies.
        document = { "secrets" => {} } if document.is_a?(Hash) && document.key?("projects")
        raise "policy must be an object" unless document.is_a?(Hash)
        document["account"] = args[0]
      else
        validate(document)
        case command
        when "set" then document.fetch("secrets")[args[0]] = args[1]
        when "remove"
          raise "unknown secret alias: #{args[0]}" unless document.fetch("secrets").key?(args[0])
          document.fetch("secrets").delete(args[0])
        when "show"
          puts JSON.pretty_generate(document)
          return
        end
      end
      validate(document)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      Tempfile.create([".1password-bridge-", ".json"], File.dirname(path)) do |file|
        file.write(JSON.pretty_generate(document) + "\n")
        file.flush
        if command == "edit"
          editor = ENV["VISUAL"].to_s.empty? ? ENV.fetch("EDITOR", "vi") : ENV["VISUAL"]
          raise "editor failed; policy unchanged" unless system(*Shellwords.split(editor), file.path)
          document = JSON.parse(File.read(file.path))
        end
        validate(document)
        current = File.exist?(path) ? File.read(path) : nil
        raise "policy changed while editing; refusing to overwrite" if File.symlink?(path) || current != original

        # Editors may replace their input file, so reopen before writing.
        File.open(file.path, "w", 0o600) do |output|
          output.chmod(0o600)
          output.write(JSON.pretty_generate(document) + "\n")
          output.flush
          output.fsync
        end
        File.rename(file.path, path)
      end
      puts "Saved #{path}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    OnePasswordBridge::Config.run(ARGV)
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
