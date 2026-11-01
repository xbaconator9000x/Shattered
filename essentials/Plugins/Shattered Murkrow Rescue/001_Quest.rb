# frozen_string_literal: true
# SE-019C: saved Murkrow rescue state and native event flow.
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
  RECRUIT_TAG = :@shattered_murkrow_rescue_award

  def self.tagged_murkrow?(pokemon)
    pokemon && pokemon.respond_to?(:species) && pokemon.species == SPECIES &&
      pokemon.instance_variable_get(RECRUIT_TAG) == VERSION
  end

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
    if value.nil?
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
    # A partially corrupted or imported save must never skip the rescue battle,
    # adopt an unrelated Murkrow or claim the reward twice.
    consistent = (!flags[:battle_won] || flags[:discovered]) &&
      (!flags[:murkrow_recruited] || flags[:battle_won]) &&
      (!flags[:reward_claimed] || flags[:murkrow_recruited]) &&
      (!flags[:complete] || flags[:reward_claimed])
    raise InvalidState, "Inconsistent Murkrow rescue progress" unless consistent
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

  # A species match is NOT evidence of this quest's reward. Without a tag,
  # an unrelated Murkrow can be silently adopted and the rescue skipped.
  # Tag the actual befriended Pokemon before committing the saved quest flag.
  def self.recruit!(player = nil, store = nil)
    player ||= (defined?($player) ? $player : nil)
    value = state(store)
    return false unless player && player.respond_to?(:party) && player.party.is_a?(Array)
    party = player.party
    friends = party.select { |pokemon| pokemon.respond_to?(:species) && pokemon.species == SPECIES }
    raise InvalidState, "Multiple Murkrow already exist in the party" if friends.length > 1
    tagged = friends.select { |pokemon| tagged_murkrow?(pokemon) }
    if value[:flags][:murkrow_recruited]
      raise InvalidState, "Tagged Murkrow rescue companion missing" if tagged.empty?
      return tagged.first
    end
    return false unless value[:stage] == :befriending
    if tagged.any?
      # Recover only a tagged companion from an interrupted save, never a
      # random Murkrow already travelling with the player.
      value[:flags][:murkrow_recruited] = true
      value[:stage] = :recruited
      return tagged.first
    end
    raise InvalidState, "Unrelated Murkrow cannot be adopted as rescue reward" if friends.any?
    return false if party.length >= 6
    raise "Shattered Core befriending API unavailable" unless
      defined?(Shattered) && Shattered.respond_to?(:befriend)
    friend = Shattered.befriend(SPECIES, 5, player)
    raise InvalidState, "Befriending did not create a new Murkrow" unless
      friend && party.include?(friend) && friend.species == SPECIES
    friend.instance_variable_set(RECRUIT_TAG, VERSION)
    value[:flags][:murkrow_recruited] = true
    value[:stage] = :recruited
    friend
  end

  def self.claim_reward!(reward, store = nil)
    value = state(store)
    return true if value[:stage] == :complete || value[:flags][:reward_claimed]
    return false unless value[:stage] == :recruited
    # Never pay out a rescue reward when the actual tagged companion has
    # vanished or was replaced by an unrelated Murkrow after save/reload.
    # recruit! is idempotent here and checks the saved award provenance.
    return false unless recruit!(nil, store)
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
      # A failed rescue must return to the overworld for a retry rather than
      # ending the run at Game Over. This also lets Essentials restore HP.
      rules.send(:setBattleRule, "canLose")
    end
    # start_core returns the actual Essentials decision (1 victory, 2 loss,
    # 3 escape, 4 capture, 5 draw). WildBattle.start returns true for escape
    # and capture as well as victory, so never use its boolean for quest flags.
    decision = receiver.start_core(*arguments)
    # Essentials restores HP on canLose loss/draw, but HUMAN stamina is saved
    # separately. Mirror the mandatory Route 22 retry recovery contract.
    if battle["hook"] == "WildBattle.start_core" && [2, 5].include?(decision) &&
       defined?(Shattered) && Shattered.respond_to?(:restore_stamina) &&
       defined?($player) && $player && $player.respond_to?(:party)
      $player.party.each do |member|
        Shattered.restore_stamina(member) if Shattered.human?(member)
      end
    end
    decision == 1
  end

  # New native events pass a reviewed Ruby Hash directly. Legacy JSON event
  # strings remain supported only when JSON is already available in the host.
  # Do not require CRuby json/base64 at mkxp-z game startup.
  def self.run_event(encoded_plan)
    plan = if encoded_plan.is_a?(Hash)
             encoded_plan
           elsif encoded_plan.is_a?(String) && defined?(JSON)
             JSON.parse(encoded_plan)
           else
             raise ArgumentError, "Unsupported Murkrow event plan"
           end
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
  rescue StandardError => error
    raise unless error.is_a?(ArgumentError) ||
      (defined?(JSON::ParserError) && error.is_a?(JSON::ParserError))
    false
  end
end
