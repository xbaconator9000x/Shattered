# frozen_string_literal: true

module ShatteredEquipment
  SLOT_IDS = [:head, :torso, :left_hand, :right_hand, :legs, :feet].freeze
  SAVE_VERSION = 1
  SAVE_IVAR = :@shattered_equipment
  DEFAULT_GEAR_RULES = {
    :KNIFE => { :slot => :right_hand, :move => :SLASH, :two_handed => false }.freeze,
    :BRAZIER => { :slot => :left_hand, :move => :EMBER, :two_handed => false }.freeze,
    :SLING => { :slot => :left_hand, :move => :ROCKTHROW, :two_handed => true }.freeze,
    :SPRAYGUN => { :slot => :right_hand, :move => :BUBBLE, :two_handed => false }.freeze,
    :BUCKLER => { :slot => :left_hand, :move => :DEFENSECURL, :two_handed => false }.freeze
  }.freeze

  @gear_rules = DEFAULT_GEAR_RULES.dup
  @runtime_hook_status = :unavailable

  class << self
    attr_reader :runtime_hook_status

    def slots
      SLOT_IDS.dup
    end

    def register_gear(item_id, slot, move_id = nil, two_handed = false)
      return false unless SLOT_IDS.include?(slot)
      return false unless two_handed == false || [:left_hand, :right_hand].include?(slot)
      item = native_item(item_id)
      return false unless item
      return false if @gear_rules.key?(item.id)
      return false unless move_id.nil? || valid_granted_move?(move_id)
      return false unless two_handed == true || two_handed == false

      @gear_rules[item.id] = {
        :slot => slot,
        :move => move_id,
        :two_handed => two_handed
      }.freeze
      true
    end

    def equip(human, item_id)
      return false unless human?(human)
      item = native_item(item_id)
      return false unless item
      rule = @gear_rules[item.id]
      return false unless rule && valid_gear_rule?(item.id, rule)

      current = equipment(human)
      conflicts = current.values.compact.uniq.select do |equipped_id|
        (occupied_slots(@gear_rules[equipped_id]) & occupied_slots(rule)).any?
      end
      replaceable = conflicts.all? do |equipped_id|
        @gear_rules[equipped_id][:slot] == rule[:slot]
      end
      return false unless replaceable

      conflicts.each { |equipped_id| current.delete_if { |_slot, value| value == equipped_id } }
      current[rule[:slot]] = item.id
      return false unless within_move_limit?(current)
      save_equipment(human, current)
      true
    end

    def unequip(human, slot)
      return false unless human?(human) && SLOT_IDS.include?(slot)
      current = equipment(human)
      item_id = current.values.compact.uniq.find do |equipped_id|
        occupied_slots(@gear_rules[equipped_id]).include?(slot)
      end
      return false unless item_id

      current.delete_if { |_slot, value| value == item_id }
      save_equipment(human, current)
      true
    end

    def equipment(human)
      return nil unless human?(human)
      raw = human.instance_variable_get(SAVE_IVAR)
      slots = empty_slots
      return slots unless raw.is_a?(Hash) && raw[:version] == SAVE_VERSION && raw[:slots].is_a?(Hash)

      occupied = []
      seen = []
      SLOT_IDS.each do |slot|
        item_id = raw[:slots][slot]
        next unless item_id.is_a?(Symbol)
        rule = @gear_rules[item_id]
        next unless rule && rule[:slot] == slot && valid_gear_rule?(item_id, rule)
        next if seen.include?(item_id)
        required_slots = occupied_slots(rule)
        next if (occupied & required_slots).any?

        slots[slot] = item_id
        seen << item_id
        occupied.concat(required_slots)
      end
      save_equipment(human, slots) if slots != raw[:slots]
      slots
    end

    def equipped_item(human, slot)
      return nil unless SLOT_IDS.include?(slot)
      current = equipment(human)
      return nil unless current
      current.values.compact.uniq.find do |item_id|
        occupied_slots(@gear_rules[item_id]).include?(slot)
      end
    end

    def granted_move_ids(human)
      return [] unless human?(human)
      current = equipment(human)
      return [] unless current
      move_ids_for_slots(current)
    end

    def move_ids_for_slots(slots)
      slots.values.compact.uniq.each_with_object([]) do |item_id, result|
        rule = @gear_rules[item_id]
        next unless rule && rule[:move] && valid_gear_rule?(item_id, rule)
        result << rule[:move] unless result.include?(rule[:move])
      end
    end

    def within_move_limit?(slots)
      return true if move_ids_for_slots(slots).empty?
      defined?(Pokemon::MAX_MOVES) && move_ids_for_slots(slots).length <= Pokemon::MAX_MOVES
    end

    def add_battle_moves(battler, human)
      return false unless human?(human) && battler.respond_to?(:moves) && battler.moves.is_a?(Array)
      return false unless core_battle_hooks_ready?
      return false unless defined?(Pokemon::Move) && defined?(Pokemon::MAX_MOVES) &&
                          defined?(Battle::Move) &&
                          Battle::Move.respond_to?(:from_pokemon_move) &&
                          battler.respond_to?(:battle)

      granted = granted_move_ids(human)
      return false if granted.length > Pokemon::MAX_MOVES || battler.moves.length > Pokemon::MAX_MOVES
      pending = granted.reject do |move_id|
        battler.moves.any? { |move| move.respond_to?(:id) && move.id == move_id }
      end.map do |move_id|
        pokemon_move = Pokemon::Move.new(move_id)
        Battle::Move.from_pokemon_move(battler.battle, pokemon_move)
      end
      return false if pending.any?(&:nil?)

      while battler.moves.length + pending.length > Pokemon::MAX_MOVES
        index = battler.moves.rindex do |move|
          !move.respond_to?(:id) || !granted.include?(move.id)
        end
        return false unless index
        battler.moves.delete_at(index)
      end
      battler.moves.concat(pending)
      true
    rescue ArgumentError, TypeError, KeyError
      false
    end

    def install_battle_hook(battler_class = nil)
      battler_class ||= Battle::Battler if defined?(Battle::Battler)
      unless core_stamina_api_available? && battler_class &&
             battler_class.method_defined?(:pbInitPokemon) &&
             battler_class.method_defined?(:moves)
        @runtime_hook_status = :unavailable
        return false
      end
      if battler_class.method_defined?(:shattered_equipment_original_pb_init_pokemon)
        @runtime_hook_status = :installed
        return true
      end

      battler_class.class_eval do
        alias_method :shattered_equipment_original_pb_init_pokemon, :pbInitPokemon

        def pbInitPokemon(pokemon, party_index)
          result = shattered_equipment_original_pb_init_pokemon(pokemon, party_index)
          ShatteredEquipment.add_battle_moves(self, pokemon)
          result
        end
      end
      @runtime_hook_status = :installed
      true
    end

    def install_runtime_hooks
      install_battle_hook
      if defined?(EventHandlers)
        EventHandlers.add(:on_start_battle, :shattered_equipment_battle_hook,
                          proc { |*args| install_battle_hook })
      end
      @runtime_hook_status == :installed
    end

    private

    def human?(pokemon)
      defined?(Shattered) && Shattered.respond_to?(:human?) && Shattered.human?(pokemon)
    end

    def core_stamina_api_available?
      defined?(Shattered) &&
        Shattered.respond_to?(:stamina_cost) &&
        Shattered.respond_to?(:can_spend_stamina?) &&
        Shattered.respond_to?(:spend_stamina) &&
        Shattered.respond_to?(:install_battle_hooks)
    end

    def core_battle_hooks_ready?
      return false unless core_stamina_api_available?
      return false unless Shattered.install_battle_hooks
      return false unless defined?(Battle::Battler)
      Battle::Battler.method_defined?(:shattered_core_original_pb_can_choose_move) &&
        Battle::Battler.method_defined?(:shattered_core_original_pb_try_use_move)
    end

    def native_item(item_id)
      return nil unless defined?(GameData::Item) && GameData::Item.respond_to?(:try_get)
      GameData::Item.try_get(item_id)
    end

    def valid_granted_move?(move_id)
      return false unless move_id.is_a?(Symbol) && defined?(GameData::Move) &&
                          GameData::Move.respond_to?(:exists?) && GameData::Move.exists?(move_id)
      return false unless defined?(Shattered) && Shattered.respond_to?(:stamina_cost)
      cost = Shattered.stamina_cost(move_id)
      cost.is_a?(Numeric) && cost > 0
    end

    def valid_gear_rule?(item_id, rule)
      item = native_item(item_id)
      return false unless item && item.id == item_id
      return false unless SLOT_IDS.include?(rule[:slot])
      return false if rule[:two_handed] && ![:left_hand, :right_hand].include?(rule[:slot])
      rule[:move].nil? || valid_granted_move?(rule[:move])
    end

    def occupied_slots(rule)
      return [] unless rule
      return [:left_hand, :right_hand] if rule[:two_handed]
      [rule[:slot]]
    end

    def empty_slots
      SLOT_IDS.each_with_object({}) { |slot, result| result[slot] = nil }
    end

    def save_equipment(human, slots)
      human.instance_variable_set(SAVE_IVAR, {
        :version => SAVE_VERSION,
        :slots => SLOT_IDS.each_with_object({}) { |slot, result| result[slot] = slots[slot] }
      })
    end
  end
end

ShatteredEquipment.install_runtime_hooks
