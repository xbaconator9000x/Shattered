# frozen_string_literal: true
# Shattered Raid v0.1 — Pokémon Essentials 21.1.
require "digest/sha2"
require "thread"

module ShatteredRaid
  STATE_VERSION = 1
  ENCOUNTER_COUNT = 3
  OUTCOME_WON = 1
  DIRECTIONS = [2, 4, 6, 8].freeze
  EVENT_PREFIX = "ShatteredRaid:BEEDRILL:"
  SOURCE_MAP_WIDTH = 48
  SOURCE_MAP_HEIGHT = 40
  BATTLE_GUARD = Mutex.new
  INSTALL_GUARD = Mutex.new

  class DependencyError < StandardError; end
  class ConfigurationError < StandardError; end
  class InstallationError < StandardError; end

  class << self
    def state(store = defined?($PokemonGlobal) ? $PokemonGlobal : nil)
      raise DependencyError, "PokemonGlobal metadata unavailable" unless store
      value = store.instance_variable_get(:@shattered_raid_state)
      return write_state(store, 0) if value.nil?
      unless value.is_a?(Hash) && value["version"] == STATE_VERSION &&
             value["progression"].is_a?(Integer) &&
             value["progression"].between?(0, ENCOUNTER_COUNT) &&
             [true, false].include?(value["completed"]) &&
             value["completed"] == (value["progression"] == ENCOUNTER_COUNT) &&
             (value["map_id"].nil? || (value["map_id"].is_a?(Integer) && value["map_id"] > 0)) &&
             (value["map_id"].nil? == value["switch_ids"].nil?) &&
             (value["switch_ids"].nil? ||
               (value["switch_ids"].is_a?(Array) && value["switch_ids"].length == ENCOUNTER_COUNT &&
                value["switch_ids"].all? { |id| id.is_a?(Integer) && id > 0 } &&
                value["switch_ids"].uniq.length == ENCOUNTER_COUNT))
        raise ConfigurationError, "invalid or unsupported saved raid state"
      end
      value
    end

    def progression(store = defined?($PokemonGlobal) ? $PokemonGlobal : nil)
      state(store)["progression"]
    end

    def trigger(index, config)
      index = Integer(index)
      runtime_config = validate_runtime_config(config)
      return false unless index.between?(0, ENCOUNTER_COUNT - 1)
      acquired = false
      BATTLE_GUARD.synchronize do
        return false if @battle_active
        @battle_active = true
        acquired = true
      end
      begin
        validate_runtime_dependencies!
        current_state = state
        sync_map_state(runtime_config, current_state)
        return false if current_state["completed"] || current_state["progression"] != index
        $game_variables[runtime_config["outcome_variable_id"]] = 0
        self.send(:setBattleRule, "disablePokeBalls")
        self.send(:setBattleRule, "outcome", runtime_config["outcome_variable_id"])
        WildBattle.start(:BEEDRILL, runtime_config["events"][index]["level"])
        return false unless $game_variables[runtime_config["outcome_variable_id"]] == OUTCOME_WON
        new_state = write_state(nil, current_state["progression"] + 1)
        sync_map_state(runtime_config, new_state)
        true
      ensure
        BATTLE_GUARD.synchronize { @battle_active = false } if acquired
      end
    rescue DependencyError
      false
    end

    def sync_saved_state(config)
      runtime_config = validate_runtime_config(config)
      sync_map_state(runtime_config, state)
    end

    def sync_saved_state_for_map(map_id)
      return false unless defined?($PokemonGlobal) && $PokemonGlobal &&
                          defined?($game_switches) && $game_switches
      saved_state = state
      return false unless saved_state["map_id"] == map_id && saved_state["switch_ids"]
      saved_state["switch_ids"].each_with_index do |switch_id, index|
        $game_switches[switch_id] = index < saved_state["progression"]
      end
      true
    end

    def install_staged(project_root, config, passability, failure_hook = nil)
      acquired = false
      INSTALL_GUARD.synchronize do
        raise InstallationError, "installer already active" if @install_active
        @install_active = true
        acquired = true
      end
      begin
        install_staged_map(project_root, config, passability, failure_hook)
      ensure
        INSTALL_GUARD.synchronize { @install_active = false } if acquired
      end
    end

    private

    def write_state(store, progression)
      store ||= defined?($PokemonGlobal) ? $PokemonGlobal : nil
      raise DependencyError, "PokemonGlobal metadata unavailable" unless store
      value = {
        "version" => STATE_VERSION,
        "progression" => progression,
        "completed" => progression == ENCOUNTER_COUNT,
        "map_id" => nil,
        "switch_ids" => nil
      }
      previous = store.instance_variable_get(:@shattered_raid_state)
      if previous.is_a?(Hash) && previous["version"] == STATE_VERSION
        value["map_id"] = previous["map_id"]
        value["switch_ids"] = previous["switch_ids"]
      end
      store.instance_variable_set(:@shattered_raid_state, value)
      value
    end

    def validate_runtime_dependencies!
      unless defined?(Shattered) && Shattered.respond_to?(:human?) &&
             defined?(GameData::Species) && GameData::Species.respond_to?(:exists?) &&
             GameData::Species.exists?(:HUMAN) && GameData::Species.exists?(:BEEDRILL) &&
             defined?(WildBattle) && WildBattle.respond_to?(:start) &&
             respond_to?(:setBattleRule, true)
        raise DependencyError, "compiled HUMAN, BEEDRILL, Shattered Core and WildBattle are required"
      end
      unless defined?($player) && $player && $player.respond_to?(:party) &&
             $player.party.any? { |pokemon| Shattered.human?(pokemon) }
        raise DependencyError, "a genuine HUMAN party member is required"
      end
      unless defined?($game_variables) && $game_variables &&
             defined?($game_switches) && $game_switches
        raise DependencyError, "Essentials game variables and switches are required"
      end
    end

    def validate_runtime_config(config)
      unless config.is_a?(Hash) && config["map_id"].is_a?(Integer) &&
             config["outcome_variable_id"].is_a?(Integer) &&
             config["outcome_variable_id"] > 0 &&
             config["events"].is_a?(Array) && config["events"].length == ENCOUNTER_COUNT
        raise ConfigurationError, "invalid raid runtime configuration"
      end
      if defined?($game_map) && $game_map && $game_map.respond_to?(:map_id) &&
         $game_map.map_id != config["map_id"]
        raise ConfigurationError, "raid event is running on the wrong map"
      end
      seen_switches = []
      config["events"].each_with_index do |entry, index|
        unless entry.is_a?(Hash) && entry["index"] == index &&
               entry["level"].is_a?(Integer) && entry["level"].between?(1, 100) &&
               entry["switch_id"].is_a?(Integer) && entry["switch_id"] > 0
          raise ConfigurationError, "invalid encounter runtime configuration"
        end
        raise ConfigurationError, "duplicate encounter switch" if seen_switches.include?(entry["switch_id"])
        seen_switches << entry["switch_id"]
      end
      config
    end

    def sync_map_state(config, saved_state)
      switch_ids = config["events"].map { |entry| entry["switch_id"] }
      if saved_state["map_id"] && saved_state["map_id"] != config["map_id"]
        raise ConfigurationError, "saved raid belongs to a different map"
      end
      if saved_state["switch_ids"] && saved_state["switch_ids"] != switch_ids
        raise ConfigurationError, "saved raid switch configuration has changed"
      end
      saved_state = saved_state.dup
      saved_state["map_id"] = config["map_id"]
      saved_state["switch_ids"] = switch_ids
      $PokemonGlobal.instance_variable_set(:@shattered_raid_state, saved_state)
      config["events"].each_with_index do |entry, index|
        $game_switches[entry["switch_id"]] = index < saved_state["progression"]
      end
    end

    def install_staged_map(project_root, config, passability, failure_hook)
      config = validate_install_config(config)
      raise InstallationError, "a passability checker is required" unless passability.respond_to?(:call)
      root = File.expand_path(project_root)
      marker = File.join(root, "SHATTERED_STAGING_REPORT.json")
      raise InstallationError, "installer only supports a staged Shattered project" unless File.file?(marker)
      marker_text = read_file(marker)
      raise InstallationError, "staging report is not for Essentials 21.1" unless marker_text.include?('"engine": "Essentials 21.1"')
      core = File.join(root, "Plugins", "Shattered Core", "001_Core.rb")
      raise InstallationError, "staged Shattered Core plugin is missing" unless File.file?(core)
      map_path = File.join(root, "Data", "Map#{format_map_id(config["map_id"])}.rxdata")
      unless File.file?(map_path) && !File.symlink?(map_path) && !File.symlink?(File.join(root, "Data")) &&
             File.expand_path(map_path).index(root + File::SEPARATOR) == 0
        raise InstallationError, "target native map is missing"
      end
      backup_path = map_path + ".shattered-raid.bak"
      temp_path = map_path + ".shattered-raid.tmp"
      rollback_path = map_path + ".shattered-raid.rollback"
      backup_temp_path = backup_path + ".tmp"
      raise InstallationError, "stale installer temporary file exists" if path_exists?(temp_path)
      raise InstallationError, "stale installer rollback file exists" if path_exists?(rollback_path)
      raise InstallationError, "stale backup temporary file exists" if path_exists?(backup_temp_path)
      raise InstallationError, "installer backup must not be a symlink" if File.symlink?(backup_path)

      original = read_file(map_path)
      expected = config["expected_sha256"]
      original_digest = Digest::SHA256.hexdigest(original)
      if File.exist?(backup_path) && Digest::SHA256.hexdigest(read_file(backup_path)) != expected
        raise InstallationError, "stale installer backup exists"
      end
      if original_digest != expected && !File.exist?(backup_path)
        raise InstallationError, "target map SHA256 is stale or already modified"
      end
      source = original_digest == expected ? original : read_file(backup_path)
      map = Marshal.load(source)
      validate_native_map!(map, config)
      preflight_events!(map, config, root, passability)
      install_native_events!(map, config)
      replacement = Marshal.dump(map)
      if original_digest != expected
        if Digest::SHA256.hexdigest(replacement) == original_digest
          return :already_installed
        end
        raise InstallationError, "target map SHA256 is stale or already modified"
      end

      backup_created = false
      target_moved = false
      backup_temp_identity = nil
      temp_identity = nil
      begin
        unless File.exist?(backup_path)
          backup_temp_identity = write_file(backup_temp_path, original)
          raise InstallationError, "backup temporary file changed" unless owned_file?(backup_temp_path, backup_temp_identity)
          File.rename(backup_temp_path, backup_path)
          backup_temp_identity = nil
          backup_created = true
        end
        failure_hook.call(:after_backup) if failure_hook
        temp_identity = write_file(temp_path, replacement)
        raise InstallationError, "installer temporary file changed" unless owned_file?(temp_path, temp_identity)
        File.rename(map_path, rollback_path)
        target_moved = true
        raise InstallationError, "installer temporary file changed" unless owned_file?(temp_path, temp_identity)
        File.rename(temp_path, map_path)
        temp_identity = nil
        failure_hook.call(:after_replace) if failure_hook
        File.delete(rollback_path)
        :installed
      rescue Exception
        if target_moved && File.exist?(rollback_path)
          File.delete(map_path) if File.exist?(map_path)
          File.rename(rollback_path, map_path)
        end
        delete_owned_file(temp_path, temp_identity)
        File.delete(backup_path) if backup_created && File.exist?(backup_path)
        delete_owned_file(backup_temp_path, backup_temp_identity)
        raise
      end
    ensure
      delete_owned_file(temp_path, temp_identity) if temp_path
    end

    def validate_install_config(config)
      unless config.is_a?(Hash) && config["reviewed"] == true &&
             config["switches_reviewed"] == true && config["outcome_variable_reviewed"] == true &&
             config["map_id"].is_a?(Integer) && config["map_id"] > 0 &&
             config["expected_sha256"].is_a?(String) &&
             config["expected_sha256"] =~ /\A[0-9a-f]{64}\z/ &&
             config["width"] == SOURCE_MAP_WIDTH && config["height"] == SOURCE_MAP_HEIGHT &&
             config["outcome_variable_id"].is_a?(Integer) && config["outcome_variable_id"] > 0 &&
             config["events"].is_a?(Array) && config["events"].length == ENCOUNTER_COUNT
        raise ConfigurationError, "installation requires a reviewed 48x40 map configuration"
      end
      switches = []
      anchors = []
      config["events"].each_with_index do |entry, index|
        unless entry.is_a?(Hash) && entry["index"] == index &&
               entry["role"] == "beedrill_threat_#{index + 1}" &&
               entry["role_reviewed"] == true && entry["source_anchor_reviewed"] == true &&
               entry["source_anchor_event_id"].is_a?(Integer) && entry["source_anchor_event_id"] > 0 &&
               entry["x"].is_a?(Integer) && entry["y"].is_a?(Integer) &&
               entry["x"].between?(0, SOURCE_MAP_WIDTH - 1) &&
               entry["y"].between?(0, SOURCE_MAP_HEIGHT - 1) &&
               entry["level"].is_a?(Integer) && entry["level"].between?(1, 100) &&
               entry["switch_id"].is_a?(Integer) && entry["switch_id"] > 0 &&
               entry["sprite_name"].is_a?(String) &&
               entry["sprite_name"] =~ /\A[A-Za-z0-9_-]+\z/ &&
               entry["sprite_hue"].is_a?(Integer) && entry["sprite_hue"].between?(0, 360)
          raise ConfigurationError, "encounter #{index + 1} needs reviewed role and source anchor data"
        end
        raise ConfigurationError, "duplicate source anchor" if anchors.include?(entry["source_anchor_event_id"])
        raise ConfigurationError, "duplicate encounter switch" if switches.include?(entry["switch_id"])
        anchors << entry["source_anchor_event_id"]
        switches << entry["switch_id"]
      end
      config
    end

    def validate_native_map!(map, config)
      unless defined?(RPG::Map) && map.is_a?(RPG::Map) &&
             map.width == config["width"] && map.height == config["height"] &&
             map.events.is_a?(Hash)
        raise InstallationError, "native map dimensions or data do not match reviewed configuration"
      end
      config["events"].each do |entry|
        unless map.events[entry["source_anchor_event_id"]]
          raise InstallationError, "reviewed source anchor is missing from native map"
        end
      end
    end

    def preflight_events!(map, config, root, passability)
      positions = []
      config["events"].each do |entry|
        point = [entry["x"], entry["y"]]
        raise InstallationError, "duplicate event placement" if positions.include?(point)
        positions << point
        if map.events.values.any? { |event| event.x == point[0] && event.y == point[1] }
          raise InstallationError, "event placement is occupied"
        end
        sprite = File.join(root, "Graphics", "Characters", entry["sprite_name"] + ".png")
        raise InstallationError, "reviewed event sprite is missing" unless File.file?(sprite)
        DIRECTIONS.each do |direction|
          unless passability.call(map, point[0], point[1], direction)
            raise InstallationError, "event placement is blocked"
          end
        end
      end
    end

    def install_native_events!(map, config)
      config["events"].each do |entry|
        event_id = (map.events.keys.max || 0) + 1
        event = RPG::Event.new(entry["x"], entry["y"])
        event.id = event_id
        event.name = EVENT_PREFIX + entry["index"].to_s
        event.pages = [active_page(entry, config), defeated_page(entry["switch_id"])]
        map.events[event_id] = event
      end
    end

    def active_page(entry, config)
      page = RPG::Event::Page.new
      page.graphic.character_name = entry["sprite_name"]
      page.graphic.character_hue = entry["sprite_hue"]
      page.trigger = 0
      page.through = false
      page.always_on_top = false
      page.list = [
        RPG::EventCommand.new(355, 0, [runtime_script(entry["index"], config)]),
        RPG::EventCommand.new(0, 0, [])
      ]
      page
    end

    def defeated_page(switch_id)
      page = RPG::Event::Page.new
      page.condition.switch1_valid = true
      page.condition.switch1_id = switch_id
      page.graphic.character_name = ""
      page.trigger = 0
      page.through = true
      page.always_on_top = false
      page.list = [RPG::EventCommand.new(0, 0, [])]
      page
    end

    def runtime_script(index, config)
      runtime = {
        "map_id" => config["map_id"],
        "outcome_variable_id" => config["outcome_variable_id"],
        "events" => config["events"].map do |entry|
          { "index" => entry["index"], "level" => entry["level"], "switch_id" => entry["switch_id"] }
        end
      }
      "ShatteredRaid.trigger(#{index}, #{runtime.inspect})"
    end

    def format_map_id(map_id)
      ("%03d" % map_id)
    end

    def read_file(path)
      File.open(path, "rb") { |file| file.read }
    end

    def write_file(path, content)
      identity = nil
      flags = File::WRONLY | File::CREAT | File::EXCL
      flags |= File::BINARY if defined?(File::BINARY)
      File.open(path, flags, 0600) do |file|
        stat = file.stat
        identity = [stat.dev, stat.ino]
        file.write(content)
        file.flush
      end
      identity
    rescue Exception
      delete_owned_file(path, identity)
      raise
    end

    def path_exists?(path)
      File.exist?(path) || File.symlink?(path)
    end

    def owned_file?(path, identity)
      return false unless identity && File.exist?(path) && !File.symlink?(path)
      stat = File.lstat(path)
      [stat.dev, stat.ino] == identity
    end

    def delete_owned_file(path, identity)
      File.delete(path) if owned_file?(path, identity)
    end

  end
end

if defined?(EventHandlers)
  EventHandlers.add(:on_game_map_setup, :shattered_raid_switch_sync,
    proc { |map_id, _map, _tileset| ShatteredRaid.sync_saved_state_for_map(map_id) })
end
