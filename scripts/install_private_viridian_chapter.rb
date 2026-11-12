#!/usr/bin/env ruby
# Install the recovered rest/tour/supply chapter on a private candidate COPY.
require 'json'
require 'digest'
require_relative 'private_rgss_writer'
module GameData; class Item; end; class Species; end; end

module ShatteredPrivateViridianChapter
  ROM_SHA = 'e8664a1475126a1f37358c98e55c5236d55622306b127c81c9c46d43b6e415e2'
  MAP_PINS = {
    10 => ['6ad04d25da9862e74875f6263cd7a674c7231abb64a1abcc9c8fd00e77e3f189',
           '27de759ce54ca8700766d00b474094e9edc04ccdbf3b889c9bc25eb4d8f157bf'],
    11 => ['c36da3ea1c8c40db30a3c13412b3e72273b8aa8f0f203d09ced41667a2fe2cbf'],
    12 => ['d7ddfc5e3dd62bbbc4cb37b79b4441741968cf13932d1942c725ee53c699467f'],
    15 => ['b29055183f8cfab44986d9827ee32ee2dc81b19845b41c2db285fcdbd7c4b2b9'],
    24 => ['de5e8c8043c4005a325b62df56842c420feda8be18eccf2de2adc401c1fd0dc9']
  }.freeze
  SUPPLIES = {
    'berry_1' => [31, 55], 'berry_2' => [38, 56], 'berry_3' => [40, 58],
    'wood_1' => [42, 60], 'wood_2' => [36, 62],
    'apricorn_1' => [30, 60], 'apricorn_2' => [37, 55]
  }.freeze
  NIGHT_ACTORS = {
    'ren' => [26, 12], 'cook' => [26, 19], 'saff' => [21, 22],
    'mara' => [35, 20], 'resident' => [31, 11]
  }.freeze
  module_function

  def script_command(script)
    RPG::EventCommand.new(355, 0, [script])
  end

  def supply_event(id, resource, point)
    event = RPG::Event.new(*point)
    event.id = id
    event.name = 'SHATTERED_SUPPLY:' + resource
    first = RPG::Event::Page.new
    first.graphic.character_name = 'Object ball'
    first.list = [script_command("ShatteredViridianQuest.run_supply(#{resource.inspect})"), RPG::EventCommand.new]
    last = RPG::Event::Page.new
    last.condition.self_switch_valid = true
    last.condition.self_switch_ch = 'A'
    last.through = true
    event.pages = [first, last]
    event
  end

  def install!(root, dialogue_path, training_path, night_path)
    root = File.realpath(root)
    raise 'Private staging marker required' unless File.file?(File.join(root, 'SHATTERED_STAGING_REPORT.json'))
    recovered = JSON.parse(File.read(dialogue_path))
    raise 'Dialogue is from another ROM' unless recovered['rom_sha256'] == ROM_SHA
    dialogue = recovered.fetch('dialogue')
    training = JSON.parse(File.read(training_path))
    night = JSON.parse(File.read(night_path))
    raise 'Invalid recovered night raid' unless night['rom_sha256'] == ROM_SHA &&
      night.fetch('encounters').map { |entry| entry['id'] } == NIGHT_ACTORS.keys
    raise 'Invalid recovered training curriculum' unless training['rom_sha256'] == ROM_SHA &&
      training.fetch('classes').length == 171 &&
      training['classes'].sum { |entry| entry.fetch('moves').length } == 5850 &&
      training.fetch('lesson').is_a?(Array) && !training['lesson'].empty?
    required = %w[hana morning tour council request accepted reminder thanks]
    raise 'Incomplete dialogue extraction' unless required.all? { |key| dialogue[key].is_a?(Array) && !dialogue[key].empty? }
    raise 'Incomplete recovered tour' unless dialogue['tour'].length == 9
    maps = {}
    originals = {}
    MAP_PINS.each do |id, pins|
      path = File.join(root, format('Data/Map%03d.rxdata', id))
      raise 'Missing or unsafe chapter map' unless File.file?(path) && !File.symlink?(path)
      bytes = File.binread(path)
      raise "Unreviewed chapter map #{id}" unless pins.include?(Digest::SHA256.hexdigest(bytes))
      originals[path] = bytes
      maps[id] = Marshal.load(bytes)
    end
    # Preserve the ordinary empty Tone representation used by this candidate's
    # existing doors, without inventing RGSS colour payloads.
    [Tone, Color].each do |klass|
      objects = ObjectSpace.each_object(klass).to_a
      next if objects.empty?
      raise 'Unknown colour encoding requires review' unless objects.all? { |o|
        o.instance_variable_defined?(:@native_bytes) || o.instance_variables.empty? }
      klass.class_eval { remove_method :_dump } if klass.instance_methods(false).include?(:_dump)
      objects.each do |object|
        next unless object.instance_variable_defined?(:@native_bytes)
        object.define_singleton_method(:_dump) { |_depth| @native_bytes }
      end
      # Preserve user-marshalled colours created by subsequent roundtrip loads.
      klass.define_singleton_method(:_load) do |bytes|
        raise 'Invalid native colour payload' unless bytes.bytesize == 32
        object = allocate
        object.instance_variable_set(:@native_bytes, bytes)
        object.define_singleton_method(:_dump) { |_depth| @native_bytes }
        object
      end
    end
    tilesets = load_data(File.join(root, 'Data/Tilesets.rxdata'))
    forest = maps.fetch(24)
    occupied = forest.events.values.map { |e| [e.x, e.y] }
    SUPPLIES.each_value do |point|
      raise "Blocked/occupied supply tile #{point.inspect}" unless
        ShatteredNativeAudit.tile_status(forest, tilesets, *point) == 'clear' && !occupied.include?(point)
      raise 'Supply has no clear approach' unless [[-1,0],[1,0],[0,-1],[0,1]].any? { |dx,dy|
        xy = [point[0]+dx, point[1]+dy]
        ShatteredNativeAudit.tile_status(forest, tilesets, *xy) == 'clear' &&
          !occupied.include?(xy) && !SUPPLIES.values.include?(xy) }
    end
    city_guard = maps[10].events.fetch(28)
    hana = maps[11].events.fetch(10)
    mara = maps[12].events.fetch(10)
    ren = maps[15].events.fetch(1)
    raise 'Ren native teacher identity drift' unless [ren.x, ren.y, ren.name] == [6, 2, 'Teacher']
    raise 'Chapter actor identity drift' unless city_guard.name == 'SHATTERED_VIRIDIAN:guard_at_center' &&
      [hana.x, hana.y, hana.name] == [4, 7, 'NPC'] &&
      [mara.x, mara.y, mara.name] == [9, 5, 'NPC']
    old_tiles = maps.transform_values { |map| Marshal.dump(map.data) }
    untouched = maps.transform_values { |map| map.events.transform_values { |event| Marshal.dump(event) } }
    # Mara's mission opens the original native north-road blockers. Reserve a
    # distinct switch after checking every map, rather than borrowing a badge.
    system_path = File.join(root, 'Data/System.rxdata')
    raise 'Unsafe native switch registry' unless File.file?(system_path) && !File.symlink?(system_path)
    originals[system_path] = File.binread(system_path)
    system = Marshal.load(originals[system_path])
    switches = system.instance_variable_get(:@switches)
    raise 'North gate switch is already named' unless switches.is_a?(Array) && switches[1101].to_s.empty?
    Dir.glob(File.join(root, 'Data/Map[0-9][0-9][0-9].rxdata')).each do |path|
      map = Marshal.load(File.binread(path))
      map.events.each_value do |event|
        event.pages.each do |page|
          c = page.condition
          raise 'North gate switch collides with an existing event' if
            (c.switch1_valid && c.switch1_id == 1101) || (c.switch2_valid && c.switch2_id == 1101) ||
            page.list.any? { |cmd| cmd.code == 121 && cmd.parameters[0].is_a?(Integer) &&
              cmd.parameters[1].is_a?(Integer) && 1101.between?(cmd.parameters[0], cmd.parameters[1]) }
        end
      end
    end
    switches[1101] = 'Shattered Mara north road authorised'
    {18 => 'Grumpy Old Man', 19 => 'Event Barrier'}.each do |id, name|
      blocker = maps[10].events.fetch(id)
      raise 'North road blocker identity drift' unless blocker.name == name
      open = RPG::Event::Page.new
      open.condition.switch1_valid = true
      open.condition.switch1_id = 1101
      open.through = true
      blocker.pages << open
    end
    city_guard.pages.last.list.insert(-2, script_command("ShatteredViridianQuest.run_tour(#{dialogue.inspect})"))
    hana.name = 'SHATTERED_QUEST:Hana'
    hana.pages.first.list = [script_command("ShatteredViridianQuest.run_rest(#{dialogue.inspect})"), RPG::EventCommand.new]
    mara.name = 'SHATTERED_QUEST:Mara'
    mara.pages.first.list = [script_command("ShatteredViridianQuest.run_mara(#{dialogue.inspect})"), RPG::EventCommand.new]
    city = maps[10]
    graphics = {
      'ren' => ren.pages.first.graphic, 'cook' => city.events.fetch(13).pages.first.graphic,
      'saff' => city.events.fetch(14).pages.first.graphic,
      'mara' => mara.pages.first.graphic, 'resident' => city.events.fetch(15).pages.first.graphic
    }
    occupied_city = city.events.values.map { |event| [event.x, event.y] }
    NIGHT_ACTORS.each do |actor, point|
      raise 'Blocked/occupied night actor' unless
        ShatteredNativeAudit.tile_status(city, tilesets, *point) == 'clear' && !occupied_city.include?(point)
      raise 'Night actor has no clear approach' unless [[-1,0],[1,0],[0,-1],[0,1]].any? { |dx, dy|
        xy = [point[0]+dx, point[1]+dy]
        ShatteredNativeAudit.tile_status(city, tilesets, *xy) == 'clear' &&
          !occupied_city.include?(xy) && !NIGHT_ACTORS.values.include?(xy) }
      event = RPG::Event.new(*point)
      event.id = city.events.keys.max + 1
      event.name = 'SHATTERED_NIGHT:' + actor
      dormant = RPG::Event::Page.new
      dormant.through = true
      active = RPG::Event::Page.new
      active.condition.self_switch_valid = true
      active.condition.self_switch_ch = 'A'
      active.graphic = Marshal.load(Marshal.dump(graphics.fetch(actor)))
      active.list = [script_command("ShatteredViridianNightRaid.trigger(#{actor.inspect})"), RPG::EventCommand.new]
      event.pages = [dormant, active]
      sprite = active.graphic.character_name
      raise 'Missing native night victim sheet' unless File.file?(File.join(root, 'Graphics/Characters', sprite + '.png'))
      city.events[event.id] = event
    end
    ren.name = 'SHATTERED_QUEST:Ren'
    ren.pages.first.list = [script_command('ShatteredRenTraining.run_lesson'), RPG::EventCommand.new]
    SUPPLIES.each do |resource, point|
      id = forest.events.keys.max + 1
      forest.events[id] = supply_event(id, resource, point)
    end
    allowed = {10 => [18, 19, 28], 11 => [10], 12 => [10], 15 => [1], 24 => []}
    maps.each do |id, map|
      raise 'Chapter changed native tiles' unless Marshal.dump(map.data) == old_tiles[id]
      raise 'Chapter changed unrelated events' unless untouched[id].all? { |event_id, bytes|
        allowed[id].include?(event_id) || Marshal.dump(map.events[event_id]) == bytes }
    end
    item_path = File.join(root, 'Data/items.dat')
    pbs_path = File.join(root, 'PBS/items.txt')
    [item_path, pbs_path].each do |path|
      raise 'Missing or unsafe item data' unless File.file?(path) && !File.symlink?(path)
      originals[path] = File.binread(path)
    end
    items = Marshal.load(originals[item_path])
    raise 'Unexpected compiled item registry' unless items.is_a?(Hash) && items[:SACREDASH].is_a?(GameData::Item)
    raise 'Camping Kit already exists; review its schema' if items.key?(:CAMPINGKIT) || originals[pbs_path].include?('[CAMPINGKIT]')
    kit = Marshal.load(Marshal.dump(items.fetch(:SACREDASH)))
    {id: :CAMPINGKIT, real_name: 'Camping Kit', real_name_plural: 'Camping Kits',
     real_portion_name: nil, real_portion_name_plural: nil, field_use: 2, battle_use: 0,
     price: 0, sell_price: 0, flags: [], consumable: true,
     real_description: 'Single-use supplies that restore the whole party.'}.each { |key, value|
      kit.instance_variable_set('@' + key.to_s, value) }
    items[:CAMPINGKIT] = kit
    raise 'Supply List already exists' if items.key?(:SHATTEREDSUPPLYLIST) || originals[pbs_path].include?('[SHATTEREDSUPPLYLIST]')
    list = Marshal.load(Marshal.dump(kit))
    {id: :SHATTEREDSUPPLYLIST, real_name: 'Supply List', real_name_plural: 'Supply Lists',
     pocket: 8, flags: ['KeyItem'], consumable: false,
     real_description: 'Mara needs three medicinal berries, two dry wood bundles and two apricorns.'}.each { |key,value|
      list.instance_variable_set('@' + key.to_s, value) }
    items[:SHATTEREDSUPPLYLIST] = list
    raise 'Training Manual already exists' if items.key?(:SHATTEREDTRAININGMANUAL) || originals[pbs_path].include?('[SHATTEREDTRAININGMANUAL]')
    manual = Marshal.load(Marshal.dump(list))
    {id: :SHATTEREDTRAININGMANUAL, real_name: 'Training Manual', real_name_plural: 'Training Manuals',
     real_description: 'Ren\'s reference to the original HUMAN specialisation curriculum.'}.each { |key, value|
      manual.instance_variable_set('@' + key.to_s, value) }
    items[:SHATTEREDTRAININGMANUAL] = manual
    outputs = maps.to_h { |id, map| [File.join(root, format('Data/Map%03d.rxdata', id)), Marshal.dump(map)] }
    outputs[item_path] = Marshal.dump(items)
    outputs[system_path] = Marshal.dump(system)
    training_output = File.join(root, 'Data/shattered_training.dat')
    raise 'Training data already exists' if File.exist?(training_output)
    outputs[training_output] = Marshal.dump(training)
    night_output = File.join(root, 'Data/shattered_night_raid.dat')
    raise 'Night raid data already exists' if File.exist?(night_output) || File.symlink?(night_output)
    outputs[night_output] = Marshal.dump(night)
    species_path = File.join(root, 'Data/species.dat')
    pokemon_path = File.join(root, 'PBS/pokemon.txt')
    [species_path, pokemon_path].each do |path|
      raise 'Missing/unsafe species registry' unless File.file?(path) && !File.symlink?(path)
      originals[path] = File.binread(path)
    end
    species = Marshal.load(originals[species_path])
    raise 'Raider species already exists' if species.key?(:RAIDER) || originals[pokemon_path].include?('[RAIDER]')
    raider = Marshal.load(Marshal.dump(species.fetch(:HUMAN)))
    source_raider = night.fetch('raider')
    raise 'Unknown raider typing' unless source_raider.fetch('types') == [9, 9]
    stat_ids = [:HP, :ATTACK, :DEFENSE, :SPEED, :SPECIAL_ATTACK, :SPECIAL_DEFENSE]
    raider_stats = stat_ids.zip(source_raider.fetch('base_stats')).to_h
    # QMARKS is the native Gen III slot 9. No Normal STAB is invented for
    # the source HUMAN type; Core supplies the recovered defensive chart.
    {id: :RAIDER, species: :RAIDER, real_name: 'Raider', types: [:QMARKS],
     base_stats: raider_stats, base_exp: source_raider.fetch('base_exp'),
     evs: stat_ids.to_h { |stat| [stat, 0] }, growth_rate: :Slow,
     abilities: [source_raider.fetch('ability').to_sym], hidden_abilities: [],
     catch_rate: 0, happiness: 0, moves: [], tutor_moves: [], egg_moves: [],
     evolutions: [], offspring: [], real_pokedex_entry: 'A human raider attacking the settlement.'}.each { |key, value|
      raider.instance_variable_set('@' + key.to_s, value) }
    species[:RAIDER] = raider
    beedrill = species.fetch(:BEEDRILL)
    beedrill.instance_variable_set(:@base_stats, stat_ids.zip(night.fetch('beedrill').fetch('base_stats')).to_h)
    beedrill.instance_variable_set(:@base_exp, night.fetch('beedrill').fetch('base_exp'))
    outputs[species_path] = Marshal.dump(species)
    pbs_stats = ->(stats) { [stats[0], stats[1], stats[2], stats[3], stats[4], stats[5]].join(',') }
    pokemon_text = originals[pokemon_path].dup
    # Update only Beedrill's source base stats/experience; leave its existing
    # learnset, evolutions and every unrelated species unchanged.
    changed = false
    pokemon_text.sub!(/\[BEEDRILL\].*?(?=\n\[|\z)/m) do |block|
      changed = true
      block.sub(/^BaseStats = [^\r\n]+/, 'BaseStats = ' + pbs_stats.call(night['beedrill']['base_stats']))
        .sub(/^BaseExp = [^\r\n]+/, 'BaseExp = ' + night['beedrill']['base_exp'].to_s)
    end
    raise 'Missing native Beedrill PBS' unless changed
    pokemon_text += "\n[RAIDER]\nName = Raider\nTypes = QMARKS\nBaseStats = #{pbs_stats.call(source_raider['base_stats'])}\nGenderRatio = Genderless\nGrowthRate = Slow\nBaseExp = #{source_raider['base_exp']}\nCatchRate = 0\nHappiness = 0\nAbilities = #{source_raider['ability']}\nEggGroups = Undiscovered\nHatchSteps = 5120\nHeight = 1.8\nWeight = 85.0\nColor = Brown\nShape = Bipedal\nCategory = Human\nPokedex = A human raider attacking the settlement.\n"
    outputs[pokemon_path] = pokemon_text
    %w[RAIDER BEEDRILL].each do |name|
      source = File.join(File.dirname(night_path), File.basename(night_path, '.json'), name + '.png')
      raise 'Unverified recovered opponent sprite' unless File.file?(source) && !File.symlink?(source) &&
        Digest::SHA256.file(source).hexdigest == night.fetch('asset_sha256').fetch(name + '.png')
      target = File.join(root, 'Graphics/Pokemon/Front', name + '.png')
      raise 'Unsafe opponent sprite destination' if File.symlink?(target)
      originals[target] = File.binread(target) if File.exist?(target)
      outputs[target] = File.binread(source)
    end
    outputs[pbs_path] = originals[pbs_path] + "\n[CAMPINGKIT]\nName = Camping Kit\nNamePlural = Camping Kits\nPocket = 2\nPrice = 0\nFieldUse = Direct\nConsumable = true\nDescription = Single-use supplies that restore the whole party.\n"
    outputs[pbs_path] += "\n[SHATTEREDSUPPLYLIST]\nName = Supply List\nNamePlural = Supply Lists\nPocket = 8\nPrice = 0\nFieldUse = Direct\nConsumable = false\nFlags = KeyItem\nDescription = Mara needs three medicinal berries, two dry wood bundles and two apricorns.\n"
    outputs[pbs_path] += "\n[SHATTEREDTRAININGMANUAL]\nName = Training Manual\nNamePlural = Training Manuals\nPocket = 8\nPrice = 0\nFieldUse = Direct\nConsumable = false\nFlags = KeyItem\nDescription = Ren's reference to the original HUMAN specialisation curriculum.\n"
    outputs.each do |path, bytes|
      raise 'Stale chapter recovery file' if File.exist?(path + '.chapter.tmp') || File.exist?(path + '.chapter.bak')
      next if path == pbs_path || path == pokemon_path || path.end_with?('.png')
      raise 'Native chapter roundtrip failed' unless Marshal.dump(Marshal.load(bytes)) == bytes
    end
    replaced = []
    begin
      outputs.each { |path, bytes| File.binwrite(path + '.chapter.tmp', bytes) }
      outputs.each_key do |path|
        File.rename(path, path + '.chapter.bak') if File.exist?(path)
        replaced << path
        File.rename(path + '.chapter.tmp', path)
      end
    rescue Exception
      replaced.reverse_each do |path|
        File.delete(path) if File.exist?(path)
        File.rename(path + '.chapter.bak', path) if File.exist?(path + '.chapter.bak')
      end
      raise
    ensure
      outputs.each_key { |path| File.delete(path + '.chapter.tmp') if File.exist?(path + '.chapter.tmp') }
    end
    replaced.each { |path| File.delete(path + '.chapter.bak') if File.exist?(path + '.chapter.bak') }
    report = {'chapter' => 'bunkhouse_rest_tour_mara_supply_run', 'rom_sha256' => ROM_SHA,
      'native_placement' => 'adapted to existing Essentials maps; ROM map geometry is not ported here',
      'supply_events' => SUPPLIES, 'reward' => 'CAMPINGKIT',
      'training' => {'map' => 15, 'event' => 1, 'technique' => 'QUICKATTACK',
        'reference_classes' => 171, 'reference_moves' => 5850},
      'night_raid' => {'native_actors' => NIGHT_ACTORS,
        'placement' => 'Victim interactions adapted to native Essentials geometry and existing NPC sheets',
        'encounters' => night['encounters'].map { |entry| entry.reject { |key, _| key == 'dialogue' } }},
      'files' => outputs.to_h { |path, bytes| [path.delete_prefix(root + '/'), Digest::SHA256.hexdigest(bytes)] },
      'native_gameplay_verified' => false}
    File.write(File.join(root, 'SHATTERED_VIRIDIAN_CHAPTER_REPORT.json'), JSON.pretty_generate(report) + "\n")
    report
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'Usage: ruby install_private_viridian_chapter.rb PRIVATE_COPY DIALOGUE_JSON TRAINING_JSON NIGHT_JSON' unless ARGV.length == 4
  puts JSON.pretty_generate(ShatteredPrivateViridianChapter.install!(*ARGV))
end
