#!/usr/bin/env python3
"""Verify pinned Shattered feature sources and build a private Essentials staging copy."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "development" / "shattered_integration_manifest.json"
LOCK_NAME = ".shattered-integration-source.json"
HEX_40 = re.compile(r"^[0-9a-f]{40}$")
HEX_64 = re.compile(r"^[0-9a-f]{64}$")
ALLOWED_ARCHIVE_ROOTS = {"Audio", "Graphics", "Plugins", "Data", "PBS"}
MAX_ARCHIVE_ENTRIES = 20000
MAX_ARCHIVE_BYTES = 600 * 1024 * 1024
MAX_ENTRY_BYTES = 80 * 1024 * 1024
RUBY_HOOK_PATTERNS = {
    "Battle::Battler#pbCanChooseMove?": re.compile(r"\bdef\s+pbCanChooseMove\?"),
    "Battle::Battler#pbTryUseMove": re.compile(r"\bdef\s+pbTryUseMove\b"),
    "Battle::Battler#pbReducePP": re.compile(r"\bdef\s+pbReducePP\b"),
    "Battle::Battler#pbReducePPOther": re.compile(r"\bdef\s+pbReducePPOther\b"),
    "ItemHandlers::CanUseInBattle:POKEBALL": re.compile(r"ItemHandlers::CanUseInBattle\.add"),
    "EventHandlers:on_game_map_setup:shattered_core_ensure_human": re.compile(
        r"EventHandlers\.add\(\s*:on_game_map_setup,\s*:shattered_core_ensure_human"
    ),
    "EventHandlers:on_start_battle:shattered_core_battle_hooks": re.compile(
        r"EventHandlers\.add\(\s*:on_start_battle,\s*:shattered_core_battle_hooks"
    ),
    "EventHandlers:on_game_map_setup:shattered_raid_switch_sync": re.compile(
        r"EventHandlers\.add\(\s*:on_game_map_setup,\s*:shattered_raid_switch_sync"
    ),
    "EventHandlers:on_start_battle:shattered_equipment_battle_hook": re.compile(
        r"EventHandlers\.add\(\s*:on_start_battle,\s*:shattered_equipment_battle_hook"
    ),
    "Battle::Battler#pbInitPokemon": re.compile(r"\bdef\s+pbInitPokemon\b"),
    "Pokemon#calc_stats": re.compile(r"\bdef\s+calc_stats\b"),
    "Pokemon#calcStat": re.compile(r"\bdef\s+calcStat\b"),
    "Pokemon#calcHP": re.compile(r"\bdef\s+calcHP\b"),
}


class IntegrationError(ValueError):
    pass


def _ruby_hook_counts(text):
    return {
        claim: len(pattern.findall(text))
        for claim, pattern in RUBY_HOOK_PATTERNS.items()
        if pattern.search(text)
    }


def load_manifest(path=MANIFEST_PATH):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise IntegrationError(f"cannot read integration manifest: {exc}") from exc


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def regular_file(root, relative, label):
    root = Path(root).resolve()
    rel = safe_relative(relative, label)
    path = root
    for part in rel.parts:
        path = path / part
        if path.is_symlink():
            raise IntegrationError(f"symlink rejected for {label}: {relative}")
    if not path.is_file():
        raise IntegrationError(f"missing regular file for {label}: {relative}")
    return path


def project_tree_digest(project):
    root = Path(project).resolve()
    records, folded = [], set()
    for current, dirs, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        if current_path == root and ".git" in dirs:
            dirs.remove(".git")
        for directory in list(dirs):
            candidate = current_path / directory
            if candidate.is_symlink():
                raise IntegrationError(f"project symlink directory rejected: {candidate.relative_to(root)}")
        for name in files:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            safe_relative(relative, "project file")
            if path.is_symlink() or not path.is_file():
                raise IntegrationError(f"project symlink or special file rejected: {relative}")
            folded_path = relative.casefold()
            if folded_path in folded:
                raise IntegrationError(f"case-insensitive project path collision: {relative}")
            folded.add(folded_path)
            records.append((relative, sha256(path)))
    records.sort()
    digest = hashlib.sha256()
    for relative, file_hash in records:
        digest.update(relative.encode("utf-8") + b"\0" + bytes.fromhex(file_hash) + b"\n")
    return {"sha256": digest.hexdigest(), "file_count": len(records)}


def safe_relative(value, label="path"):
    if (
        not isinstance(value, str) or not value or "\x00" in value or "\\" in value
        or value.startswith("/") or re.match(r"^[a-zA-Z]:", value)
        or any(part in ("", ".", "..") for part in value.split("/"))
    ):
        raise IntegrationError(f"invalid {label}: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts:
        raise IntegrationError(f"unsafe {label}: {value}")
    return Path(*path.parts)


def _topological_order(nodes, deps, label):
    result, active, done = [], set(), set()

    def visit(node):
        if node in active:
            raise IntegrationError(f"{label} dependency cycle at {node}")
        if node in done:
            return
        if node not in nodes:
            raise IntegrationError(f"{label} dependency is missing: {node}")
        active.add(node)
        for dependency in deps[node]:
            visit(dependency)
        active.remove(node)
        done.add(node)
        result.append(node)

    for node in nodes:
        visit(node)
    return result


def validate_manifest(manifest):
    if manifest.get("schema_version") != 1:
        raise IntegrationError("unsupported integration manifest schema")
    if manifest.get("engine", {}).get("version") != "21.1":
        raise IntegrationError("manifest must pin Pokémon Essentials 21.1")

    prs = manifest.get("pull_requests", [])
    pr_by_id = {pr.get("id"): pr for pr in prs}
    if len(pr_by_id) != len(prs) or not prs:
        raise IntegrationError("duplicate or empty pull request source list")
    main = manifest.get("main", {})
    if not HEX_40.fullmatch(main.get("commit", "")):
        raise IntegrationError("main commit must be a full 40-character SHA")
    inspected = manifest.get("inspected_main", {})
    if inspected.get("commit") != main["commit"]:
        raise IntegrationError("inspected main commit is stale relative to pinned main")
    merged_ids = sorted(pr["id"] for pr in prs if pr.get("state") == "merged")
    if sorted(inspected.get("merged_feature_prs", [])) != merged_ids:
        raise IntegrationError("merged PR ledger differs from pinned source states")
    pr_deps = {}
    for pr in prs:
        pid = pr.get("id")
        if not isinstance(pid, int) or not HEX_40.fullmatch(pr.get("head", "")):
            raise IntegrationError(f"PR {pid}: invalid pinned head")
        if not HEX_40.fullmatch(pr.get("base", "")):
            raise IntegrationError(f"PR {pid}: invalid pinned base")
        parent_id = pr.get("ancestry_parent")
        if parent_id is None:
            if pr.get("base_ref") != main.get("ref"):
                raise IntegrationError(f"PR {pid}: unexpected base branch/commit")
        else:
            parent = pr_by_id.get(parent_id)
            if not parent or pr["base_ref"] != parent["branch"] or pr["base"] != parent["head"]:
                raise IntegrationError(f"PR {pid}: wrong branch ancestry/base commit")
            if parent_id not in pr.get("build_requires", []):
                raise IntegrationError(f"PR {pid}: ancestry parent missing from build requirements")
        pr_deps[pid] = pr.get("build_requires", [])
    _topological_order(pr_by_id, pr_deps, "PR")

    sources = manifest.get("required_source_files", [])
    source_keys = [(item.get("pr"), item.get("path")) for item in sources]
    if len(source_keys) != len(set(source_keys)):
        raise IntegrationError("duplicate PR source file declaration")
    for pid, path in source_keys:
        if pid not in pr_by_id:
            raise IntegrationError(f"source file references unknown PR {pid}")
        safe_relative(path, "source file")
    source_key_set = set(source_keys)
    for suite in manifest.get("contract_test_suites", []):
        if suite.get("pr") not in pr_by_id or not suite.get("commands"):
            raise IntegrationError("contract test suite references an unknown PR or has no commands")
        for command in suite["commands"]:
            if not isinstance(command, list) or not command or any(
                not isinstance(part, str) or not part for part in command
            ):
                raise IntegrationError(f"PR {suite['pr']}: invalid contract test command")
            test_path = None
            if command[0] == "ruby" and len(command) > 1:
                test_path = command[1]
            elif "-p" in command:
                test_pattern = command[command.index("-p") + 1]
                test_dir = command[command.index("-s") + 1] if "-s" in command else "tests"
                if not any(char in test_pattern for char in "*?["):
                    test_path = str(Path(test_dir) / test_pattern)
            if test_path and (suite["pr"], test_path) not in source_key_set:
                raise IntegrationError(
                    f"PR {suite['pr']}: contract test source is not allow-listed: {test_path}"
                )
    protected_paths = {
        "development/integration_queue.json",
        "development/plugin_manifest.json",
        "scripts/stage_essentials.py",
    }
    if protected_paths & {path for _, path in source_keys}:
        raise IntegrationError("source allow-list includes a protected integration-owned file")
    staged_paths = [
        Path(item["path"]).relative_to("essentials").as_posix()
        for item in sources
        if item.get("stage") and item["path"].startswith("essentials/")
    ]
    if len(staged_paths) != len(set(staged_paths)):
        raise IntegrationError("conflicting staged source files target the same project path")

    queue_task = manifest.get("queue_task", {})
    if queue_task.get("id") != "SE-024" or not queue_task.get("title"):
        raise IntegrationError("manifest must identify its SE-024 queue ownership")

    components = manifest.get("components", [])
    component_by_id = {item.get("id"): item for item in components}
    if len(component_by_id) != len(components) or not components:
        raise IntegrationError("duplicate or empty integration component list")
    plugin_names = [item.get("name") for item in components]
    if len(plugin_names) != len(set(plugin_names)):
        raise IntegrationError("duplicate plugin name")
    installed_archive_names = {
        item["name"] for item in manifest.get("plugin_archives", [])
        if item.get("required") or item.get("install") is True
    }
    all_plugin_names = plugin_names + sorted(installed_archive_names)
    if len(all_plugin_names) != len(set(all_plugin_names)):
        raise IntegrationError("duplicate plugin name across first-party and archive plugins")
    if set(plugin_names) | installed_archive_names != set(manifest.get("load_order", [])):
        raise IntegrationError("plugin load order does not exactly cover declared plugins")
    if len(manifest["load_order"]) != len(set(manifest["load_order"])):
        raise IntegrationError("duplicate plugin load-order entry")
    load_positions = {name: index for index, name in enumerate(manifest["load_order"])}
    for archive in manifest.get("plugin_archives", []):
        if not (archive.get("required") or archive.get("install") is True):
            continue
        for dependency in archive.get("depends_on", []):
            dependency_spec = next(
                (item for item in manifest["plugin_archives"] if item.get("id") == dependency), None
            )
            if not dependency_spec or load_positions[dependency_spec["name"]] >= load_positions[archive["name"]]:
                raise IntegrationError(f"plugin load-order clash: {archive['name']} before dependency {dependency}")

    hook_owners = {}
    for component in components:
        pid = component.get("pr")
        if pid not in pr_by_id:
            raise IntegrationError(f"{component.get('id')}: unknown source PR")
        if not set(component.get("build_requires", [])) <= set(pr_by_id):
            raise IntegrationError(f"{component['id']}: unknown build dependency")
        for required_pr in component.get("build_requires", []):
            dependency_component = next(
                (item for item in components if item.get("pr") == required_pr), None
            )
            if dependency_component and load_positions[dependency_component["name"]] >= load_positions[component["name"]]:
                raise IntegrationError(
                    f"plugin load-order clash: {component['name']} before {dependency_component['name']}"
                )
        for claim in component.get("hook_claims", []):
            if claim in hook_owners:
                raise IntegrationError(
                    f"duplicate hook claim {claim}: {hook_owners[claim]} and {component['id']}"
                )
            hook_owners[claim] = component["id"]

    # A map may be created once and then modified only by a component that is
    # explicitly ordered after the earlier writer.
    for index, before in enumerate(components):
        for after in components[index + 1:]:
            before_slots = {write["slot"] for write in before.get("map_writes", [])}
            after_slots = {write["slot"] for write in after.get("map_writes", [])}
            overlap = before_slots & after_slots
            if not overlap:
                continue
            closure = set()
            stack = list(after.get("build_requires", []))
            while stack:
                dependency = stack.pop()
                if dependency in closure:
                    continue
                closure.add(dependency)
                stack.extend(pr_by_id[dependency].get("build_requires", []))
            if before["pr"] not in closure:
                raise IntegrationError(
                    f"unordered overlapping map writes: {before['id']} -> {after['id']} ({sorted(overlap)})"
                )

    archives = manifest.get("plugin_archives", [])
    archive_by_id = {item.get("id"): item for item in archives}
    if len(archive_by_id) != len(archives):
        raise IntegrationError("duplicate plugin archive ID")
    archive_deps = {key: item.get("depends_on", []) for key, item in archive_by_id.items()}
    _topological_order(archive_by_id, archive_deps, "plugin archive")
    event_names, event_prefixes = [], []
    for component in components:
        for contract in component.get("event_contracts", []):
            event_names.extend(contract.get("event_names", []))
            if contract.get("event_prefix"):
                event_prefixes.append(contract["event_prefix"])
            if contract.get("event_name"):
                event_names.append(contract["event_name"])
    if len(event_names) != len(set(event_names)):
        raise IntegrationError("duplicate native event name contract")
    if len(event_prefixes) != len(set(event_prefixes)):
        raise IntegrationError("duplicate native event prefix contract")
    for slot, info in manifest.get("target_map_slots", {}).items():
        dimensions = info.get("dimensions")
        if dimensions is not None and (
            len(dimensions) != 2 or any(not isinstance(value, int) or value <= 0 for value in dimensions)
        ):
            raise IntegrationError(f"{slot}: invalid source map dimensions")
    for profile_name, profile in manifest.get("profiles", {}).items():
        if not profile_name or not isinstance(profile, dict):
            raise IntegrationError("invalid integration profile")
        for key, available in (
            ("components", {item["id"] for item in components}),
            ("source_prs", set(pr_by_id)),
            ("map_slots", set(manifest.get("target_map_slots", {}))),
            ("archives", set(archive_by_id)),
            ("assets", {item["id"] for item in manifest.get("asset_requirements", [])}),
            ("source_projects", {item["id"] for item in manifest.get("source_projects", [])}),
            ("switch_ids", set(manifest["runtime_resources"]["switch_ids"])),
            ("variable_ids", set(manifest["runtime_resources"]["variable_ids"])),
        ):
            selected = profile.get(key, [])
            if not isinstance(selected, list) or len(selected) != len(set(selected)) or not set(selected) <= available:
                raise IntegrationError(f"profile {profile_name}: invalid {key}")
    return {
        "pull_requests": len(prs),
        "components": len(components),
        "source_files": len(sources),
        "map_slots": len(manifest.get("target_map_slots", {})),
        "load_order": manifest["load_order"],
    }


def validate_queue(queue, manifest):
    tasks = queue.get("tasks", [])
    identifiers = [task.get("id") for task in tasks]
    if len(identifiers) != len(set(identifiers)):
        raise IntegrationError("duplicate integration queue task ID")
    expected = manifest["queue_task"]
    matches = [task for task in tasks if task.get("id") == expected["id"]]
    if matches and matches[0].get("title") != expected["title"]:
        raise IntegrationError(f"integration queue ID collision: {expected['id']}")
    return {"queue_task_id": expected["id"], "queue_collision": False}


def _git(repo, *args, binary=False):
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode:
        message = result.stderr.decode("utf-8", "replace").strip()
        raise IntegrationError(f"git {' '.join(args)} failed: {message}")
    return result.stdout if binary else result.stdout.decode("utf-8").strip()


def _resolve_branch(repo, branch, pr_id=None):
    refs = [f"refs/remotes/origin/{branch}", f"refs/heads/{branch}"]
    if pr_id is not None:
        refs.extend((f"refs/pull/{pr_id}/head", f"refs/remotes/integration/pr-{pr_id}"))
    for ref in refs:
        try:
            return _git(repo, "rev-parse", "--verify", ref)
        except IntegrationError:
            pass
    raise IntegrationError(f"missing fetched source branch/ref: {branch}")


def _verify_git_refs(repo, manifest, selected_prs=None):
    main = manifest["main"]
    if _resolve_branch(repo, main["ref"]) != main["commit"]:
        raise IntegrationError("fetched main ref does not match pinned commit")
    for pr in manifest["pull_requests"]:
        if selected_prs is not None and pr["id"] not in selected_prs:
            continue
        if _resolve_branch(repo, pr["branch"], pr["id"]) != pr["head"]:
            raise IntegrationError(f"PR #{pr['id']} branch no longer matches pinned head")
        _git(repo, "cat-file", "-e", f"{pr['base']}^{{commit}}")
        _git(repo, "merge-base", "--is-ancestor", pr["base"], pr["head"])
        if pr["ancestry_parent"] is None:
            _git(repo, "merge-base", "--is-ancestor", pr["base"], main["commit"])


def _profile_config(manifest, profile):
    if profile is None:
        return {
            "components": [item["id"] for item in manifest["components"]],
            "source_prs": [item["id"] for item in manifest["pull_requests"]],
            "map_slots": list(manifest["target_map_slots"]),
            "archives": [item["id"] for item in manifest["plugin_archives"] if item.get("required") or item.get("install")],
            "assets": [item["id"] for item in manifest["asset_requirements"] if item.get("required")],
            "source_projects": [],
            "switch_ids": list(manifest["runtime_resources"]["switch_ids"]),
            "variable_ids": list(manifest["runtime_resources"]["variable_ids"]),
        }
    profiles = manifest.get("profiles", {})
    if profile not in profiles:
        raise IntegrationError(f"unknown integration profile: {profile}")
    return profiles[profile]


def export_sources(repo, output, manifest, profile=None):
    validate_manifest(manifest)
    repo, output = Path(repo).resolve(), Path(output).resolve()
    if output.exists():
        raise IntegrationError("source export output must be a fresh directory")
    if output == repo or output in repo.parents or repo in output.parents:
        raise IntegrationError("source export output and Git repository must be separate")
    selected = _profile_config(manifest, profile)
    selected_prs = set(selected["source_prs"])
    _verify_git_refs(repo, manifest, selected_prs)
    pr_by_id = {pr["id"]: pr for pr in manifest["pull_requests"]}
    temp_parent = output.parent
    temp_parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix=".shattered-sources-", dir=temp_parent))
    try:
        files = {}
        for item in manifest["required_source_files"]:
            if item["pr"] not in selected_prs:
                continue
            pid, source_path = item["pr"], item["path"]
            content = _git(repo, "show", f"{pr_by_id[pid]['head']}:{source_path}", binary=True)
            bundle_rel = Path(f"pr-{pid}") / safe_relative(source_path, "source file")
            destination = temp / bundle_rel
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content)
            files[f"{pid}:{source_path}"] = hashlib.sha256(content).hexdigest()
        lock = {
            "schema_version": 1,
            "git_verified": True,
            "profile": profile,
            "pull_requests": _source_lock_record(manifest, selected_prs),
            "files": files,
        }
        (temp / LOCK_NAME).write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temp, output)
    except Exception:
        shutil.rmtree(temp, ignore_errors=True)
        raise
    return {"exported_files": len(files), "git_verified": True, "source_bundle": str(output)}


def _source_lock_record(manifest, selected_prs=None):
    return [
        {key: pr[key] for key in ("id", "branch", "head", "base_ref", "base", "ancestry_parent")}
        for pr in manifest["pull_requests"]
        if selected_prs is None or pr["id"] in selected_prs
    ]


def verify_source_bundle(source_root, manifest, synthetic_fixture=False, profile=None):
    root = Path(source_root).resolve()
    lock_path = root / LOCK_NAME
    if not lock_path.is_file() or lock_path.is_symlink():
        raise IntegrationError(f"missing pinned source lock: {LOCK_NAME}")
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise IntegrationError(f"invalid source lock: {exc}") from exc
    selected_prs = set(_profile_config(manifest, profile)["source_prs"])
    if lock.get("schema_version") != 1 or lock.get("profile") != profile or lock.get(
        "pull_requests"
    ) != _source_lock_record(manifest, selected_prs):
        raise IntegrationError("source lock PR branches/commits/ancestry differ from pinned manifest")
    if synthetic_fixture:
        if not lock.get("synthetic_fixture"):
            raise IntegrationError("--synthetic-fixture requires a fixture-marked source lock")
    elif not lock.get("git_verified"):
        raise IntegrationError("source lock was not generated from verified pinned Git commits")

    selected_sources = [
        item for item in manifest["required_source_files"] if item["pr"] in selected_prs
    ]
    expected = {f"{item['pr']}:{item['path']}" for item in selected_sources}
    if set(lock.get("files", {})) != expected:
        raise IntegrationError("source lock file inventory differs from manifest allow-list")
    for key in sorted(expected):
        pid, source_path = key.split(":", 1)
        path = regular_file(root, f"pr-{pid}/{source_path}", f"PR {pid} source file")
        digest = lock["files"][key]
        if not HEX_64.fullmatch(digest) or sha256(path) != digest:
            raise IntegrationError(f"source file hash mismatch: PR {pid} {source_path}")
    if not synthetic_fixture:
        _verify_first_party_hooks(root, manifest, set(_profile_config(manifest, profile)["components"]))
    return lock


def _verify_first_party_hooks(source_root, manifest, component_ids=None):
    components = [
        component for component in manifest["components"]
        if component_ids is None or component["id"] in component_ids
    ]
    component_by_pr = {component["pr"]: component for component in components}
    counts_by_component = {}
    for item in manifest["required_source_files"]:
        if not item.get("stage") or not item["path"].lower().endswith(".rb"):
            continue
        component = component_by_pr.get(item["pr"])
        if not component:
            continue
        source = regular_file(source_root, f"pr-{item['pr']}/{item['path']}", "plugin source")
        text = source.read_text(encoding="utf-8", errors="replace")
        counts = counts_by_component.setdefault(component["id"], {})
        for claim, count in _ruby_hook_counts(text).items():
            counts[claim] = counts.get(claim, 0) + count
    owners = {}
    for component in components:
        component_id = component["id"]
        counts = counts_by_component.get(component_id, {})
        repeated = [claim for claim, count in counts.items() if count > 1]
        if repeated:
            raise IntegrationError(f"duplicate compatibility hook definitions in {component_id}: {repeated}")
        declared = set(component.get("hook_claims", []))
        undeclared = set(counts) - declared
        if undeclared:
            raise IntegrationError(f"unlisted compatibility hooks in {component_id}: {sorted(undeclared)}")
        for claim in declared:
            if claim in owners:
                raise IntegrationError(f"duplicate compatibility hook {claim}: {owners[claim]} and {component_id}")
            owners[claim] = component_id


def _parse_meta(text):
    values = {}
    for line in text.splitlines():
        match = re.match(r"^\s*(Name|Version)\s*=\s*(.*?)\s*$", line, re.I)
        if match:
            values[match.group(1).lower()] = match.group(2)
    return values


def _pbs_sections(path):
    return re.findall(r"^\[([A-Z0-9_]+)\]\s*$", path.read_text(encoding="utf-8-sig"), re.M)


def _archive_members(path):
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        if len(members) > MAX_ARCHIVE_ENTRIES or sum(item.file_size for item in members) > MAX_ARCHIVE_BYTES:
            raise IntegrationError(f"plugin archive exceeds safety limits: {path}")
        seen, metas, hooks = set(), [], {}
        for member in members:
            name = member.filename.replace("\\", "/")
            if name.startswith("/") or re.match(r"^[a-zA-Z]:", name):
                raise IntegrationError(f"absolute archive path: {name}")
            parts = PurePosixPath(name).parts
            if any(part in ("", ".", "..") for part in parts):
                raise IntegrationError(f"unsafe archive path: {name}")
            if parts and parts[0] not in ALLOWED_ARCHIVE_ROOTS:
                if len(parts) < 2 or parts[1] not in ALLOWED_ARCHIVE_ROOTS:
                    raise IntegrationError(f"unsupported archive destination: {name}")
                name = "/".join(parts[1:])
                parts = PurePosixPath(name).parts
            if not parts or parts[0] not in ALLOWED_ARCHIVE_ROOTS:
                raise IntegrationError(f"unsupported archive destination: {name}")
            mode = (member.external_attr >> 16) & 0o170000
            if mode == stat.S_IFLNK:
                raise IntegrationError(f"archive symlink rejected: {name}")
            if member.file_size > MAX_ENTRY_BYTES:
                raise IntegrationError(f"oversized archive member: {name}")
            if member.is_dir():
                continue
            if name in seen:
                raise IntegrationError(f"duplicate archive member: {name}")
            seen.add(name)
            if (parts[0] == "PBS" and PurePosixPath(name).name == "pokemon.txt") or (
                parts[0] == "Data" and PurePosixPath(name).name == "Scripts.rxdata"
            ):
                raise IntegrationError(f"refusing to replace protected engine file: {name}")
            if PurePosixPath(name).name.lower() == "meta.txt":
                metas.append(_parse_meta(archive.read(member).decode("utf-8-sig", "replace")))
            if name.lower().endswith(".rb"):
                script = archive.read(member).decode("utf-8", "replace")
                for claim, count in _ruby_hook_counts(script).items():
                    hooks[claim] = hooks.get(claim, 0) + count
        duplicates = {claim for claim, count in hooks.items() if count > 1}
        if duplicates:
            raise IntegrationError(f"duplicate hook definitions within archive: {sorted(duplicates)}")
        return metas, hooks


def _verify_rights_record(inputs, record, expected_id, expected_type):
    record_path = regular_file(inputs, record.get("rights_record"), "rights record")
    digest = record.get("rights_record_sha256")
    if not isinstance(digest, str) or not HEX_64.fullmatch(digest) or sha256(record_path) != digest:
        raise IntegrationError(f"rights record hash mismatch: {expected_id}")
    try:
        details = json.loads(record_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise IntegrationError(f"invalid local rights record: {expected_id}") from exc
    if (
        details.get("id") != expected_id
        or details.get("type") != expected_type
        or details.get("rights_cleared") is not True
        or not all(isinstance(details.get(key), str) and details[key].strip()
                   for key in ("source", "license", "basis"))
    ):
        raise IntegrationError(f"rights record is incomplete or not cleared: {expected_id}")
    return digest


def diagnose_preflight(project, source_root, inputs, plan, manifest, profile):
    profile_config = _profile_config(manifest, profile)
    project, source_root, inputs = (
        Path(project).resolve(), Path(source_root).resolve(), Path(inputs).resolve()
    )
    blockers = []

    if not project.is_dir():
        blockers.append(f"missing authorized Essentials v21.1 project directory: {project}")
    for required in manifest["base"]["required_files"]:
        if not (project / required).is_file():
            blockers.append(f"missing Essentials project file: {required}")

    lock_path = source_root / LOCK_NAME
    if not lock_path.is_file():
        blockers.append(f"missing pinned source lock: {lock_path}")
    else:
        try:
            verify_source_bundle(source_root, manifest, profile=profile)
        except IntegrationError as exc:
            blockers.append(str(exc))

    if not inputs.is_dir():
        blockers.append(f"missing private build-input directory: {inputs}")
    if not isinstance(plan, dict):
        blockers.append("missing or invalid private build plan")
        plan = {}

    authorization = plan.get("authorization", {})
    if authorization.get("engine_version") != manifest["engine"]["version"] or authorization.get(
        "source_authorized"
    ) is not True:
        blockers.append("plan must attest an authorized, source-owned Pokémon Essentials v21.1 project")
    elif inputs.is_dir():
        try:
            _verify_rights_record(inputs, authorization, "base_project", "essentials_project")
        except IntegrationError as exc:
            blockers.append(str(exc))

    targets = plan.get("map_targets", {})
    if set(targets) != set(profile_config["map_slots"]):
        blockers.append(
            "map_targets must contain exactly: " + ", ".join(profile_config["map_slots"])
        )
    for slot in profile_config["map_slots"]:
        target = targets.get(slot, {})
        map_id = target.get("id")
        if not isinstance(map_id, int) or isinstance(map_id, bool) or map_id <= 0:
            blockers.append(f"{slot}: reviewed target map ID is unassigned")
        elif project.is_dir() and not (project / "Data" / f"Map{map_id:03d}.rxdata").is_file():
            blockers.append(f"missing target map file: Data/Map{map_id:03d}.rxdata ({slot})")
        if target.get("reviewed") is not True:
            blockers.append(f"{slot}: map identity/target mapping approval is missing")
        if target.get("map_info_reviewed") is not True:
            blockers.append(f"{slot}: MapInfos approval is missing")

    for kind in ("switch_ids", "variable_ids"):
        expected = profile_config[kind]
        supplied = plan.get(kind, {})
        for name in expected:
            if name not in supplied:
                blockers.append(f"unassigned {kind[:-1]}: {name}")
        values = [supplied[name] for name in expected if name in supplied]
        if any(not isinstance(value, int) or isinstance(value, bool) or value <= 0 for value in values):
            blockers.append(f"{kind}: all reserved IDs must be positive integers")
        if len(values) != len(set(values)):
            blockers.append(f"{kind}: duplicate event resource ID")

    asset_specs = {item["id"]: item for item in manifest["asset_requirements"]}
    assets = plan.get("assets", {})
    for asset_id in profile_config["assets"]:
        spec = asset_specs[asset_id]
        asset = assets.get(asset_id)
        expected_path = spec.get("expected_local_input", f"assets/{asset_id}")
        if not asset:
            blockers.append(f"missing asset input {asset_id}: {expected_path}")
            continue
        try:
            asset_path = regular_file(inputs, asset.get("source"), f"asset {asset_id}")
            if sha256(asset_path) != asset.get("sha256"):
                blockers.append(f"asset SHA256 mismatch: {asset_id}")
        except IntegrationError as exc:
            blockers.append(str(exc))
        if asset.get("rights_reviewed") is not True:
            blockers.append(f"missing rights approval for asset {asset_id}: {expected_path}")
        try:
            _verify_rights_record(inputs, asset, asset_id, "asset")
        except IntegrationError as exc:
            blockers.append(str(exc))

    archive_specs = {
        item["id"]: item for item in manifest["plugin_archives"]
        if item["id"] in profile_config["archives"]
    }
    archives = plan.get("archives", {})
    installed = _project_plugins(project) if project.is_dir() else {}
    for archive_id, spec in archive_specs.items():
        if installed.get(spec["name"]) == spec["version"]:
            continue
        record = archives.get(archive_id)
        expected_path = spec.get("expected_local_input", f"archives/{archive_id}.zip")
        if not record:
            blockers.append(
                f"missing required plugin archive {archive_id} v{spec['version']}: {expected_path}"
            )
            continue
        try:
            archive_path = regular_file(inputs, record.get("source"), f"plugin archive {archive_id}")
            if sha256(archive_path) != record.get("sha256"):
                blockers.append(f"plugin archive SHA256 mismatch: {archive_id}")
        except IntegrationError as exc:
            blockers.append(str(exc))
        if record.get("license_reviewed") is not True:
            blockers.append(f"missing license approval for plugin archive: {archive_id}")
        try:
            _verify_rights_record(inputs, record, archive_id, "plugin_archive")
        except IntegrationError as exc:
            blockers.append(str(exc))

    source_specs = {item["id"]: item for item in manifest.get("source_projects", [])}
    supplied_sources = plan.get("source_projects", {})
    for source_id in profile_config.get("source_projects", []):
        spec = source_specs[source_id]
        record = supplied_sources.get(source_id)
        if not record:
            blockers.append(
                f"missing source permission and local source inventory for {source_id}: "
                f"{spec.get('repository')}@{spec.get('commit')}"
            )
            for source in spec.get("source_files", []):
                blockers.append(f"missing local source file: {source.get('input', source['path'])}")
            continue
        try:
            _verify_rights_record(inputs, record, source_id, "source_project")
        except IntegrationError as exc:
            blockers.append(str(exc))
        source_files = record.get("files", {})
        for source in spec.get("source_files", []):
            details = source_files.get(source["path"])
            if not details:
                blockers.append(f"missing local source file: {source.get('input', source['path'])}")
                continue
            try:
                source_path = regular_file(
                    inputs, details.get("input"), f"{source_id} source file {source['path']}"
                )
                if sha256(source_path) != details.get("sha256"):
                    blockers.append(f"{source_id}: local source file hash mismatch: {source['path']}")
                if source.get("sha256") and details.get("sha256") != source["sha256"]:
                    blockers.append(
                        f"{source_id}: source does not match pinned hash: {source['path']}"
                    )
            except IntegrationError as exc:
                blockers.append(str(exc))

    if project.is_dir() and inputs.is_dir() and source_root.is_dir() and not blockers:
        try:
            _validate_plan(plan, manifest, project, inputs, profile=profile)
        except IntegrationError as exc:
            blockers.append(str(exc))
    return {
        "profile": profile,
        "status": "BLOCKED" if blockers else "READY_TO_STAGE",
        "evidence_tier": "private-input-preflight-only",
        "runtime_verified": False,
        "blockers": sorted(set(blockers)),
    }


def _validate_plan(plan, manifest, project, inputs, profile=None):
    profile_config = _profile_config(manifest, profile)
    authorization = plan.get("authorization", {})
    if authorization.get("engine_version") != manifest["engine"]["version"] or authorization.get(
        "source_authorized"
    ) is not True:
        raise IntegrationError("plan must attest an authorized Pokémon Essentials v21.1 source project")
    authorization_hash = _verify_rights_record(
        inputs, authorization, "base_project", "essentials_project"
    )
    source_rights_hashes = {}
    source_specs = {item["id"]: item for item in manifest.get("source_projects", [])}
    source_inputs = plan.get("source_projects", {})
    if set(source_inputs) != set(profile_config.get("source_projects", [])):
        raise IntegrationError("plan must provide exactly the source project inputs required by profile")
    for source_id in profile_config.get("source_projects", []):
        source_spec = source_specs[source_id]
        source_record = source_inputs[source_id]
        source_rights_hashes[source_id] = _verify_rights_record(
            inputs, source_record, source_id, "source_project"
        )
        files = source_record.get("files", {})
        expected_paths = {item["path"] for item in source_spec.get("source_files", [])}
        if set(files) != expected_paths:
            raise IntegrationError(
                f"{source_id}: local source file inventory mismatch "
                f"(missing={sorted(expected_paths - set(files))}, extra={sorted(set(files) - expected_paths)})"
            )
        expected_hashes = {
            item["path"]: item.get("sha256") for item in source_spec.get("source_files", [])
        }
        for source_path, details in files.items():
            input_path = regular_file(
                inputs, details.get("input"), f"{source_id} source file {source_path}"
            )
            digest = details.get("sha256")
            if not isinstance(digest, str) or not HEX_64.fullmatch(digest) or sha256(input_path) != digest:
                raise IntegrationError(f"{source_id}: local source file hash mismatch: {source_path}")
            expected_hash = expected_hashes[source_path]
            if expected_hash is not None and digest != expected_hash:
                raise IntegrationError(f"{source_id}: source file differs from pinned upstream hash: {source_path}")

    targets = plan.get("map_targets", {})
    slots = {
        slot: manifest["target_map_slots"][slot]
        for slot in profile_config["map_slots"]
    }
    if set(targets) != set(slots):
        raise IntegrationError("plan must provide exactly one reviewed target for every map slot")
    ids, map_hashes = set(), {}
    for slot, requirement in slots.items():
        target = targets[slot]
        map_id = target.get("id")
        if not isinstance(map_id, int) or isinstance(map_id, bool) or map_id <= 0 or map_id in ids:
            raise IntegrationError(f"{slot}: target map ID missing or duplicated")
        ids.add(map_id)
        expected_path = Path("Data") / f"Map{map_id:03d}.rxdata"
        map_path = regular_file(project, expected_path.as_posix(), f"{slot} target map")
        digest = target.get("sha256")
        if not isinstance(digest, str) or not HEX_64.fullmatch(digest) or sha256(map_path) != digest:
            raise IntegrationError(f"{slot}: target map SHA256 mismatch")
        expected_dimensions = requirement.get("dimensions")
        if expected_dimensions and target.get("dimensions") != expected_dimensions:
            raise IntegrationError(f"{slot}: target map dimensions do not match source contract")
        expected_uuid = requirement.get("source_uuid")
        source_uuid = target.get("source_uuid")
        if expected_uuid and source_uuid != expected_uuid:
            raise IntegrationError(f"{slot}: source map UUID mismatch")
        if target.get("reviewed") is not True:
            raise IntegrationError(f"{slot}: map identity/target mapping has not been reviewed")
        if target.get("map_info_reviewed") is not True:
            raise IntegrationError(f"{slot}: MapInfos entry has not been reviewed")
        map_hashes[slot] = {"id": map_id, "sha256": digest, "path": expected_path.as_posix()}

    for kind, profile_key in (("switch_ids", "switch_ids"), ("variable_ids", "variable_ids")):
        required = set(profile_config[profile_key])
        values = plan.get(kind, {})
        if set(values) != required:
            raise IntegrationError(f"plan must allocate every {kind.replace('_', ' ')} exactly once")
        numeric = list(values.values())
        if any(not isinstance(value, int) or isinstance(value, bool) or value <= 0 for value in numeric):
            raise IntegrationError(f"{kind}: IDs must be positive integers")
        if len(numeric) != len(set(numeric)):
            raise IntegrationError(f"{kind}: duplicate event resource ID")

    asset_requirements = {
        asset_id for asset_id in profile_config["assets"]
    }
    assets = plan.get("assets", {})
    if set(assets) != asset_requirements:
        missing = sorted(asset_requirements - set(assets))
        extra = sorted(set(assets) - asset_requirements)
        raise IntegrationError(f"asset inventory mismatch (missing={missing}, extra={extra})")
    destinations, asset_hashes, rights_hashes = set(), {}, {}
    for asset_id, asset in assets.items():
        source_rel = safe_relative(asset.get("source"), "asset source")
        source_path = regular_file(inputs, source_rel.as_posix(), f"asset {asset_id}")
        digest = asset.get("sha256")
        if not isinstance(digest, str) or not HEX_64.fullmatch(digest) or sha256(source_path) != digest:
            raise IntegrationError(f"local asset hash mismatch: {asset_id}")
        if asset.get("rights_reviewed") is not True:
            raise IntegrationError(f"asset rights not reviewed: {asset_id}")
        rights_hashes[asset_id] = _verify_rights_record(
            inputs, asset, asset_id, "asset"
        )
        destination = asset.get("destination")
        if destination is not None:
            dest_rel = safe_relative(destination, "asset destination")
            if dest_rel.parts[0] not in ("Audio", "Graphics"):
                raise IntegrationError(f"asset destination is not an Audio/Graphics path: {destination}")
            if destination in destinations:
                raise IntegrationError(f"duplicate staged asset destination: {destination}")
            destinations.add(destination)
        asset_hashes[asset_id] = digest

    archive_specs = {
        item["id"]: item for item in manifest["plugin_archives"]
        if item["id"] in profile_config["archives"]
    }
    archives = plan.get("archives", {})
    if not set(archives) <= set(archive_specs):
        raise IntegrationError("plan contains an undeclared plugin archive")
    base_plugins = _project_plugins(project)
    if "Feral Tank" in base_plugins:
        raise IntegrationError("Feral Tank is optional and blocked until Pokemon#calc_stats/HUMAN audit")
    selected_components = [
        component for component in manifest["components"]
        if component["id"] in profile_config["components"]
    ]
    first_party_names = {component["name"] for component in selected_components}
    base_hooks = _project_hook_claims(project, ignored_plugin_names=first_party_names)
    first_party_hooks = {
        hook for component in selected_components for hook in component.get("hook_claims", [])
    }
    if first_party_hooks & set(base_hooks):
        raise IntegrationError(f"base plugin hook conflicts with Shattered: {sorted(first_party_hooks & set(base_hooks))}")
    archive_hashes = {}
    archive_hook_claims = {}
    for archive_id, spec in archive_specs.items():
        installed = base_plugins.get(spec["name"])
        if installed == spec["version"]:
            if archive_id in archives:
                raise IntegrationError(f"{spec['name']} is already installed; duplicate archive supplied")
            continue
        if archive_id not in archives:
            raise IntegrationError(f"missing required plugin archive: {archive_id} ({spec['version']})")
        record = archives[archive_id]
        archive_rel = safe_relative(record.get("source"), "plugin archive source")
        archive_path = regular_file(inputs, archive_rel.as_posix(), f"plugin archive {archive_id}")
        if record.get("license_reviewed") is not True:
            raise IntegrationError(f"plugin archive license not reviewed: {archive_id}")
        rights_hashes[archive_id] = _verify_rights_record(
            inputs, record, archive_id, "plugin_archive"
        )
        digest = record.get("sha256")
        if not isinstance(digest, str) or not HEX_64.fullmatch(digest) or sha256(archive_path) != digest:
            raise IntegrationError(f"plugin archive hash mismatch: {archive_id}")
        metadata, detected_hooks = _archive_members(archive_path)
        if not any(meta.get("name") == spec["name"] and meta.get("version") == spec["version"] for meta in metadata):
            raise IntegrationError(f"archive identity/version mismatch: {archive_id}")
        reviewed_hooks = record.get("reviewed_hooks")
        if not isinstance(reviewed_hooks, list) or any(not isinstance(item, str) or not item for item in reviewed_hooks):
            raise IntegrationError(f"archive hook inventory is missing or invalid: {archive_id}")
        if len(reviewed_hooks) != len(set(reviewed_hooks)):
            raise IntegrationError(f"archive hook inventory contains duplicate claims: {archive_id}")
        hook_claims = set(reviewed_hooks) | set(detected_hooks)
        collision = first_party_hooks & hook_claims
        if collision:
            raise IntegrationError(f"conflicting plugin hooks in {archive_id}: {sorted(collision)}")
        for previous_id, previous_claims in archive_hook_claims.items():
            if hook_claims & previous_claims:
                raise IntegrationError(
                    f"conflicting plugin hooks between {previous_id} and {archive_id}: "
                    f"{sorted(hook_claims & previous_claims)}"
                )
        if hook_claims & set(base_hooks):
            raise IntegrationError(f"archive conflicts with source project hooks: {sorted(hook_claims & set(base_hooks))}")
        archive_hook_claims[archive_id] = hook_claims
        archive_hashes[archive_id] = digest
    return {
        "map_targets": map_hashes,
        "assets": asset_hashes,
        "archives": archive_hashes,
        "rights_records": {"base_project": authorization_hash, **rights_hashes},
        "source_project_rights_sha256": source_rights_hashes,
        "switch_ids": plan["switch_ids"],
        "variable_ids": plan["variable_ids"],
    }


def _project_plugins(project):
    found = {}
    plugin_root = project / "Plugins"
    if not plugin_root.is_dir():
        return found
    for meta in plugin_root.glob("*/meta.txt"):
        info = _parse_meta(meta.read_text(encoding="utf-8-sig", errors="replace"))
        name, version = info.get("name"), info.get("version")
        if not name or not version:
            continue
        if name in found:
            raise IntegrationError(f"duplicate plugin name in source project: {name}")
        found[name] = version
    return found


def _project_hook_claims(project, ignored_plugin_names=()):
    claims = {}
    plugin_root = project / "Plugins"
    if not plugin_root.is_dir():
        return claims
    ignored = set(ignored_plugin_names)
    for folder in plugin_root.iterdir():
        if not folder.is_dir() or folder.name in ignored:
            continue
        meta = folder / "meta.txt"
        name = _parse_meta(meta.read_text(encoding="utf-8-sig", errors="replace")).get("name") if meta.is_file() else folder.name
        plugin_claims = set()
        for script in folder.rglob("*.rb"):
            if script.is_symlink():
                raise IntegrationError(f"plugin source symlink rejected: {script.relative_to(project)}")
            text = script.read_text(encoding="utf-8", errors="replace")
            plugin_claims.update(
                claim for claim, pattern in RUBY_HOOK_PATTERNS.items()
                if pattern.search(text)
            )
        for claim in plugin_claims:
            if claim in claims:
                raise IntegrationError(
                    f"conflicting hooks in source project: {claim} ({claims[claim]} and {name})"
                )
            claims[claim] = name
    return claims


def _append_pbs_fragment(target, fragment):
    content = fragment.read_text(encoding="utf-8-sig")
    match = re.search(r"^\[([A-Z0-9_]+)\]\s*$", content, re.M)
    if not match or len(re.findall(r"^\[[A-Z0-9_]+\]\s*$", content, re.M)) != 1:
        raise IntegrationError(f"PBS fragment must contain exactly one section: {fragment.name}")
    section = match.group(1)
    original = target.read_text(encoding="utf-8-sig")
    sections = re.findall(r"^\[([A-Z0-9_]+)\]\s*$", original, re.M)
    if sections.count(section) > 1:
        raise IntegrationError(f"duplicate PBS section already exists: [{section}]")
    if section in sections:
        existing = re.split(r"^\[[A-Z0-9_]+\]\s*$", original, flags=re.M)
        index = sections.index(section)
        existing_section = f"[{section}]\n{existing[index + 1]}".strip()
        if re.sub(r"\s+", "", existing_section) != re.sub(r"\s+", "", content):
            raise IntegrationError(f"conflicting PBS section already exists: [{section}]")
        return False
    with target.open("a", encoding="utf-8", newline="") as stream:
        if original and not original.endswith("\n"):
            stream.write("\n")
        stream.write("\n" + content.rstrip() + "\n")
    return True


def _extract_archive(archive_path, destination, manifest_record, known_plugins, manifest):
    spec_name, spec_version = manifest_record["name"], manifest_record["version"]
    with zipfile.ZipFile(archive_path) as archive:
        members = archive.infolist()
        total_size = sum(member.file_size for member in members)
        if len(members) > MAX_ARCHIVE_ENTRIES or total_size > MAX_ARCHIVE_BYTES:
            raise IntegrationError(f"plugin archive exceeds safety limits: {spec_name}")
        files, meta_records, seen = [], [], set()
        for member in members:
            raw = member.filename.replace("\\", "/")
            parts = PurePosixPath(raw).parts
            if raw.startswith("/") or re.match(r"^[a-zA-Z]:", raw):
                raise IntegrationError(f"absolute archive path: {raw}")
            if any(part in ("", ".", "..") for part in parts):
                raise IntegrationError(f"unsafe archive path: {raw}")
            if parts and parts[0] not in ALLOWED_ARCHIVE_ROOTS:
                if len(parts) < 2 or parts[1] not in ALLOWED_ARCHIVE_ROOTS:
                    raise IntegrationError(f"unsupported archive destination: {raw}")
                raw = "/".join(parts[1:])
                parts = PurePosixPath(raw).parts
            if not parts or parts[0] not in ALLOWED_ARCHIVE_ROOTS:
                raise IntegrationError(f"unsupported archive destination: {raw}")
            if ((member.external_attr >> 16) & 0o170000) == stat.S_IFLNK:
                raise IntegrationError(f"archive symlink rejected: {raw}")
            if member.file_size > MAX_ENTRY_BYTES:
                raise IntegrationError(f"oversized archive member: {raw}")
            if member.is_dir():
                continue
            if raw in seen:
                raise IntegrationError(f"duplicate archive member: {raw}")
            seen.add(raw)
            if (parts[0] == "PBS" and PurePosixPath(raw).name == "pokemon.txt") or (
                parts[0] == "Data" and PurePosixPath(raw).name == "Scripts.rxdata"
            ):
                raise IntegrationError(f"refusing to replace protected engine file: {raw}")
            if PurePosixPath(raw).name.lower() == "meta.txt":
                meta_records.append(_parse_meta(archive.read(member).decode("utf-8-sig", "replace")))
            files.append((member, raw))
        if not any(meta.get("name") == spec_name and meta.get("version") == spec_version for meta in meta_records):
            raise IntegrationError(f"archive identity/version mismatch: {spec_name}")
        for dependency in manifest_record["depends_on"]:
            required = next(item for item in manifest["plugin_archives"] if item["id"] == dependency)
            if known_plugins.get(required["name"]) != required["version"]:
                raise IntegrationError(f"{spec_name} requires installed {required['name']} {required['version']}")
        for member, rel_name in files:
            target = destination / safe_relative(rel_name, "archive member")
            if target.exists():
                raise IntegrationError(f"plugin archive would overwrite an existing file: {rel_name}")
        for member, rel_name in files:
            target = destination / safe_relative(rel_name, "archive member")
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
    known_plugins[spec_name] = spec_version


def stage_project(
    project, source_root, inputs, plan, output, manifest, synthetic_fixture=False, profile=None
):
    validate_manifest(manifest)
    profile_config = _profile_config(manifest, profile)
    queue_path = ROOT / "development" / "integration_queue.json"
    if queue_path.is_file():
        validate_queue(json.loads(queue_path.read_text(encoding="utf-8")), manifest)
    project, source_root, inputs, output = map(
        lambda value: Path(value).resolve(), (project, source_root, inputs, output)
    )
    if output.exists():
        raise IntegrationError("output exists; choose a fresh staging directory")
    if project == output or project in output.parents or output in project.parents:
        raise IntegrationError("input and output must be separate, non-nested directories")
    if not project.is_dir():
        raise IntegrationError("authorized Essentials project directory is missing")
    for required in manifest["base"]["required_files"]:
        regular_file(project, required, "required Essentials base file")
    project_identity = project_tree_digest(project)
    lock = verify_source_bundle(
        source_root, manifest, synthetic_fixture=synthetic_fixture, profile=profile
    )
    inventory = _validate_plan(plan, manifest, project, inputs, profile=profile)
    initial_plugins = _project_plugins(project)

    temp_parent = output.parent
    temp_parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix=".shattered-integration-", dir=temp_parent))
    try:
        target = temp / "project"
        shutil.copytree(
            project,
            target,
            ignore=lambda directory, names: {".git"} if Path(directory).resolve() == project and ".git" in names else set(),
        )
        if project_tree_digest(target) != project_identity:
            raise IntegrationError("project changed during the copy; source/output hashes differ")
        known_plugins = dict(initial_plugins)
        archive_specs = {item["id"]: item for item in manifest["plugin_archives"]}
        for archive_id in archive_specs:
            if archive_id not in plan.get("archives", {}):
                continue
            archive_path = inputs / safe_relative(plan["archives"][archive_id]["source"], "archive source")
            if sha256(archive_path) != plan["archives"][archive_id]["sha256"]:
                raise IntegrationError(f"plugin archive changed during staging: {archive_id}")
            _extract_archive(archive_path, target, archive_specs[archive_id], known_plugins, manifest)

        source_files = {}
        source_hashes = lock["files"]
        selected_sources = [
            item for item in manifest["required_source_files"]
            if item["pr"] in profile_config["source_prs"]
        ]
        for item in selected_sources:
            bundle_path = source_root / f"pr-{item['pr']}" / safe_relative(item["path"], "source file")
            if sha256(bundle_path) != source_hashes[f"{item['pr']}:{item['path']}"]:
                raise IntegrationError(f"pinned source changed during staging: PR {item['pr']} {item['path']}")
            source_files[(item["pr"], item["path"])] = bundle_path
        for item in selected_sources:
            if not item.get("stage"):
                continue
            source_path = source_files[(item["pr"], item["path"])]
            source_name = Path(item["path"])
            if source_name.parts[0] == "essentials" and source_name.parts[1] == "Plugins":
                destination = target / "Plugins" / Path(*source_name.parts[2:])
                if destination.exists():
                    if destination.is_file() and sha256(destination) == sha256(source_path):
                        continue
                    raise IntegrationError(f"refusing to overwrite staged plugin file: {destination.relative_to(target)}")
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source_path, destination)

        for slot, target_record in inventory["map_targets"].items():
            if sha256(target / target_record["path"]) != target_record["sha256"]:
                raise IntegrationError(f"target map changed during staging: {slot}")
        for item in selected_sources:
            pbs_target = item.get("pbs_target")
            if pbs_target:
                _append_pbs_fragment(
                    target / safe_relative(pbs_target, "PBS target"),
                    source_files[(item["pr"], item["path"])],
                )
        for label, pbs_path in (
            ("species", target / "PBS/pokemon.txt"),
            ("items", target / "PBS/items.txt"),
        ):
            required = profile_config.get(
                f"pbs_{label}", manifest["pbs_requirements"][label]
            )
            sections = _pbs_sections(pbs_path)
            for section in required:
                if sections.count(section) != 1:
                    raise IntegrationError(f"PBS {label} definition must exist exactly once: [{section}]")

        for asset_id, asset in plan["assets"].items():
            if asset.get("destination") is None:
                continue
            destination = target / safe_relative(asset["destination"], "asset destination")
            source_path = inputs / safe_relative(asset["source"], "asset source")
            if destination.exists():
                if sha256(destination) != asset["sha256"]:
                    raise IntegrationError(f"asset would overwrite different project content: {asset['destination']}")
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source_path, destination)
            if sha256(destination) != asset["sha256"]:
                raise IntegrationError(f"asset changed during staging: {asset_id}")

        final_plugins = _project_plugins(target)
        for archive in manifest["plugin_archives"]:
            if archive["id"] in profile_config["archives"] and final_plugins.get(archive["name"]) != archive["version"]:
                raise IntegrationError(f"required plugin missing or wrong version after stage: {archive['name']}")
        for component in (
            component for component in manifest["components"]
            if component["id"] in profile_config["components"]
        ):
            if final_plugins.get(component["name"]) != component["version"]:
                raise IntegrationError(f"staged plugin missing or wrong version: {component['name']}")

        report = {
            "schema_version": 1,
            "product": manifest["product"],
            "engine": manifest["engine"],
            "evidence_tier": "synthetic-fixture" if synthetic_fixture else "staged-copy-only",
            "status": "staged_test_copy",
            "profile": profile or "full",
            "acceptance_target": profile_config.get("acceptance_target"),
            "runtime_status": profile_config.get("runtime_status", "BLOCKED until native acceptance"),
            "source_prs": [
                {"id": pr["id"], "branch": pr["branch"], "commit": pr["head"], "base": pr["base"]}
                for pr in manifest["pull_requests"] if pr["id"] in profile_config["source_prs"]
            ],
            "source_files_verified": len(lock["files"]),
            "source_integrity": "synthetic-fixture-lock" if synthetic_fixture else "pinned-git-export-and-sha256",
            "base_project_sha256": project_identity["sha256"],
            "base_project_file_count": project_identity["file_count"],
            "declared_plugin_load_order": [
                name for name in manifest["load_order"]
                if name in {component["name"] for component in manifest["components"] if component["id"] in profile_config["components"]}
                or name in {archive["name"] for archive in manifest["plugin_archives"] if archive["id"] in profile_config["archives"]}
            ],
            "plugin_load_order_engine_verified": False,
            "map_targets": inventory["map_targets"],
            "assets_sha256": inventory["assets"],
            "plugin_archives_sha256": inventory["archives"],
            "rights_records_sha256": inventory["rights_records"],
            "source_project_rights_sha256": inventory["source_project_rights_sha256"],
            "switch_ids": inventory["switch_ids"],
            "variable_ids": inventory["variable_ids"],
            "original_project_modified": False,
            "pbs_compiled": False,
            "game_boot_verified": False,
            "gameplay_verified": False,
            "save_reload_verified": False,
            "android_joiplay_verified": False,
            "open_gates": [
                "native Essentials v21.1 PBS compilation",
                "native plugin script compilation and game boot",
                "map/event execution, full playthrough, and save/reload",
                "Android JoiPlay/NaviaXP playthrough",
                "manual confirmation that all supplied assets and plugin archives are distributable",
            ],
        }
        (target / "SHATTERED_INTEGRATION_BUILD.json").write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.replace(target, output)
    except Exception:
        shutil.rmtree(temp, ignore_errors=True)
        raise
    shutil.rmtree(temp, ignore_errors=True)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate_parser = subparsers.add_parser("validate-manifest", help="validate pinned refs and compatibility graph")
    validate_parser.add_argument("--manifest", default=str(MANIFEST_PATH))
    export_parser = subparsers.add_parser("export-sources", help="export allow-listed files from exact local Git PR heads")
    export_parser.add_argument("--git-repo", required=True)
    export_parser.add_argument("--output", required=True)
    export_parser.add_argument("--manifest", default=str(MANIFEST_PATH))
    export_parser.add_argument("--profile", choices=["initial_slice"])
    stage_parser = subparsers.add_parser("stage", help="build a new, private Essentials test copy")
    stage_parser.add_argument("--project", required=True)
    stage_parser.add_argument("--sources", required=True)
    stage_parser.add_argument("--inputs", required=True, help="directory containing reviewed assets and plugin ZIPs")
    stage_parser.add_argument("--plan", required=True, help="private reviewed project/resource plan JSON")
    stage_parser.add_argument("--output", required=True)
    stage_parser.add_argument("--manifest", default=str(MANIFEST_PATH))
    stage_parser.add_argument("--profile", choices=["initial_slice"])
    stage_parser.add_argument("--synthetic-fixture", action="store_true", help=argparse.SUPPRESS)
    preflight_parser = subparsers.add_parser(
        "preflight", help="report all missing private inputs for a staging profile"
    )
    preflight_parser.add_argument("--project", required=True)
    preflight_parser.add_argument("--sources", required=True)
    preflight_parser.add_argument("--inputs", required=True)
    preflight_parser.add_argument("--plan", required=True)
    preflight_parser.add_argument("--profile", choices=["initial_slice"], required=True)
    preflight_parser.add_argument("--manifest", default=str(MANIFEST_PATH))
    args = parser.parse_args(argv)
    try:
        manifest = load_manifest(args.manifest)
        if args.command == "validate-manifest":
            result = validate_manifest(manifest)
            queue_path = ROOT / "development" / "integration_queue.json"
            if queue_path.is_file():
                result.update(validate_queue(json.loads(queue_path.read_text(encoding="utf-8")), manifest))
            result.update({"manifest_valid": True, "evidence_tier": "static-only", "integrated_build_ready": False})
        elif args.command == "export-sources":
            result = export_sources(args.git_repo, args.output, manifest, profile=args.profile)
        elif args.command == "preflight":
            try:
                plan = json.loads(Path(args.plan).read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise IntegrationError(f"cannot read private staging plan: {exc}") from exc
            result = diagnose_preflight(
                args.project, args.sources, args.inputs, plan, manifest, args.profile
            )
            print(json.dumps(result, indent=2, sort_keys=True))
            return 0 if result["status"] == "READY_TO_STAGE" else 2
        else:
            try:
                plan = json.loads(Path(args.plan).read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise IntegrationError(f"cannot read private staging plan: {exc}") from exc
            result = stage_project(
                args.project, args.sources, args.inputs, plan, args.output, manifest,
                synthetic_fixture=args.synthetic_fixture, profile=args.profile,
            )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (IntegrationError, OSError, zipfile.BadZipFile, KeyError, TypeError) as exc:
        print(f"integration gate failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
