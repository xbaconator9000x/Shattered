require "json"
require "digest"
require "fileutils"

module ShatteredInitialSlice
  PLAN_PATH = "Plugins/Shattered Initial Slice Installer/initial_slice_plan.json"
  PLAN_SHA256 = "__PLAN_SHA256__"
  RUNNER_TEMPLATE_SHA256 = "__TEMPLATE_SHA256__"
  INSTALLER_ORDER = [
    "pbInstallShatteredHNSReceptionGate",
    "pbInstallShatteredWorldLinks",
    "pbInstallShatteredGateStory",
    "pbInstallShatteredRoute22"
  ].freeze
  RECEIPT_PATH = "Data/.shattered_initial_slice.receipt.json"
  ROLLBACK_DIR = "Data/.shattered_initial_slice.rollback"
  ROUTE22_UUID = "c4c03051-b9be-4d3c-a06c-bcde09a0e3a2"
  HNS_WARPS = {
    "west" => [[1, 9]],
    "east" => [[20, 9]],
    "south" => [[11, 19]],
    "north" => [[10, 1], [11, 1]]
  }.freeze
  ROUTE22_RESERVED = [[36, 16], [36, 17], [36, 18],
                      [38, 17], [39, 16], [39, 18]].freeze

  def self.top
    TOPLEVEL_BINDING.eval("self")
  end

  def self.call_api(name, *args)
    top.send(name, *args)
  end

  def self.load_native(path)
    top.send(:load_data, path)
  end

  def self.save_native(value, path)
    top.send(:save_data, value, path)
  end

  def self.check(condition, message)
    raise message unless condition
  end

  def self.safe_file!(relative)
    check(relative.is_a?(String) && !relative.empty? &&
      !relative.start_with?("/") && !relative.include?("\\") &&
      !relative.split("/").any? { |part| ["", ".", ".."].include?(part) },
      "Unsafe handoff path: #{relative.inspect}")
    path = ""
    relative.split("/").each do |part|
      path = path.empty? ? part : File.join(path, part)
      check(!File.symlink?(path), "Symlink rejected in handoff path: #{relative}")
    end
    check(File.file?(path), "Missing handoff input: #{relative}")
    path
  end

  def self.file_sha(path)
    Digest::SHA256.file(path).hexdigest
  end

  def self.json_file(path)
    JSON.parse(File.read(safe_file!(path)))
  rescue JSON::ParserError => error
    raise "Invalid handoff JSON #{path}: #{error.message}"
  end

  def self.native_map_path(map_id)
    format("Data/Map%03d.rxdata", map_id)
  end

  def self.event_name?(map, prefix)
    map.events.values.any? { |event| event.respond_to?(:name) && event.name.start_with?(prefix) }
  end

  def self.event_at?(map, x, y)
    map.events.values.any? { |event| event.x == x && event.y == y }
  end

  def self.validate_plan!(verify_baseline = true)
    check(File.file?("SHATTERED_STAGING_REPORT.json"),
      "Native installer requires SHATTERED_STAGING_REPORT.json")
    marker = json_file("SHATTERED_STAGING_REPORT.json")
    check(marker["engine"] == "Essentials 21.1" &&
      marker["profile"] == "initial_slice",
      "Native installer requires an Essentials 21.1 initial-slice staging marker")
    check(file_sha(safe_file!(PLAN_PATH)) == PLAN_SHA256,
      "Native installer plan SHA256 mismatch")
    plan = json_file(PLAN_PATH)
    runner_path = safe_file!("Plugins/Shattered Initial Slice Installer/001_Install.rb")
    normalized_runner = File.read(runner_path)
      .gsub(PLAN_SHA256, "__PLAN_SHA256__")
      .gsub(RUNNER_TEMPLATE_SHA256, "__TEMPLATE_SHA256__")
    check(Digest::SHA256.hexdigest(normalized_runner) == RUNNER_TEMPLATE_SHA256 &&
      plan["installer_template_sha256"] == RUNNER_TEMPLATE_SHA256,
      "Native installer template hash mismatch")
    check(plan["schema_version"] == 1 && plan["profile"] == "initial_slice" &&
      plan["status"] == "native_install_pending",
      "Unsupported or already-consumed native installation plan")
    check(plan["installer_apis"] == INSTALLER_ORDER,
      "Native installer dependency order differs from reviewed plan")
    check(plan["runtime_acceptance_status"].is_a?(String) &&
      plan["runtime_acceptance_status"].include?("BLOCKED"),
      "Plan must not claim native gameplay acceptance")
    check(plan["source_pins"].is_a?(Array) && !plan["source_pins"].empty?,
      "Exact source commit pins are missing")
    plan["source_pins"].each do |pin|
      check(pin["head"].to_s.match?(/\A[0-9a-f]{40}\z/) &&
        pin["source_commit"].to_s.match?(/\A[0-9a-f]{40}\z/) &&
        pin["base"].to_s.match?(/\A[0-9a-f]{40}\z/),
        "Malformed pinned source SHA")
    end
    plan["runtime_files"].each do |path, digest|
      safe_file!(path)
      check(digest.match?(/\A[0-9a-f]{64}\z/) && file_sha(path) == digest,
        "Pinned runtime source changed: #{path}")
    end
    plan["asset_files"].each do |asset_id, record|
      safe_file!(record["path"])
      check(record["sha256"].match?(/\A[0-9a-f]{64}\z/) &&
        file_sha(record["path"]) == record["sha256"],
        "Pinned local asset changed: #{asset_id}")
    end
    plan["config_hashes"].each do |path, digest|
      safe_file!(path)
      check(digest.match?(/\A[0-9a-f]{64}\z/) && file_sha(path) == digest,
        "Pinned installer config changed: #{path}")
    end
    if verify_baseline
      plan["baseline_hashes"].each do |path, digest|
        safe_file!(path)
        check(file_sha(path) == digest, "Reviewed project baseline changed: #{path}")
      end
    end
    configs = {}
    plan["config_paths"].each do |key, path|
      configs[key] = json_file(path)
    end
    [plan, configs, marker]
  end

  def self.validate_contract!(plan, configs)
    gate_id = plan["map_targets"].fetch("reception_gate").fetch("id")
    route = plan["map_targets"].fetch("route22")
    route_id = route.fetch("id")
    check(gate_id.is_a?(Integer) && route_id.is_a?(Integer) &&
      gate_id > 0 && route_id > 0 && gate_id != route_id,
      "Reviewed gate/Route22 map IDs are missing or duplicated")
    check(configs["hns_import"]["target"]["map_id"] == gate_id &&
      configs["gate_story"]["map_id"] == gate_id,
      "HnS importer and Gate Story map IDs differ from the plan")
    check(configs["world_links"]["maps"].map { |item| item["map_id"] }.sort ==
      [gate_id, route_id].sort,
      "World Links must cover exactly the initial-slice maps")
    check(configs["route22"]["map_id"] == route_id &&
      configs["route22"]["source_map_uuid"] == ROUTE22_UUID,
      "Route22 map identity differs from the reviewed plan")
    check(configs["route22"]["expected_map_sha256"] == route["sha256"] &&
      route["sha256"].match?(/\A[0-9a-f]{64}\z/),
      "Route22 base map SHA256 differs from the reviewed plan")
    resources = plan["resource_ids"]
    check(configs["route22"]["scatter_switch"] == resources["switches"]["route22_scatter"] &&
      configs["route22"]["cleared_switch"] == resources["switches"]["route22_cleared"] &&
      configs["route22"]["outcome_variable"] == resources["variables"]["route22_outcome"],
      "Route22 switch/variable IDs differ from reviewed allocations")
    check(resources["switches"].values.uniq.length == resources["switches"].length &&
      resources["variables"].values.uniq.length == resources["variables"].length,
      "Duplicate switch or variable allocation")

    hns = configs["hns_import"]
    check(hns["format"] == "shattered-hns-rmxp-map" &&
      hns["format_version"] == 1 &&
      hns["dimensions"] == {"width" => 22, "height" => 21, "tile_pixels" => 32},
      "HnS map is not the reviewed 22x21 converted source")
    grouped = Hash.new { |hash, key| hash[key] = [] }
    hns["warps"].each { |warp| grouped[warp["direction"]] << [warp["x"], warp["y"]] }
    check(grouped == HNS_WARPS, "HnS warp coordinates differ from the source contract")
    south = hns["warps"].find { |warp| warp["direction"] == "south" }
    south_target = south.fetch("target")
    expected_south = [0, south_target["map_id"], south_target["x"],
      south_target["y"], south_target["direction"], south_target["fade"]]
    check(configs["gate_story"]["positions"]["johto_block"] ==
      {"x" => south["x"], "y" => south["y"]} &&
      configs["gate_story"]["expected_south_transfer"] == expected_south,
      "Gate Story south blocker/transfer differs from the imported HnS warp")

    link_positions = {}
    configs["world_links"]["events"].each do |event|
      key = [event["map_id"], event["x"], event["y"]]
      check(!link_positions[key], "Duplicate world-link event coordinate")
      link_positions[key] = true
    end
    gate_warps = HNS_WARPS.values.flatten(1)
    check(configs["world_links"]["events"].none? do |event|
      event["map_id"] == gate_id && gate_warps.include?([event["x"], event["y"]])
    end, "World-link event overlaps an HnS warp")
    configs["gate_story"]["positions"].each do |name, position|
      next if name == "johto_block"
      check(!link_positions[[gate_id, position["x"], position["y"]]],
        "Gate Story event overlaps a world-link event: #{name}")
    end
    check(plan["route22_reserved_positions"].length == ROUTE22_RESERVED.length &&
      plan["route22_reserved_positions"].sort == ROUTE22_RESERVED.sort,
      "Route22 event coordinate contract differs from the pinned source")
    configs["world_links"]["events"].each do |event|
      next unless event["map_id"] == route_id
      check(!ROUTE22_RESERVED.include?([event["x"], event["y"]]),
        "World-link event overlaps a reserved Route22 event coordinate")
    end
  end

  def self.preflight_native!(plan, configs)
    check(defined?(RPG::Map), "Installer must run in a native Essentials/RMXP context")
    %w[pbInstallShatteredHNSReceptionGate pbInstallShatteredWorldLinks
      pbInstallShatteredGateStory pbInstallShatteredRoute22].each do |api|
      check(top.respond_to?(api, true), "Required installer API is not loaded: #{api}")
    end
    check(defined?(ShatteredHNSGateImport) && defined?(ShatteredWorldLinks) &&
      defined?(ShatteredGateStory) && defined?(ShatteredRoute22),
      "Required Shattered installer modules are not loaded")
    validate_contract!(plan, configs)
    hns = configs["hns_import"]
    gate_id = plan["map_targets"]["reception_gate"]["id"]
    route = plan["map_targets"]["route22"]
    route_id = route["id"]

    map_infos = load_native("Data/MapInfos.rxdata")
    check(map_infos.is_a?(Hash), "Native MapInfos data is not a Hash")
    check(!map_infos.key?(gate_id) && !map_infos.key?(gate_id.to_s) &&
      !File.exist?(native_map_path(gate_id)),
      "Reception gate target ID is occupied")
    check(map_infos.key?(route_id) || map_infos.key?(route_id.to_s),
      "Route22 MapInfo is missing")
    check(File.file?("Data/Tilesets.rxdata"), "Native Tilesets.rxdata is missing")

    existing_maps = {}
    plan["required_existing_maps"].each do |record|
      id = record["id"]
      path = native_map_path(id)
      check(map_infos.key?(id) || map_infos.key?(id.to_s),
        "Reviewed warp destination MapInfo is missing: #{id}")
      check(file_sha(path) == record["sha256"],
        "Reviewed warp destination map changed: #{id}")
      map = load_native(path)
      check([map.width, map.height] == record["dimensions"],
        "Reviewed warp destination dimensions changed: #{id}")
      existing_maps[id] = map
    end
    route_map = existing_maps[route_id]
    check(route_map && route_map.events.is_a?(Hash),
      "Route22 map is absent from reviewed HnS warp destinations")
    check([route_map.width, route_map.height] == [48, 24],
      "Route22 native map must be 48x24")
    check(file_sha(native_map_path(route_id)) == route["sha256"],
      "Route22 map changed after the plan was generated")
    check(!event_name?(route_map, "SHATTERED_ROUTE22:") &&
      !event_name?(route_map, "SHATTERED_LINK:"),
      "Route22 has a partial/duplicate integration install without a receipt")
    ROUTE22_RESERVED.each do |x, y|
      check(!event_at?(route_map, x, y),
        "Route22 event coordinate is occupied: #{x},#{y}")
    end

    hns_plugin = File.dirname(PLAN_PATH).sub("Shattered Initial Slice Installer",
      "Shattered HnS Gate")
    ShatteredHNSGateImport.preflight!(hns)
    ShatteredWorldLinks.validate(configs["world_links"])
    ShatteredGateStory.validate_install(configs["gate_story"])
    ShatteredRoute22.validate_config(configs["route22"])
    check(configs["hns_import"]["target"]["tileset_image"] &&
      File.file?(File.join("Graphics", "Tilesets",
        configs["hns_import"]["target"]["tileset_image"])),
      "Reviewed HnS tileset image is missing")
    check(File.file?("PBS/items.txt") &&
      File.read("PBS/items.txt").match?(/^\[SHATTEREDGATEKEY\]\s*$/),
      "Compiled-input Gate Key PBS entry is missing")

    [native_map_path(gate_id), native_map_path(route_id), "Data/MapInfos.rxdata",
      "Data/Tilesets.rxdata"].each do |path|
      %w[.se013-import.tmp .se013-import.bak .shattered.tmp .shattered.bak
        .shattered_gate.tmp .shattered_gate.bak .shattered_route22.tmp
        .shattered_route22.bak .shattered_initial_slice_view.tmp].each do |suffix|
        check(!File.exist?(path + suffix), "Stale native installer file exists: #{path + suffix}")
      end
    end
    check(!File.exist?("Data/.shattered-hns-gate-import.lock"),
      "Stale HnS import lock requires manual recovery")
    check(!File.exist?(ROLLBACK_DIR), "Interrupted native installation requires manual recovery")
    check(!File.symlink?(ROLLBACK_DIR), "Interrupted native installation requires manual recovery")
    check(!File.exist?(RECEIPT_PATH), "Native installation receipt exists but is unreadable")
    check(!File.symlink?(RECEIPT_PATH + ".tmp") && !File.exist?(RECEIPT_PATH + ".tmp"),
      "Stale native installation receipt temp requires manual recovery")
    check(!File.symlink?("Plugins/Shattered Initial Slice Installer/route22.runtime.json") &&
      !File.exist?("Plugins/Shattered Initial Slice Installer/route22.runtime.json"),
      "Stale dynamic Route22 config requires manual recovery")
    [plan, existing_maps]
  end

  def self.transaction_paths(plan)
    [
      "Data/MapInfos.rxdata",
      "Data/Tilesets.rxdata",
      native_map_path(plan["map_targets"]["reception_gate"]["id"]),
      native_map_path(plan["map_targets"]["route22"]["id"])
    ].uniq
  end

  def self.begin_transaction!(paths)
    Dir.mkdir(ROLLBACK_DIR)
    records = []
    paths.each_with_index do |path, index|
      existed = File.file?(path)
      backup_name = format("%02d.bin", index)
      File.binwrite(File.join(ROLLBACK_DIR, backup_name), File.binread(path)) if existed
      records << {"path" => path, "backup" => backup_name, "existed" => existed}
    end
    File.write(File.join(ROLLBACK_DIR, "files.json"), JSON.generate(records))
  rescue Exception
    FileUtils.remove_entry(ROLLBACK_DIR) if File.directory?(ROLLBACK_DIR)
    raise
  end

  def self.restore_transaction!
    manifest_path = File.join(ROLLBACK_DIR, "files.json")
    check(File.file?(manifest_path), "Rollback manifest missing; preserve #{ROLLBACK_DIR}")
    records = JSON.parse(File.read(manifest_path))
    records.reverse_each do |record|
      path = record.fetch("path")
      if record["existed"]
        backup = File.join(ROLLBACK_DIR, record.fetch("backup"))
        check(File.file?(backup) && !File.symlink?(backup),
          "Rollback data missing; preserve #{ROLLBACK_DIR}")
        temporary = path + ".shattered_initial_slice.restore"
        check(!File.exist?(temporary) && !File.symlink?(temporary),
          "Stale rollback temp; preserve #{ROLLBACK_DIR}")
        File.binwrite(temporary, File.binread(backup))
        File.delete(path) if File.exist?(path)
        File.rename(temporary, path)
      else
        File.delete(path) if File.exist?(path)
      end
    end
    FileUtils.remove_entry(ROLLBACK_DIR)
  rescue Exception => error
    raise "Native installer failed and rollback requires recovery (#{error.message}); preserve #{ROLLBACK_DIR}"
  end

  def self.with_tileset_hash_view
    path = "Data/Tilesets.rxdata"
    original_bytes = File.binread(path)
    tilesets = load_native(path)
    return yield unless tilesets.is_a?(Array)
    hash_view = {}
    tilesets.each_with_index { |tileset, index| hash_view[index] = tileset unless tileset.nil? }
    temporary = path + ".shattered_initial_slice_view.tmp"
    check(!File.exist?(temporary) && !File.symlink?(temporary),
      "Stale temporary tileset compatibility view")
    begin
      save_native(hash_view, temporary)
      File.delete(path)
      File.rename(temporary, path)
      yield
    ensure
      File.binwrite(path, original_bytes)
      File.delete(temporary) if File.exist?(temporary)
    end
  end

  def self.transfer_matches?(event, name, x, y, parameters)
    page = event.pages.first if event.respond_to?(:pages) && event.pages.is_a?(Array) &&
      event.pages.length == 1
    commands = page.list if page && page.list.is_a?(Array)
    event.is_a?(RPG::Event) && event.name == name &&
      event.x == x && event.y == y && page && page.trigger == 1 &&
      page.through == false && page.always_on_top == false &&
      commands && commands.length == 2 &&
      commands[0].code == 201 && commands[0].indent == 0 &&
      commands[0].parameters == parameters &&
      commands[1].code == 0 && commands[1].indent == 0 &&
      commands[1].parameters == []
  end

  def self.validate_hns_import_result!(plan, hns_config, result)
    gate_id = plan["map_targets"]["reception_gate"]["id"]
    map = load_native(native_map_path(gate_id))
    check(result == gate_id && map.width == 22 && map.height == 21 &&
      map.events.is_a?(Hash) && map.events.values.count { |event| event.name.start_with?("Exit ") } == 5,
      "HnS importer returned false success or created an incomplete gate map")
    hns_config["warps"].each do |warp|
      target = warp["target"]
      parameters = [0, target["map_id"], target["x"], target["y"],
        target["direction"], target["fade"]]
      matches = map.events.values.select do |event|
        transfer_matches?(event, "Exit #{warp['direction']}", warp["x"], warp["y"], parameters)
      end
      check(matches.length == 1,
        "HnS exit differs from the converted transfer: #{warp['direction']} at #{warp['x']},#{warp['y']}")
    end
    true
  end

  def self.validate_install_results!(plan, configs, results)
    gate_id = plan["map_targets"]["reception_gate"]["id"]
    route_id = plan["map_targets"]["route22"]["id"]
    links = results[1]
    event_count = configs["world_links"]["events"].length
    check(links.is_a?(Hash) && links["created"] == event_count &&
      links["unchanged"] == 0 &&
      links["changed_maps"].sort == [gate_id, route_id].sort,
      "World Links returned false success or an unexpected partial installation")

    story = results[2]
    check(story.is_a?(Hash) && story["map_id"] == gate_id &&
      story["installed"] == ["collapse", "aipom", "johto_block"],
      "Gate Story returned false success or an unexpected partial installation")

    route = results[3]
    check(route.is_a?(Hash) && route["map_id"] == route_id && route["installed"] == 6,
      "Route22 returned false success or an unexpected partial installation")
    validate_installed_maps!(plan, configs)
  end

  def self.validate_story_event!(map, config, name, script, trigger, character = nil)
    position = config["positions"][name]
    event_name = "SHATTERED_GATE:#{name}"
    matches = map.events.values.select { |event| event.name == event_name }
    check(matches.length == 1, "Gate Story event missing or duplicated: #{event_name}")
    expected = ShatteredGateStory.scene_event(
      position["x"], position["y"], name, script, trigger, character
    )
    expected.id = matches.first.id
    check(ShatteredGateStory.same_event?(matches.first, expected),
      "Gate Story event differs from reviewed config: #{event_name}")
  end

  def self.validate_installed_maps!(plan, configs)
    gate_id = plan["map_targets"]["reception_gate"]["id"]
    route_id = plan["map_targets"]["route22"]["id"]
    infos = load_native("Data/MapInfos.rxdata")
    check(infos.is_a?(Hash) && (infos.key?(gate_id) || infos.key?(gate_id.to_s)) &&
      (infos.key?(route_id) || infos.key?(route_id.to_s)),
      "Installed map IDs are missing from MapInfos")
    gate_map = load_native(native_map_path(gate_id))
    check(gate_map.width == 22 && gate_map.height == 21 && gate_map.events.is_a?(Hash),
      "Installed reception gate map has invalid geometry or events")
    remaining_warps = configs["hns_import"]["warps"].reject do |warp|
      warp["direction"] == "south"
    end
    expected_warp_names = remaining_warps.map { |warp| "Exit #{warp['direction']}" }.sort
    actual_warp_names = gate_map.events.values.map(&:name).grep(/\AExit /).sort
    check(actual_warp_names == expected_warp_names,
      "Gate Story did not preserve the unblocked HnS exits")
    remaining_warps.each do |warp|
      name = "Exit #{warp['direction']}"
      matches = gate_map.events.values.select do |event|
        event.name == name && event.x == warp["x"] && event.y == warp["y"]
      end
      target = warp["target"]
      parameters = [0, target["map_id"], target["x"], target["y"],
        target["direction"], target["fade"]]
      check(matches.length == 1 && transfer_matches?(
        matches.first, name, warp["x"], warp["y"], parameters
      ),
        "HnS exit differs from the reviewed transfer: #{name} at #{warp['x']},#{warp['y']}")
    end

    south = configs["hns_import"]["warps"].find { |warp| warp["direction"] == "south" }
    blocked_script = "ShatteredGateStory.blocked_johto"
    validate_story_event!(gate_map, configs["gate_story"], "johto_block",
      blocked_script, 1)
    check(!gate_map.events.values.any? do |event|
      event.name == "Exit south" && event.x == south["x"] && event.y == south["y"]
    end, "Original HnS south exit remains beside its blocker")
    %w[collapse aipom].each do |name|
      config = configs["gate_story"]
      script = if name == "collapse"
        sounds = config["collapse_sounds"][0, ShatteredGateStory::MAX_IMPACTS]
        "ShatteredGateStory.run_collapse(#{sounds.inspect}, #{config['final_roar_sound'].inspect})"
      else
        "ShatteredGateStory.run_aipom(#{config['aipom_cry'].inspect})"
      end
      validate_story_event!(gate_map, config, name, script,
        name == "aipom" ? 0 : 1,
        name == "aipom" ? config["aipom_character"] : nil)
    end

    maps = {
      gate_id => gate_map,
      route_id => load_native(native_map_path(route_id))
    }
    configs["world_links"]["events"].each do |entry|
      map = maps[entry["map_id"]]
      name = "SHATTERED_LINK:#{entry['link_id']}:#{entry['side']}"
      matches = map.events.values.select { |event| event.name == name }
      check(matches.length == 1 &&
        matches.first.x == entry["x"] && matches.first.y == entry["y"] &&
        transfer_matches?(matches.first, name, entry["x"], entry["y"],
          [0, entry["destination"]["map_id"], entry["destination"]["x"],
            entry["destination"]["y"], entry["destination"]["direction"],
            entry["destination"]["fade"]]) &&
        ShatteredWorldLinks.event_matches?(matches.first, entry),
        "World Links event differs from reviewed transfer: #{name}")
    end

    route_map = load_native(native_map_path(route_id))
    check(route_map.width == 48 && route_map.height == 24 && route_map.events.is_a?(Hash),
      "Installed Route22 map has invalid geometry or events")
    npc_events = (0..2).map do |index|
      name = "SHATTERED_ROUTE22:rattata_#{index}"
      matches = route_map.events.values.select { |event| event.name == name }
      check(matches.length == 1, "Route22 NPC missing or duplicated: #{name}")
      matches.first
    end
    npc_ids = npc_events.map(&:id)
    route_config = configs["route22"]
    expected_events = ShatteredRoute22::NPCS.each_with_index.map do |point, index|
      ShatteredRoute22.build_npc(
        *point, index, route_config["rattata_character"],
        route_config["cleared_switch"]
      )
    end
    expected_events.concat(ShatteredRoute22::TRIGGERS.each_with_index.map do |point, index|
      ShatteredRoute22.build_trigger(*point, index, npc_ids, route_config)
    end)
    expected_events.each do |expected|
      actual = route_map.events.values.find { |event| event.name == expected.name }
      check(actual, "Route22 event missing: #{expected.name}")
      expected.id = actual.id
      check(Marshal.dump(actual) == Marshal.dump(expected),
        "Route22 event differs from the pinned installer: #{expected.name}")
    end
    expected_route_events = expected_events.map(&:name).sort
    actual_route_events = route_map.events.values.map(&:name).grep(/\ASHATTERED_ROUTE22:/).sort
    check(actual_route_events == expected_route_events,
      "Route22 events are missing, duplicated, or foreign")
  end

  def self.validate_receipt_inventory!(plan, receipt)
    check(receipt["status"] == "native_install_complete" &&
      receipt["plan_sha256"] == PLAN_SHA256 &&
      receipt["source_pins"] == plan["source_pins"] &&
      receipt["installer_apis"] == INSTALLER_ORDER &&
      receipt["gameplay_verified"] == false &&
      receipt["save_reload_verified"] == false &&
      receipt["android_joiplay_verified"] == false,
      "Native installation receipt does not match this pinned plan")
    installed_files = receipt["installed_files"]
    expected_paths = transaction_paths(plan).sort
    check(installed_files.is_a?(Hash) && installed_files.keys.sort == expected_paths,
      "Native installation receipt has an incomplete file inventory")
    check(installed_files.values.all? { |digest| digest.is_a?(String) &&
      digest.match?(/\A[0-9a-f]{64}\z/) },
      "Native installation receipt contains an invalid file hash")
    receipt
  end

  def self.verify_receipt!(plan, configs)
    check(!File.directory?(ROLLBACK_DIR),
      "Native installation rollback data remains; manual recovery is required")
    check(!File.exist?(RECEIPT_PATH + ".tmp") && !File.symlink?(RECEIPT_PATH + ".tmp"),
      "Stale native installation receipt temp requires manual recovery")
    check(!File.exist?("Plugins/Shattered Initial Slice Installer/route22.runtime.json") &&
      !File.symlink?("Plugins/Shattered Initial Slice Installer/route22.runtime.json"),
      "Stale dynamic Route22 config requires manual recovery")
    check(file_sha(safe_file!(PLAN_PATH)) == PLAN_SHA256,
      "Native installation plan changed after installation")
    receipt = validate_receipt_inventory!(plan, json_file(RECEIPT_PATH))
    installed_files = receipt["installed_files"]
    installed_files.each do |path, digest|
      check(File.file?(path) && file_sha(path) == digest,
        "Installed native map data changed since receipt: #{path}")
    end
    validate_installed_maps!(plan, configs)
    receipt
  end

  def self.rollback_after_error!(error)
    begin
      [RECEIPT_PATH, RECEIPT_PATH + ".tmp"].each do |path|
        check(!File.symlink?(path), "Receipt path became a symlink; preserve #{ROLLBACK_DIR}")
        File.delete(path) if File.exist?(path)
      end
      restore_transaction!
    rescue Exception => rollback_error
      raise "#{error.message}; rollback requires recovery (#{rollback_error.message})"
    end
    raise error
  end

  def self.install
    check(!File.exist?(ROLLBACK_DIR) && !File.symlink?(ROLLBACK_DIR),
      "Interrupted native installation requires manual recovery")
    check(!File.symlink?(RECEIPT_PATH),
      "Native installation receipt path is a symlink")
    if File.file?(RECEIPT_PATH)
      plan, configs, _marker = validate_plan!(false)
      return verify_receipt!(plan, configs)
    end
    plan, configs, _marker = validate_plan!
    plan, = preflight_native!(plan, configs)
    begin_transaction!(transaction_paths(plan))
    results = []
    begin
      results << call_api("pbInstallShatteredHNSReceptionGate")
      validate_hns_import_result!(plan, configs["hns_import"], results.last)
      results << call_api("pbInstallShatteredWorldLinks",
        plan["config_paths"]["world_links"])
      results << with_tileset_hash_view do
        call_api("pbInstallShatteredGateStory", plan["config_paths"]["gate_story"])
      end

      route_config = configs["route22"].dup
      route_config["expected_map_sha256"] = file_sha(native_map_path(
        plan["map_targets"]["route22"]["id"]))
      dynamic_path = "Plugins/Shattered Initial Slice Installer/route22.runtime.json"
      check(!File.exist?(dynamic_path) && !File.symlink?(dynamic_path),
        "Stale dynamic Route22 config exists")
      File.write(dynamic_path, JSON.generate(route_config))
      begin
        results << call_api("pbInstallShatteredRoute22", dynamic_path)
      ensure
        File.delete(dynamic_path) if File.exist?(dynamic_path)
      end
      validate_install_results!(plan, configs, results)
      installed_paths = transaction_paths(plan)
      receipt = {
        "schema_version" => 1,
        "status" => "native_install_complete",
        "plan_sha256" => PLAN_SHA256,
        "source_pins" => plan["source_pins"],
        "installer_apis" => INSTALLER_ORDER,
        "installed_files" => installed_paths.each_with_object({}) do |path, result|
          result[path] = file_sha(path)
        end,
        "gameplay_verified" => false,
        "save_reload_verified" => false,
        "android_joiplay_verified" => false
      }
      temporary_receipt = RECEIPT_PATH + ".tmp"
      check(!File.exist?(temporary_receipt) && !File.symlink?(temporary_receipt),
        "Stale native installation receipt temp")
      File.write(temporary_receipt, JSON.pretty_generate(receipt) + "\n")
      File.rename(temporary_receipt, RECEIPT_PATH)
      FileUtils.remove_entry(ROLLBACK_DIR)
      receipt
    rescue Exception => error
      rollback_after_error!(error)
    end
  end
end

def pbInstallShatteredInitialSlice
  ShatteredInitialSlice.install
end
