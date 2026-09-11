#!/usr/bin/env ruby

require "fileutils"
require "optparse"
require "pathname"
require "shellwords"
require "tempfile"
require_relative "server"

module OnePasswordBridge
  class Config
    def self.validate(document)
      raise "policy must contain a projects object" unless document.is_a?(Hash) && document["projects"].is_a?(Hash)

      document["projects"].each do |project, policy|
        path = Pathname.new(project)
        unless path.absolute? && path.cleanpath.to_s == project &&
               (!path.exist? || path.realpath.to_s == project)
          raise "project path must be absolute and canonical: #{project}"
        end
        raise "project policy must be an object: #{project}" unless policy.is_a?(Hash)

        Policy.new(policy.fetch("account"), policy.fetch("secrets"))
      end
    end

    def self.run(args)
      path = File.join(ENV.fetch("AI_DIR", File.expand_path("~/ai")), "1password-bridge.json")
      project = Dir.pwd
      parser = OptionParser.new do |options|
        options.banner = <<~HELP
          Usage: 1password-bridge [options] COMMAND [arguments]

          init ACCOUNT          Create a project or update its account
          set ALIAS OP_REFERENCE Add or update a secret reference
          remove ALIAS          Remove a secret alias
          show                  Print the current project's configuration
          edit                  Edit the entire policy using VISUAL or EDITOR

          Changes apply to newly started bridge sessions.
        HELP
        options.on("--file PATH", "Policy file (default: $AI_DIR/1password-bridge.json)") { |value| path = value }
        options.on("--project PATH", "Project directory (default: current directory)") { |value| project = value }
        options.on("-h", "--help") { puts options; return }
      end
      parser.parse!(args)
      command = args.shift
      arity = { "init" => 1, "set" => 2, "remove" => 1, "show" => 0, "edit" => 0 }
      raise parser.to_s unless arity.key?(command) && args.length == arity[command]

      project = File.realpath(project)
      path = File.expand_path(path)
      raise "policy must not be a symlink" if File.symlink?(path)
      if File.exist?(path)
        stat = File.stat(path)
        raise "policy must be owned by the current user" unless stat.uid == Process.uid
        raise "policy must not be group- or world-writable" unless (stat.mode & 0o022).zero?
      end
      original = File.exist?(path) ? File.read(path) : nil
      document = original ? JSON.parse(original) : { "projects" => {} }
      validate(document)
      projects = document.fetch("projects")
      case command
      when "init"
        projects[project] ||= { "secrets" => {} }
        projects[project]["account"] = args[0]
      when "set", "remove", "show"
        policy = projects.fetch(project) { raise "no policy for project; run init ACCOUNT first" }
        case command
        when "set" then policy.fetch("secrets")[args[0]] = args[1]
        when "remove"
          raise "unknown secret alias: #{args[0]}" unless policy.fetch("secrets").key?(args[0])
          policy.fetch("secrets").delete(args[0])
        when "show"
          puts JSON.pretty_generate(policy)
          return
        end
      end
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
