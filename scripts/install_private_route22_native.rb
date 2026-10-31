#!/usr/bin/env ruby
# frozen_string_literal: true
# Installs the source-pinned Route22 event into ONE PRIVATE candidate, never
# the user's original v0.4 project. Requires separately held Rattata artwork.
require "json"
require "digest"
require "zlib"
require "optparse"
require "pathname"
require_relative "private_rgss_writer"

module ShatteredPrivateRoute22
  ROOT = File.expand_path("..", __dir__)
  SOURCE_MAP_SHA = "0ec2a363a411c9b0086a4a3868fdca0d8b0339c26ab1ddf5a5c33b84174f9b6b"
  SOURCE_SCRIPTS_SHA = "38d9b59fb41a8b0d2449134cf1e316a3297a3f5eceac3a281f40ad80dc4c0b05"
  SOURCE_SCRIPT_COUNT = 402
  SOURCE_UUID = "c4c03051-b9be-4d3c-a06c-bcde09a0e3a2"
  LEGACY_EVENT_SHA = "ef8861a24531fedc56be153cc88a80ed6e314103af48b810d85b116aaadfe786"
  SWITCHES = [991, 992].freeze
  VARIABLE = 991

  def self.config(sprite)
    {
      "schema_version" => 1, "source_map_uuid" => SOURCE_UUID,
      "map_id" => 16, "expected_map_sha256" => SOURCE_MAP_SHA,
      "scatter_switch" => SWITCHES[0], "cleared_switch" => SWITCHES[1],
      "outcome_variable" => VARIABLE, "rattata_character" => sprite,
      "native_dimensions" => [54, 34], "reviewed_native_geometry" => true,
      "event_positions" => {
        "triggers" => [[31, 17], [31, 18], [32, 18]],
        "npcs" => [[29, 17], [29, 18], [28, 18]]
      },
      "scatter_moves" => [3, 4, 3],
      "legacy_migration" => {
        "event_id" => 3, "event_name" => "SHATTERED: Rattata ambush",
        "x" => 30, "y" => 17, "event_sha256" => LEGACY_EVENT_SHA
      }
    }
  end

  def self.event_id_conflicts(map)
    conflicts = []
    map.events.each do |id, event|
      event.pages.each_with_index do |page, index|
        condition = page.condition
        conflicts << [id, index, "condition"] if
          (condition.switch1_valid && SWITCHES.include?(condition.switch1_id)) ||
          (condition.switch2_valid && SWITCHES.include?(condition.switch2_id)) ||
          (condition.variable_valid && condition.variable_id == VARIABLE)
        page.list.each do |cmd|
          params = cmd.parameters
          if cmd.code == 121 && params[0].is_a?(Integer) && params[1].is_a?(Integer) &&
             SWITCHES.any? { |number| number.between?(params[0], params[1]) }
            conflicts << [id, index, "switch"]
          elsif cmd.code == 122 && params[0].is_a?(Integer) && params[1].is_a?(Integer) &&
                VARIABLE.between?(params[0], params[1])
            conflicts << [id, index, "variable"]
          elsif [355, 655].include?(cmd.code) && params.any? { |p|
            p.is_a?(String) && p.match?(/\$game_(?:switches|variables)\[\s*(?:991|992)\s*\]/)
          }
            conflicts << [id, index, "script"]
          end
        end
      end
    end
    conflicts
  end

  # Static audit of the original v0.4 compiled script archive. The exact
  # original archive is SHA-pinned: an altered or unreviewed script must not
  # silently reuse the production Route22 switch/variable allocation.
  # This does not prove dynamic references absent; the digest pin is required.
  def self.original_script_id_conflicts(scripts)
    raise "Original script archive inventory differs" unless
      scripts.is_a?(Array) && scripts.length == SOURCE_SCRIPT_COUNT
    conflicts = []
    scripts.each_with_index do |entry, index|
      raise "Malformed original script entry #{index}" unless
        entry.is_a?(Array) && entry.length >= 3 && entry[2].is_a?(String)
      begin
        source = Zlib::Inflate.inflate(entry[2])
      rescue Zlib::Error
        raise "Unparseable original script entry #{index}"
      end
      if source.match?(/\\$game_(?:switches|variables)\\s*\\[\\s*(?:991|992)\\s*\\]/)
        conflicts << [index, entry[1].to_s]
      end
    end
    conflicts
  end

  def self.preflight!(project, sprite)
    raise "Invalid private sprite basename" unless /\A[A-Za-z0-9_ -]+\z/.match?(sprite)
    raise "Project directory missing or symlinked" unless project.directory? && !project.symlink?
    marker = project.join("SHATTERED_NATIVE_CANDIDATE.json")
    raise "Not a private compiled candidate" unless marker.file? && !marker.symlink?
    receipt = JSON.parse(marker.read)
    raise "Candidate source commit is unpinned" unless
      receipt["source_sha"].is_a?(String) && /\A[0-9a-f]{40}\z/.match?(receipt["source_sha"])
    script_path = project.join("Data/Scripts.rxdata")
    raise "Original v0.4 Scripts.rxdata differs or is missing" unless
      script_path.file? && !script_path.symlink? &&
      Digest::SHA256.file(script_path).hexdigest == SOURCE_SCRIPTS_SHA
    script_conflicts = original_script_id_conflicts(load_data(script_path.to_s))
    raise "Reserved Route22 IDs collide in original scripts: #{script_conflicts.inspect}" unless
      script_conflicts.empty?
    map_path = project.join("Data/Map016.rxdata")
    raise "Original v0.4 Map016 source SHA differs" unless map_path.file? &&
      !map_path.symlink? && Digest::SHA256.file(map_path).hexdigest == SOURCE_MAP_SHA
    # Gate Map222 transfers to Route22 (30,17), while the Viridian warp is
    # at (32,17). Previous west-side triggers were completely bypassable.
    # Static tile-only reachability is necessary but not gameplay proof.
    route_map = load_data(map_path.to_s)
    viridian = route_map.events[4]
    warp = viridian && viridian.pages.first.list.find { |command| command.code == 201 }
    raise "Reviewed Viridian warp differs" unless viridian &&
      [viridian.x, viridian.y] == [32, 17] &&
      warp && warp.parameters == [0, 10, 25, 20, 2, 0]
    tilesets_path = project.join("Data/Tilesets.rxdata")
    raise "Missing or unsafe native tilesets" unless tilesets_path.file? &&
      !tilesets_path.symlink?
    tilesets = load_data(tilesets_path.to_s)
    [[30, 17], [24, 17]].each do |entry|
      cutline = ShatteredNativeAudit.cutline_report(
        route_map, tilesets, entry: entry, exit_point: [32, 17],
        triggers: config(sprite)["event_positions"]["triggers"]
      )
      raise "Route22 encounter can be bypassed from #{entry.inspect}" unless
        cutline["static_cutline_candidate"] == true
    end
    raise "Missing local Rattata sheet" unless
      project.join("Graphics/Characters/#{sprite}.png").file?
    system = load_data(project.join("Data/System.rxdata").to_s)
    names = [system.instance_variable_get(:@switches), system.instance_variable_get(:@variables)]
    raise "Missing native System switch/variable tables" unless names.all? { |v| v.is_a?(Array) }
    raise "Reserved ID already named" unless
      SWITCHES.all? { |id| names[0][id].to_s.strip.empty? } &&
      names[1][VARIABLE].to_s.strip.empty?
    paths = Dir.glob(project.join("Data/Map[0-9][0-9][0-9].rxdata").to_s)
    raise "Native map inventory missing" if paths.empty?
    paths.each do |path|
      raise "Unsafe map file #{path}" if File.symlink?(path) || File.size(path) > 30 * 1024 * 1024
      map = load_data(path)
      next unless map.is_a?(RPG::Map)
      conflicts = event_id_conflicts(map)
      raise "Reserved Route22 switch/variable collides in #{File.basename(path)}: #{conflicts.inspect}" unless conflicts.empty?
    end
    receipt
  end

  def self.install(project, sprite: "Rattata", report_path: nil)
    project = Pathname(project).expand_path
    receipt = preflight!(project, sprite)
    original_system = Digest::SHA256.file(project.join("Data/System.rxdata")).hexdigest
    original_tilesets = Digest::SHA256.file(project.join("Data/Tilesets.rxdata")).hexdigest
    result = nil
    Dir.chdir(project) do
      load File.join(ROOT, "essentials/Plugins/Shattered Route22/001_Route22.rb")
      load File.join(ROOT, "essentials/Plugins/Shattered Route22/002_Install.rb")
      result = ShatteredRoute22.install(config(sprite))
      map = load_data("Data/Map016.rxdata")
      events = map.events.values.select { |e| e.name.start_with?("SHATTERED_ROUTE22:") }
      raise "Native Route22 event count differs" unless events.length == 6
      raise "Legacy autorun still active" unless
        map.events[3].name == "SHATTERED_LEGACY_ROUTE22_DISABLED"
      raise "Native RMXP Marshal roundtrip differs" unless
        Marshal.dump(map) == File.binread("Data/Map016.rxdata")
    end
    raise "System.rxdata changed" unless
      Digest::SHA256.file(project.join("Data/System.rxdata")).hexdigest == original_system
    raise "Tilesets.rxdata changed" unless
      Digest::SHA256.file(project.join("Data/Tilesets.rxdata")).hexdigest == original_tilesets
    output = {
      "kind" => "private_native_route22_install_not_runtime_acceptance",
      "source_sha" => receipt["source_sha"],
      "source_map_sha256" => SOURCE_MAP_SHA,
      "original_scripts_sha256" => SOURCE_SCRIPTS_SHA,
      "original_script_count_checked" => SOURCE_SCRIPT_COUNT,
      "installed_map_sha256" => Digest::SHA256.file(project.join("Data/Map016.rxdata")).hexdigest,
      "installed" => result["installed"], "switch_ids" => SWITCHES,
      "outcome_variable" => VARIABLE, "native_map_serialization_verified" => true,
      "static_cutline_from_gate_and_hns_entry_verified" => true,
      "runtime_verified" => false, "save_reload_verified" => false,
      "android_verified" => false, "artwork_distributable" => false
    }
    if report_path
      path = Pathname(report_path).expand_path
      raise "Refusing to overwrite report" if path.exist? || path.symlink?
      path.write(JSON.pretty_generate(output) + "\n")
    end
    output
  end
end

if $PROGRAM_NAME == __FILE__
  args = { sprite: "Rattata" }
  parser = OptionParser.new do |p|
    p.on("--project DIR") { |value| args[:project] = value }
    p.on("--sprite NAME") { |value| args[:sprite] = value }
    p.on("--report FILE") { |value| args[:report_path] = value }
  end
  parser.parse!
  abort parser.to_s unless args[:project]
  puts JSON.pretty_generate(ShatteredPrivateRoute22.install(args.delete(:project), **args))
end
