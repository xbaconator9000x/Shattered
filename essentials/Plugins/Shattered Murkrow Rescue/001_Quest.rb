# frozen_string_literal: true
# SE-019C: saved Murkrow rescue state and native event flow.
require "json"
require "base64"

module ShatteredMurkrowRescue
  VERSION = 1
  SPECIES = :MURKROW
  STAGES = [:undiscovered, :discovered, :battle_pending, :befriending,
            :recruited, :complete].freeze
  # Essentials v21.1 uses WildBattle/TrainerBattle.start_core for numeric outcomes.
  # The obsolete pbWildBattle/pbTrainerBattle event APIs do not exist in v21.1.
  BATTLE_HOOKS = ["WildBattle.start_core", "TrainerBattle.start_core"].freeze
  ITEM_PATTERN = /\A[A-Z][A-Z0-9_]*\z/
  SYMBOL_PATTERN = /\A[A-Z][A-Z0-9_]*\z/
  STATE_IVAR = :@shattered_murkrow_rescue

  class InvalidState < StandardError; end

  def self.saved_store(store = nil)
    return store if store
    raise "Saved PokemonGlobal is unavailable" unless
      defined?($PokemonGlobal) && $PokemonGlobal
    $PokemonGlobal
  end

  def self.state(store = nil, recover_interrupted = true)
    store = saved_store(store)
    value = store.instance_variable_get(STATE_IVAR)
    unless value
      value = {
        :version => VERSION,
        :stage => :undiscovered,
        :flags => {
          :discovered => false,
          :battle_won => false,
          :murkrow_recruited => false,
          :reward_claimed => false,
          :complete => false
        }
      }
      store.instance_variable_set(STATE_IVAR, value)
    end
    flags = value.is_a?(Hash) ? value[:flags] : nil
    valid = value.is_a?(Hash) && value[:version] == VERSION &&
      STAGES.include?(value[:stage]) && flags.is_a?(Hash) &&
      [:discovered, :battle_won, :murkrow_recruited, :reward_claimed, :complete].all? do |key|
        [true, false].include?(flags[key])
      end
    raise InvalidState, "Unknown Murkrow rescue save data; refusing to reset quest flags" unless valid
    if recover_interrupted && value[:stage] == :battle_pending
      value[:stage] = :discovered
    elsif flags[:reward_claimed]
      value[:stage] = :complete
      flags[:complete] = true
    end
    value
  end

  def self.discover!(store = nil)
    value = state(store)
    return value if value[:stage] == :complete
    value[:flags][:discovered] = true
    value[:stage] = :discovered if value[:stage] == :undiscovered
    value
  end

  def self.begin_battle!(store = nil)
    value = state(store)
    return false unless value[:stage] == :discovered
    value[:stage] = :battle_pending
    true
  end

  def self.finish_battle!(won, store = nil)
    value = state(store, false)
    return false unless value[:stage] == :battle_pending
    if won == true
      value[:stage] = :befriending
      value[:flags][:battle_won] = true
    else
      value[:stage] = :discovered
    end
    won == true
  end

  def self.interrupt!(store = nil)
    value = state(store, false)
    value[:stage] = :discovered if value[:stage] == :battle_pending
    value
  end

  def self.recruit!(player = nil, store = nil)
    player ||= (defined?($player) ? $player : nil)
    value = state(store)
    return false unless player && player.respond_to?(:party) && player.party.is_a?(Array)
    party = player.party
    friends = party.select { |pokemon| pokemon.respond_to?(:species) && pokemon.species == SPECIES }
    raise InvalidState, "Multiple Murkrow already exist in the party" if friends.length > 1
    if value[:flags][:murkrow_recruited]
      return friends.first || false
    end
    return false unless value[:stage] == :befriending
    if friends.first
      value[:flags][:murkrow_recruited] = true
      value[:stage] = :recruited
      return friends.first
    end
    return false if party.length >= 6
    raise "Shattered Core befriending API unavailable" unless
      defined?(Shattered) && Shattered.respond_to?(:befriend)
    begin
      friend = Shattered.befriend(SPECIES, 5, player)
    rescue StandardError
      friend = party.find { |pokemon| pokemon.respond_to?(:species) && pokemon.species == SPECIES }
      raise unless friend
    end
    return false unless friend && party.include?(friend) && friend.species == SPECIES
    friends = party.select { |pokemon| pokemon.respond_to?(:species) && pokemon.species == SPECIES }
    raise InvalidState, "Befriending created duplicate Murkrow" unless friends.length == 1
    value[:flags][:murkrow_recruited] = true
    value[:stage] = :recruited
    friend
  end

  def self.claim_reward!(reward, store = nil)
    value = state(store)
    return true if value[:stage] == :complete || value[:flags][:reward_claimed]
    return false unless value[:stage] == :recruited
    validate_reward!(reward)
    return false unless Object.new.respond_to?(:pbReceiveItem, true)
    value[:flags][:reward_claimed] = true
    begin
      result = Object.new.send(:pbReceiveItem, reward["item"].to_sym, reward["quantity"])
      unless result
        value[:flags][:reward_claimed] = false
        return false
      end
      value[:flags][:complete] = true
      value[:stage] = :complete
      true
    rescue StandardError
      value[:flags][:reward_claimed] = false
      false
    end
  end

  def self.validate_reward!(reward)
    raise ArgumentError, "Invalid reward plan" unless reward.is_a?(Hash) &&
      reward["item"].is_a?(String) && ITEM_PATTERN.match(reward["item"]) &&
      reward["quantity"].instance_of?(Integer) && reward["quantity"].between?(1, 99)
    true
  end

  def self.validate_battle!(battle)
    raise ArgumentError, "Invalid battle hook plan" unless battle.is_a?(Hash) &&
      BATTLE_HOOKS.include?(battle["hook"]) && battle["arguments"].is_a?(Array) &&
      battle["arguments"].length.between?(1, 10)
    battle["arguments"].each { |argument| validate_battle_argument!(argument) }
    if battle["hook"] == "WildBattle.start_core"
      args = battle["arguments"]
      raise ArgumentError, "Wild rescue must battle Murkrow at a reviewed level" unless
        args.length == 2 && args[0] == { "symbol" => "MURKROW" } &&
        args[1].instance_of?(Integer) && args[1].between?(1, 100)
    end
    true
  end

  def self.validate_battle_argument!(argument)
    if argument.is_a?(Hash)
      raise ArgumentError, "Invalid symbol argument" unless argument.keys == ["symbol"] &&
        argument["symbol"].is_a?(String) && SYMBOL_PATTERN.match(argument["symbol"])
    elsif argument.is_a?(Array)
      argument.each { |item| validate_battle_argument!(item) }
    elsif !(argument.is_a?(String) || argument.instance_of?(Integer) ||
            argument == true || argument == false || argument.nil?)
      raise ArgumentError, "Unsupported battle argument"
    end
    true
  end

  def self.decode_battle_argument(argument)
    if argument.is_a?(Hash)
      argument["symbol"].to_sym
    elsif argument.is_a?(Array)
      argument.map { |item| decode_battle_argument(item) }
    else
      argument
    end
  end

  def self.battle_receiver(battle)
    case battle["hook"]
    when "WildBattle.start_core"
      return WildBattle if defined?(WildBattle) && WildBattle.respond_to?(:start_core)
    when "TrainerBattle.start_core"
      return TrainerBattle if defined?(TrainerBattle) && TrainerBattle.respond_to?(:start_core)
    end
    nil
  end

  def self.run_battle!(battle)
    validate_battle!(battle)
    receiver = battle_receiver(battle)
    raise "Essentials v21.1 battle entry unavailable: #{battle['hook']}" unless receiver
    arguments = battle["arguments"].map { |argument| decode_battle_argument(argument) }
    if battle["hook"] == "WildBattle.start_core"
      rules = Object.new
      raise "Essentials no-capture battle rule unavailable" unless
        rules.respond_to?(:setBattleRule, true)
      rules.send(:setBattleRule, "disablePokeBalls")
    end
    # start_core returns the actual Essentials decision (1 victory, 2 loss,
    # 3 escape, 4 capture, 5 draw). WildBattle.start returns true for escape
    # and capture as well as victory, so never use its boolean for quest flags.
    receiver.start_core(*arguments) == 1
  end

  def self.run_event(encoded_plan)
    plan = JSON.parse(encoded_plan)
    validate_battle!(plan["battle"])
    validate_reward!(plan["reward"])
    value = state
    return true if value[:stage] == :complete
    discover!
    return false unless Object.new.respond_to?(:pbMessage, true) &&
      Object.new.respond_to?(:pbConfirmMessage, true)
    unless defined?(Shattered) && Shattered.respond_to?(:befriend) &&
           Object.new.respond_to?(:pbReceiveItem, true) &&
           battle_receiver(plan["battle"])
      Object.new.send(:pbMessage, "The rescue cannot continue until its game integrations are available.")
      return false
    end
    stage = state[:stage]
    message = stage == :discovered ? "A Murkrow needs help!" : "Murkrow is safe now."
    Object.new.send(:pbMessage, message)
    if state[:stage] == :discovered
      return false unless Object.new.send(:pbConfirmMessage, "Will you step in?")
      begin_battle!
      begin
        won = run_battle!(plan["battle"])
        finish_battle!(won)
      rescue StandardError
        interrupt!
        Object.new.send(:pbMessage, "The rescue was interrupted. You can try again.")
        return false
      end
      unless won
        Object.new.send(:pbMessage, "The rescue can be attempted again.")
        return false
      end
    end
    if state[:stage] == :befriending
      return false unless Object.new.send(:pbConfirmMessage, "Will you befriend Murkrow?")
      friend = recruit!
      unless friend
        Object.new.send(:pbMessage, "Make room in your party and return to Murkrow.")
        return false
      end
      Object.new.send(:pbMessage, "Murkrow joined you through friendship!")
    end
    if state[:stage] == :recruited
      unless claim_reward!(plan["reward"])
        Object.new.send(:pbMessage, "There is no room for the rescue reward yet.")
        return false
      end
    end
    true
  rescue JSON::ParserError, ArgumentError
    false
  end
end
