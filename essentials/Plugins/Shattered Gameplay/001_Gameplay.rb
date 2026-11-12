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
    nil
  end

  def training
    value = data
    value && value["training"]
  end

  def state(human)
    raise ArgumentError, "HUMAN required" unless defined?(Shattered) && Shattered.human?(human)
    value = human.instance_variable_get(STATE_IVAR)
    unless value.is_a?(Hash)
      # Preserve the old six-path save state rather than silently discarding it.
      legacy = human.instance_variable_get(:@shattered_specialisation)
      value = { :version => 2, :class_id => legacy && legacy[:primary],
                :secondary_id => nil, :known => [], :trials => [] }
      human.instance_variable_set(STATE_IVAR, value)
    end
    value[:known] ||= []; value[:trials] ||= []
    raise ArgumentError, "invalid HUMAN gameplay state" unless value[:version] == 2 &&
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

  def unlock!(human, move)
    value = state(human); move = move.to_sym
    value[:known] << move unless value[:known].include?(move)
    move
  end

  def study!(human)
    raise ArgumentError, "HUMAN must be level 20" unless human.level.to_i >= 20
    record = class_record(class_id_for(human))
    return [] unless record
    Array(record["curriculum"]).map { |entry| unlock!(human, entry[1].to_sym) }
  end

  def primary_choices(human)
    return [] unless human.level.to_i >= 30 && class_id_for(human) == 0
    (1..17).to_a
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
    moves = state(human)[:known]
    record = class_record(path)
    return [] unless record
    type = Array(record["types"])[1]
    moves.select do |move|
      info = training && training["move_data"] && training["move_data"][move.to_s]
      info && info["type"] == type
    end
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

  def advanced_choices(human)
    return [] unless human.level.to_i >= 55
    current = class_record(class_id_for(human)); return [] unless current
    [current["path_a"], current["path_b"]].compact.uniq.map(&:to_i)
  end

  def choose_advanced!(human, path)
    path = path.to_i
    raise ArgumentError, "advanced path requirements not met" unless advanced_choices(human).include?(path) &&
      trial_won?(human, path, true) && qualifying_moves(human, path).length >= 2
    primary = class_id_for(human)
    target = classes.find_index { |r| r && [r["path_a"], r["path_b"]].map(&:to_i).sort == [primary, path].sort }
    raise ArgumentError, "missing combined class" unless target
    state(human)[:class_id] = target; state(human)[:secondary_id] = path
    human.calc_stats if human.respond_to?(:calc_stats)
    target
  end

  def mount_sheet(pokemon)
    return nil unless pokemon && data && data["mounts"]
    entry = data["mounts"][pokemon.species.to_s]
    entry && entry["sheet"]
  end

  # A mount changes field presentation only; collision and movement remain the
  # native Game_Player implementation. A missing private sheet deliberately
  # leaves the player graphic untouched.
  def reconcile_mount(player = (defined?($game_player) ? $game_player : nil))
    return false unless player && defined?(ShatteredCompanion) && ShatteredCompanion.mounted?
    sheet = mount_sheet(ShatteredCompanion.partner)
    return false unless sheet && File.file?(File.join("Graphics", "Characters", sheet + ".png"))
    player.character_name = sheet if player.respond_to?(:character_name=)
    true
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
