# frozen_string_literal: true
# Runtime adapter for private, ROM-extracted gameplay data. The data and art
# are installed only by the hash-gated private builder; this source file never
# contains extracted ROM text or assets.
module ShatteredGameplay
  DATA_PATH = "Data/shattered_gameplay.dat".freeze
  STATE_IVAR = :@shattered_gameplay_state
  module_function

  def data
    @data ||= load_data(DATA_PATH)
  rescue Errno::ENOENT
    # v18 stored curriculum independently. Keeping this fallback makes old
    # saves usable until the next private rebuild emits the combined payload.
    @data ||= load_data("Data/shattered_training.dat")
  rescue Errno::ENOENT
    nil
  end

  def training
    value = data
    value && (value["training"] || value)
  end

  def class_key(value)
    value.to_s.upcase.gsub(/[^A-Z0-9]/, "")
  end

  def class_id_named(value)
    key = class_key(value)
    return nil if key.empty?
    classes.find_index { |record| record && class_key(record["name"]) == key }
  end

  def state(human)
    raise ArgumentError, "HUMAN required" unless defined?(Shattered) && Shattered.human?(human)
    value = human.instance_variable_get(STATE_IVAR)
    unless value.is_a?(Hash)
      # Older saves recorded the six descriptive paths in Core. Convert those
      # names to the matching extracted curriculum record once, so gameplay,
      # stats and later class choices have one persisted authority.
      legacy = human.instance_variable_get(:@shattered_specialisation)
      primary = legacy && legacy[:primary]
      advanced = legacy && legacy[:advanced]
      class_id = class_id_named(advanced) || class_id_named(primary) || 0
      value = { :version => 2, :class_id => class_id,
                :secondary_id => class_id_named(primary), :known => [], :trials => [] }
      human.instance_variable_set(STATE_IVAR, value)
    end
    value[:known] ||= []; value[:trials] ||= []
    raise ArgumentError, "invalid HUMAN gameplay state" unless value[:version] == 2 &&
      value[:class_id].is_a?(Integer) && class_record(value[:class_id]) &&
      (value[:secondary_id].nil? || value[:secondary_id].is_a?(Integer)) &&
      value[:known].is_a?(Array) && value[:trials].is_a?(Array)
    value
  end

  def classes
    training && training["classes"] || []
  end

  def class_record(id)
    classes[id.to_i]
  end

  def class_id_for(human)
    raw = state(human)[:class_id]
    raw.is_a?(Integer) ? raw : 0
  end

  def known?(human, move)
    state(human)[:known].include?(move.to_sym)
  end

  # The private extractor stores the authentic level-up table as
  # [level, source_id, display_name] tuples under "moves". Earlier adapter
  # code expected an abandoned "curriculum"/"move_data" schema, which meant
  # an otherwise valid private payload could never grant study progress or
  # satisfy a specialisation requirement. Keep the conversion here, at the
  # trust boundary, rather than duplicating ROM data in source.
  def curriculum_entries(record)
    Array(record && (record["moves"] || record["curriculum"])).filter_map do |entry|
      next unless entry.is_a?(Array) && entry.length >= 2 && entry[0].to_i.between?(1, 100)
      name = entry[2] || entry[1]
      id = move_id(name)
      next unless id
      { :level => entry[0].to_i, :id => id }
    end
  end

  def move_id(value)
    text = value.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    text.empty? ? nil : text.to_sym
  end

  def unlock!(human, move)
    value = state(human); move = move.to_sym
    value[:known] << move unless value[:known].include?(move)
    move
  end

  def study!(human)
    raise ArgumentError, "HUMAN must be level 20" unless human.level.to_i >= 20
    record = class_record(class_id_for(human))
    return [] unless record
    curriculum_entries(record).select { |entry| entry[:level] <= human.level.to_i }
                              .map { |entry| unlock!(human, entry[:id]) }
  end

  def primary_choices(human)
    return [] unless human.level.to_i >= 30 && class_id_for(human) == 0
    discipline_ids - [0]
  end

  # The authenticated curriculum contains one base HUMAN record, 17 single
  # disciplines and 153 pair records. It does not carry synthetic path_a or
  # path_b fields. Derive the tree from those source type pairs so advancing
  # remains correct for every recovered discipline, including combinations
  # with base HUMAN itself.
  def discipline_ids
    classes.each_with_index.filter_map do |record, id|
      types = Array(record && record["types"])
      id if id <= 17 && types.length == 2 && types[0].to_i == 9 &&
        (id == 0 || types[1].to_i != 9)
    end
  end

  def discipline_type(id)
    record = class_record(id)
    types = Array(record && record["types"])
    types.length == 2 ? types[1].to_i : nil
  end

  def combined_class_id(first, second)
    first_type = discipline_type(first)
    second_type = discipline_type(second)
    return nil if first_type.nil? || second_type.nil? || first_type == second_type
    wanted = [first_type, second_type].sort
    classes.each_with_index.find do |record, id|
      next false if discipline_ids.include?(id)
      Array(record && record["types"]).map(&:to_i).sort == wanted
    end&.last
  end

  def trial_won?(human, path, advanced = false)
    state(human)[:trials].include?([path.to_i, !!advanced])
  end

  def record_trial!(human, path, advanced = false)
    entry = [path.to_i, !!advanced]
    state(human)[:trials] << entry unless trial_won?(human, path, advanced)
    true
  end

  def qualifying_moves(human, path)
    record = class_record(path)
    return [] unless record
    type = Array(record["types"])[1]
    state(human)[:known].select { |move| move_type_id(move) == type }
  end

  # Essentials' move registry is authoritative for elemental typing. The ROM
  # curriculum carries source move IDs/names, but not a second conflicting
  # type chart. Unknown or modded moves simply do not qualify.
  def move_type_id(move)
    return nil unless defined?(GameData::Move)
    entry = if GameData::Move.respond_to?(:try_get)
              GameData::Move.try_get(move)
            elsif GameData::Move.respond_to?(:get)
              GameData::Move.get(move)
            end
    return nil unless entry
    value = entry.respond_to?(:type) ? entry.type : nil
    value.respond_to?(:id) ? value.id : value
  rescue StandardError
    nil
  end

  def can_choose_primary?(human, path)
    primary_choices(human).include?(path.to_i) && trial_won?(human, path) &&
      qualifying_moves(human, path).length >= 2
  end

  def choose_primary!(human, path)
    path = path.to_i
    raise ArgumentError, "primary path requirements not met" unless can_choose_primary?(human, path)
    state(human)[:class_id] = path
    human.calc_stats if human.respond_to?(:calc_stats)
    path
  end

  # Event-facing selection, intentionally separate from the rules methods
  # above.  Maps can call this directly at a trainer or trial NPC without
  # carrying a cached class id in switches.  Cancelling leaves the save state
  # untouched, and requirements are rechecked immediately before the commit.
  def choose_primary_interactive!(human)
    options = primary_choices(human)
    return false if options.empty? || !defined?(pbShowCommands)
    labels = options.map do |id|
      record = class_record(id) || {}
      record["name"].to_s.empty? ? "Path #{id}" : record["name"].to_s
    end
    selection = pbShowCommands(nil, labels, -1)
    return false unless selection.is_a?(Integer) && selection.between?(0, options.length - 1)
    choose_primary!(human, options[selection])
  rescue ArgumentError
    false
  end

  def advanced_choices(human)
    return [] unless human.level.to_i >= 55
    current = class_id_for(human)
    return [] unless primary_choices_for_level(human).include?(current)
    discipline_ids - [current]
  end

  def primary_choices_for_level(human)
    human.level.to_i >= 30 ? discipline_ids - [0] : []
  end

  def choose_advanced!(human, path)
    path = path.to_i
    raise ArgumentError, "advanced path requirements not met" unless advanced_choices(human).include?(path) &&
      trial_won?(human, path, true) && qualifying_moves(human, path).length >= 2
    primary = class_id_for(human)
    target = combined_class_id(primary, path)
    raise ArgumentError, "missing combined class" unless target
    state(human)[:class_id] = target; state(human)[:secondary_id] = path
    human.calc_stats if human.respond_to?(:calc_stats)
    target
  end

  def choose_advanced_interactive!(human)
    options = advanced_choices(human)
    return false if options.empty? || !defined?(pbShowCommands)
    labels = options.map do |id|
      record = class_record(id) || {}
      record["name"].to_s.empty? ? "Path #{id}" : record["name"].to_s
    end
    selection = pbShowCommands(nil, labels, -1)
    return false unless selection.is_a?(Integer) && selection.between?(0, options.length - 1)
    choose_advanced!(human, options[selection])
  rescue ArgumentError
    false
  end

  def mount_sheet(pokemon)
    return nil unless pokemon && data && data["mounts"]
    entry = data["mounts"][pokemon.species.to_s]
    entry && (entry["composite"] || entry["sheet"])
  end

  # A private build supplies an already-composited rider/mount character set.
  # Do not substitute an unmounted character sheet: collision and movement
  # remain the native Game_Player implementation and a missing composite is a
  # deliberate fail-closed dismount.
  def reconcile_mount(player = (defined?($game_player) ? $game_player : nil))
    return false unless player && player.respond_to?(:character_name) && player.respond_to?(:character_name=)
    mounted = defined?(ShatteredCompanion) && ShatteredCompanion.mounted?
    if !mounted
      base = player.instance_variable_get(:@shattered_gameplay_base_charset)
      player.character_name = base if base && !base.empty?
      player.remove_instance_variable(:@shattered_gameplay_base_charset) if base
      restore_mount_speed(player)
      return false
    end
    base = player.character_name
    base = player.instance_variable_get(:@shattered_gameplay_base_charset) if base.to_s.start_with?("SHATTERED_RIDE_")
    player.instance_variable_set(:@shattered_gameplay_base_charset, base)
    species = ShatteredCompanion.partner.species.to_s.upcase
    sheet = "SHATTERED_RIDE_#{species}_#{base}"
    return false unless File.file?(File.join("Graphics", "Characters", sheet + ".png"))
    player.character_name = sheet
    apply_mount_speed(player)
    true
  end

  # Movement is deliberately tied to the same private composite gate as the
  # sprite.  A missing rider sheet never grants invisible speed or collision
  # changes.  Essentials clamps movement speed elsewhere; this merely applies
  # one predictable field-speed increment and restores the exact prior value
  # on indoor transfer, dismount, party change and Continue.
  def apply_mount_speed(player)
    return false unless player.respond_to?(:move_speed) && player.respond_to?(:move_speed=)
    return true if player.instance_variable_defined?(:@shattered_gameplay_base_speed)
    base = player.move_speed.to_i
    player.instance_variable_set(:@shattered_gameplay_base_speed, base)
    player.move_speed = [base + 1, 6].min
    true
  end

  def restore_mount_speed(player)
    return false unless player.instance_variable_defined?(:@shattered_gameplay_base_speed)
    base = player.instance_variable_get(:@shattered_gameplay_base_speed)
    player.move_speed = base if player.respond_to?(:move_speed=)
    player.remove_instance_variable(:@shattered_gameplay_base_speed)
    true
  end
end

if defined?(Game_Player) && Game_Player.method_defined?(:set_movement_type) &&
   !Game_Player.method_defined?(:shattered_gameplay_set_movement_type)
  class Game_Player
    alias shattered_gameplay_set_movement_type set_movement_type
    def set_movement_type(*args)
      result = shattered_gameplay_set_movement_type(*args)
      ShatteredGameplay.reconcile_mount(self)
      result
    end
  end
end

# The class record is authoritative whenever the private curriculum is present.
# It leaves every non-HUMAN species on Essentials' normal data path.
if defined?(Pokemon)
  class Pokemon
    unless method_defined?(:shattered_gameplay_base_stats)
      alias shattered_gameplay_base_stats baseStats if method_defined?(:baseStats)
      alias shattered_gameplay_types types if method_defined?(:types)
      alias shattered_gameplay_ability_id ability_id if method_defined?(:ability_id)

      def shattered_gameplay_record
        return nil unless defined?(Shattered) && Shattered.human?(self)
        ShatteredGameplay.class_record(ShatteredGameplay.class_id_for(self))
      rescue StandardError
        nil
      end

      def baseStats
        record = shattered_gameplay_record
        return record["stats"] if record && record["stats"].is_a?(Array)
        return shattered_gameplay_base_stats if respond_to?(:shattered_gameplay_base_stats)
        nil
      end

      def types
        record = shattered_gameplay_record
        if record && record["types"].is_a?(Array) && defined?(GameData::Type)
          return record["types"].map { |type| GameData::Type.get(type).id }
        end
        return shattered_gameplay_types if respond_to?(:shattered_gameplay_types)
        []
      end

      def ability_id
        record = shattered_gameplay_record
        passive = record && Array(record["passives"]).first
        return passive.to_sym if passive && passive != "NONE" && passive != "None"
        return shattered_gameplay_ability_id if respond_to?(:shattered_gameplay_ability_id)
        nil
      end
    end
  end
end

if defined?(EventHandlers)
  EventHandlers.add(:on_game_map_setup, :shattered_gameplay_mount, proc { |*_| ShatteredGameplay.reconcile_mount })
  EventHandlers.add(:on_map_or_spriteset_change, :shattered_gameplay_mount_continue, proc { |*_| ShatteredGameplay.reconcile_mount })
end
