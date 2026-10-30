# frozen_string_literal: true
# SE-019: native Essentials dojo questionnaire and no-ball companion award.
# Original questionnaire dialogue has NOT been recovered; these are provisional
# original prompts and must be compared with the authorised Shattered demo.
module ShatteredDojo
  VERSION = 1
  STARTERS = [:VULPIX, :STARYU, :EXEGGCUTE].freeze
  QUESTIONS = [
    ["When someone needs help, what comes first?",
     [["Act quickly and bravely.", :VULPIX],
      ["Observe before acting.", :STARYU],
      ["Keep everyone together.", :EXEGGCUTE]]],
    ["Where would you feel most at home?",
     [["Beside a warm fire.", :VULPIX],
      ["Under a quiet night sky.", :STARYU],
      ["In a thriving garden.", :EXEGGCUTE]]],
    ["What would you offer a frightened Pokemon?",
     [["Courage.", :VULPIX],
      ["Patience.", :STARYU],
      ["Shelter.", :EXEGGCUTE]]]
  ].freeze

  class InvalidState < StandardError; end
  class MissingStarter < StandardError; end

  def self.state(store = (defined?($PokemonGlobal) ? $PokemonGlobal : nil))
    raise "Saved PokemonGlobal is unavailable" unless store
    value = store.instance_variable_get(:@shattered_dojo_starter)
    if value.nil?
      value = { :version => VERSION, :answers => [], :choice => nil, :recruited => false }
      store.instance_variable_set(:@shattered_dojo_starter, value)
    end
    valid = value.is_a?(Hash) && value[:version] == VERSION &&
      value[:answers].is_a?(Array) && value[:answers].length <= QUESTIONS.length &&
      value[:answers].all? { |a| a.instance_of?(Integer) && a.between?(0, 2) } &&
      (value[:choice].nil? || STARTERS.include?(value[:choice])) &&
      [true, false].include?(value[:recruited]) &&
      (!value[:recruited] || !value[:choice].nil?)
    raise InvalidState, "Unknown dojo save data; refusing to reset a player's choice" unless valid
    value
  end

  # Append-only answers. Replaying the same answer after an interruption is safe;
  # changing an already recorded answer is refused.
  def self.answer!(index, answer, store = (defined?($PokemonGlobal) ? $PokemonGlobal : nil))
    value = state(store)
    raise ArgumentError, "Question index invalid" unless index.instance_of?(Integer) &&
      index.between?(0, QUESTIONS.length - 1)
    raise ArgumentError, "Answer invalid" unless answer.instance_of?(Integer) && answer.between?(0, 2)
    raise InvalidState, "Cannot change a finished questionnaire" if value[:choice]
    return value[:answers][index] == answer if index < value[:answers].length
    raise InvalidState, "Questions must be answered in order" unless index == value[:answers].length
    value[:answers] << answer
    true
  end

  def self.choice(store = (defined?($PokemonGlobal) ? $PokemonGlobal : nil))
    value = state(store)
    return value[:choice] if value[:choice]
    return nil unless value[:answers].length == QUESTIONS.length
    scores = Hash.new(0)
    value[:answers].each_with_index do |answer, index|
      scores[QUESTIONS[index][1][answer][1]] += 1
    end
    highest = scores.values.max
    tied = STARTERS.select { |species| scores[species] == highest }
    # Stable tie-break from the first answer, not randomness or question order.
    first = QUESTIONS[0][1][value[:answers][0]][1]
    value[:choice] = tied.include?(first) ? first : tied.first
  end

  def self.starter_tagged?(pokemon)
    pokemon && pokemon.instance_variable_get(:@shattered_dojo_starter_award) == VERSION
  end

  # Reconcile a companion already added to the party before a save interruption.
  # Never adopt an unrelated Pokemon of the same species as the dojo reward.
  def self.recruit!(player = (defined?($player) ? $player : nil),
                    store = (defined?($PokemonGlobal) ? $PokemonGlobal : nil))
    value = state(store)
    species = choice(store)
    return false unless species
    raise ArgumentError, "Player party unavailable" unless player && player.respond_to?(:party)
    party = player.party
    raise ArgumentError, "Invalid party" unless party.is_a?(Array)
    tagged = party.select { |p| starter_tagged?(p) }
    raise InvalidState, "Multiple dojo starters detected" if tagged.length > 1
    if value[:recruited]
      raise MissingStarter, "Dojo reward was removed; do not grant a duplicate" if tagged.empty?
      raise InvalidState, "Dojo reward species mismatch" unless tagged.first.species == species
      return tagged.first
    end
    if tagged.any?
      raise InvalidState, "Dojo reward species mismatch" unless tagged.first.species == species
      value[:recruited] = true
      return tagged.first
    end
    return false if party.length >= 6
    raise "HUMAN companion missing" unless defined?(Shattered) &&
      Shattered.respond_to?(:human?) && party.any? { |p| Shattered.human?(p) }
    raise "Starter species not compiled" unless defined?(GameData::Species) &&
      GameData::Species.respond_to?(:exists?) && GameData::Species.exists?(species)
    raise "Shattered Core befriending unavailable" unless Shattered.respond_to?(:befriend)
    raise InvalidState, "Existing untagged species; cannot adopt as dojo reward" if
      party.any? { |p| p.respond_to?(:species) && p.species == species }
    friend = Shattered.befriend(species, 5, player)
    raise "Befriending did not add the selected species" unless
      friend && party.include?(friend) && friend.species == species
    friend.instance_variable_set(:@shattered_dojo_starter_award, VERSION)
    value[:recruited] = true
    friend
  end

  # Called by the native RMXP action-button event. Each answer and award is
  # persisted on the existing Essentials PokemonGlobal save object.
  def self.run_quiz
    value = state
    if value[:recruited]
      pbMessage(_INTL("Your companion is already travelling with you."))
      return true
    end
    while value[:answers].length < QUESTIONS.length
      index = value[:answers].length
      prompt, entries = QUESTIONS[index]
      answer = pbMessage(_INTL(prompt), entries.map { |e| _INTL(e[0]) }, -1)
      return false if answer.nil? || answer == -1
      answer!(index, answer)
    end
    species = choice
    pbMessage(_INTL("You seem suited to {1}.", species.to_s.capitalize))
    return false unless pbConfirmMessage(_INTL("Will you welcome this Pokemon as a friend?"))
    friend = recruit!
    unless friend
      pbMessage(_INTL("You need a free party space before your companion can join."))
      return false
    end
    pbMessage(_INTL("{1} joined you through friendship!", species.to_s.capitalize))
    true
  end
end
