#!/usr/bin/env ruby
# Read-only syntax preflight for an authorised local RPG Maker XP project.
# Never commits or emits embedded scripts; Ruby syntax != Essentials runtime.
require 'json'
require 'zlib'
require 'digest'
require 'optparse'
require 'pathname'

module ShatteredNativeScriptSyntax
  module_function
  MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
  MAX_COMPRESSED_BYTES = 8 * 1024 * 1024
  MAX_SOURCE_BYTES = 16 * 1024 * 1024
  MAX_SCRIPTS = 5000

  def safe_archive(project, name)
    path = project.join('Data', name)
    raise ArgumentError, "missing #{name}" unless path.file? && !path.symlink?
    raise ArgumentError, "oversized #{name}" if path.size > MAX_ARCHIVE_BYTES
    path
  end

  def read_archive(project, name)
    path = safe_archive(project, name)
    data = Marshal.load(path.binread) # Authorised, trusted user-owned game ONLY.
    raise ArgumentError, "invalid #{name} structure" unless data.is_a?(Array) && data.length <= MAX_SCRIPTS
    [path, data]
  end

  def inflated_source(data)
    raise ArgumentError, 'invalid compressed source' unless data.is_a?(String) && data.bytesize <= MAX_COMPRESSED_BYTES
    inflater = Zlib::Inflate.new
    output = +''
    begin
      # Limit decompressed bytes to avoid unbounded allocation on corrupt data.
      remaining = data
      until remaining.empty?
        chunk = remaining.byteslice(0, 1_024)
        remaining = remaining.byteslice(chunk.bytesize, remaining.bytesize - chunk.bytesize) || ''
        output << inflater.inflate(chunk)
        raise ArgumentError, 'script exceeds decompressed size limit' if output.bytesize > MAX_SOURCE_BYTES
      end
      output << inflater.finish
      raise ArgumentError, 'script exceeds decompressed size limit' if output.bytesize > MAX_SOURCE_BYTES
      raise ArgumentError, 'trailing compressed bytes' unless inflater.finished?
      output
    ensure
      inflater.close
    end
  end

  def check_source(source, name, index)
    raise ArgumentError, 'empty or invalid source' unless source.is_a?(String)
    raise ArgumentError, 'script exceeds source size limit' if source.bytesize > MAX_SOURCE_BYTES
    return nil if source.empty?
    RubyVM::InstructionSequence.compile(source, "native:#{index}:#{name}")
    nil
  rescue SyntaxError => e
    # No source excerpts: Ruby's syntax error text may include copyrighted code.
    { 'index' => index, 'name' => name.to_s[0, 120], 'error_class' => e.class.name }
  end

  def audit(project)
    project = Pathname(project).expand_path
    raise ArgumentError, 'project Game.ini missing' unless project.join('Game.ini').file?
    scripts_path, scripts = read_archive(project, 'Scripts.rxdata')
    plugins_path, plugins = read_archive(project, 'PluginScripts.rxdata')
    failures = []
    count = 0
    scripts.each_with_index do |entry, i|
      raise ArgumentError, "invalid native script entry #{i}" unless entry.is_a?(Array) && entry.length == 3 && entry[1].is_a?(String)
      source = inflated_source(entry[2])
      failure = check_source(source, entry[1], i)
      failures << failure.merge('archive' => 'Scripts.rxdata') if failure
      count += 1
    end
    plugin_count = 0
    plugin_metadata = []
    plugins.each_with_index do |group, group_index|
      raise ArgumentError, "invalid plugin group #{group_index}" unless group.is_a?(Array) && group.length == 3 && group[0].is_a?(String) && group[1].is_a?(Hash) && group[2].is_a?(Array)
      plugin_metadata << { 'name' => group[0], 'version' => group[1][:version].to_s }
      group[2].each_with_index do |entry, i|
        raise ArgumentError, "invalid plugin script #{group_index}:#{i}" unless entry.is_a?(Array) && entry.length == 2 && entry[0].is_a?(String)
        source = inflated_source(entry[1])
        failure = check_source(source, entry[0], i)
        failures << failure.merge('archive' => 'PluginScripts.rxdata', 'plugin' => group[0]) if failure
        plugin_count += 1
      end
    end
    { 'kind' => 'native_source_syntax_only_not_gameplay_or_engine_compile',
      'ruby_version' => RUBY_VERSION,
      'scripts_archive_sha256' => Digest::SHA256.file(scripts_path).hexdigest,
      'plugin_archive_sha256' => Digest::SHA256.file(plugins_path).hexdigest,
      'native_script_count' => count, 'native_plugin_script_count' => plugin_count,
      'plugin_metadata' => plugin_metadata, 'syntax_failures' => failures,
      'syntax_pass' => failures.empty?, 'native_runtime_verified' => false,
      'save_reload_verified' => false, 'android_verified' => false }
  end
end

if $PROGRAM_NAME == __FILE__
  opts = {}
  parser = OptionParser.new do |o|
    o.banner = 'Usage: ruby scripts/audit_native_script_syntax.rb --project /private/Essentials [--output /private/report.json]'
    o.on('--project DIR') { |v| opts[:project] = v }
    o.on('--output FILE') { |v| opts[:output] = v }
  end
  parser.parse!
  abort parser.to_s unless opts[:project]
  report = ShatteredNativeScriptSyntax.audit(opts[:project])
  payload = JSON.pretty_generate(report) + "\n"
  if opts[:output]
    raise ArgumentError, 'refusing to overwrite report' if File.exist?(opts[:output])
    File.write(opts[:output], payload)
  else
    puts payload
  end
  exit(report['syntax_pass'] ? 0 : 1)
end
