#!/usr/bin/env python3
"""Assemble a private initial-slice candidate from a local Essentials ZIP and pinned inputs."""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import build_private_native_candidate as base_builder
import shattered_integration as integration
from shattered_integration_handoff import prepare_native_handoff


ROOT = Path(__file__).resolve().parents[1]
REPORT = "SHATTERED_PRIVATE_OPENING_CANDIDATE.json"
NATIVE_CANDIDATE = "SHATTERED_NATIVE_CANDIDATE.json"
VIRIDIAN_PLUGIN = "Shattered Viridian"
VIRIDIAN_FILES = ("001_Entry.rb", "002_Install.rb", "meta.txt")


def _regular_file(path, label):
    path = Path(path).absolute()
    if not path.is_file() or path.resolve(strict=True) != path:
        raise ValueError(f"{label} is missing, non-regular, or symlinked")
    return path


def _directory(path, label):
    path = Path(path).absolute()
    if not path.is_dir() or path.resolve(strict=True) != path:
        raise ValueError(f"{label} is missing or symlinked")
    return path


def _read_json(path, label):
    path = _regular_file(path, label)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is not valid UTF-8 JSON") from error


def _run_ruby(script, args):
    result = subprocess.run(
        ["ruby", str(ROOT / "scripts" / script), *map(str, args)],
        cwd=ROOT, capture_output=True, text=True, timeout=300, check=False,
    )
    if result.returncode:
        raise RuntimeError(
            f"{script} failed (exit {result.returncode}): "
            + (result.stderr or result.stdout)[-3000:]
        )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"{script} returned invalid JSON") from error


def _write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp")
    if temporary.exists() or temporary.is_symlink():
        raise ValueError(f"Stale candidate receipt temp: {temporary.name}")
    with temporary.open("x", encoding="utf-8") as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write("\n")
    os.replace(temporary, path)


def _sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _stage_viridian_source(candidate):
    source = ROOT / "essentials" / "Plugins" / VIRIDIAN_PLUGIN
    destination = candidate / "Plugins" / VIRIDIAN_PLUGIN
    if source.is_symlink() or not source.is_dir():
        raise ValueError("reviewed Viridian source plugin is missing or symlinked")
    if destination.exists() or destination.is_symlink():
        raise ValueError("refusing to overwrite an existing staged Viridian plugin")
    if sorted(path.name for path in source.iterdir()) != sorted(VIRIDIAN_FILES):
        raise ValueError("reviewed Viridian plugin file inventory changed")
    destination.mkdir(parents=True)
    hashes = {}
    for name in VIRIDIAN_FILES:
        original = source / name
        if original.is_symlink() or not original.is_file():
            raise ValueError(f"reviewed Viridian source file is missing or symlinked: {name}")
        shutil.copyfile(original, destination / name)
        hashes[name] = _sha(original)
    return hashes


def _upgrade_viridian_maps(candidate, native_plan):
    data = candidate / "Data"
    system_path = data / "System.rxdata"
    city_path = data / "Map010.rxdata"
    center_path = data / "Map011.rxdata"
    original_hashes = {
        10: _sha(city_path),
        11: _sha(center_path),
    }
    original_system_hash = _sha(system_path)
    spawn = native_plan.get("new_game_spawn")
    if not isinstance(spawn, dict) or spawn.get("system_sha256") != original_system_hash:
        raise ValueError("reviewed native plan System hash differs from the private base")
    existing = native_plan.get("required_existing_maps")
    if not isinstance(existing, list):
        raise ValueError("native plan lacks reviewed existing HnS destination maps")
    for item in existing:
        if isinstance(item, dict) and item.get("id") in original_hashes and \
           item.get("sha256") != original_hashes[item["id"]]:
            raise ValueError(f"reviewed native map hash differs before Viridian migration: {item['id']}")

    handoff = _run_ruby("upgrade_private_viridian_handoff.rb", [candidate])
    expected_handoff = {
        "city_sha256": city_path,
        "center_sha256": center_path,
        "system_sha256": system_path,
    }
    if handoff.get("weather_center_handoff_installed") is not True or any(
        handoff.get(key) != _sha(path) for key, path in expected_handoff.items()
    ):
        raise RuntimeError("private Viridian handoff receipt failed verification")

    escort = _run_ruby("upgrade_private_viridian_escort.rb", [candidate])
    if escort.get("arrival_requires_completed_route") is not True or \
       escort.get("native_events_added") != 4 or \
       escort.get("native_map_sha256") != _sha(city_path):
        raise RuntimeError("private Viridian escort receipt failed verification")

    derived_plan = copy.deepcopy(native_plan)
    derived_plan["new_game_spawn"]["system_sha256"] = _sha(system_path)
    for item in derived_plan["required_existing_maps"]:
        if isinstance(item, dict) and item.get("id") in original_hashes:
            path = data / f"Map{item['id']:03d}.rxdata"
            item["sha256"] = _sha(path)
    return derived_plan, {
        "handoff": handoff,
        "escort": escort,
        "input_map_sha256": original_hashes,
        "input_system_sha256": original_system_hash,
        "derived_system_sha256": _sha(system_path),
    }


def _native_pbs_receipt(candidate, result):
    report_path = candidate / "SHATTERED_NATIVE_PBS_COMPILE_REPORT.json"
    if not report_path.is_file() or report_path.is_symlink():
        raise RuntimeError("native PBS compiler did not write a regular report")
    report = _read_json(report_path, "native PBS compile receipt")
    if report != result or report.get("kind") != \
       "actual_private_essentials_native_pbs_compiler_not_gameplay_acceptance" or \
       report.get("native_compiler_completed") is not True or \
       report.get("source_sha") != json.loads(
           (candidate / NATIVE_CANDIDATE).read_text(encoding="utf-8")
       ).get("source_sha") or \
       report.get("restored_scripts_sha256") != report.get("original_scripts_sha256") or \
       report.get("gameplay_verified") is not False or \
       report.get("save_reload_verified") is not False:
        raise RuntimeError("native PBS compiler receipt failed candidate verification")
    return report


def build(archive, rights_record, sources, inputs, stage_plan, native_plan, output,
          manifest_path=None, source_sha=None, native_engine=None, linux_aliases=False):
    archive = _regular_file(archive, "Essentials base archive")
    rights_record = _regular_file(rights_record, "base-project rights record")
    sources = _directory(sources, "Pinned Shattered source bundle")
    inputs = _directory(inputs, "Private staging inputs")
    stage_plan = _regular_file(stage_plan, "Private staging plan")
    native_plan = _regular_file(native_plan, "Private native installer plan")
    manifest_path = _regular_file(
        manifest_path or integration.MANIFEST_PATH, "Integration manifest"
    )
    manifest = integration.load_manifest(manifest_path)
    base_provenance = base_builder.validate_base_rights(archive, rights_record)
    source_sha, source_verified = base_builder.source_pin(source_sha)
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("candidate output already exists; choose a fresh private path")
    if not output.parent.is_dir() or output.parent.resolve(strict=True) != output.parent:
        raise ValueError("candidate output parent is missing or symlinked")
    if output == sources or output in sources.parents or output == inputs or output in inputs.parents:
        raise ValueError("candidate output must not overwrite a source or input directory")
    source_plan = _read_json(stage_plan, "Private staging plan")
    install_plan = _read_json(native_plan, "Private native installer plan")
    if native_engine is not None:
        native_engine = _regular_file(native_engine, "mkxp-z executable")
        if not os.access(native_engine, os.X_OK):
            raise ValueError("mkxp-z path is not executable")

    rights_sha = _sha(rights_record)
    source_tree = integration.project_tree_digest(sources)
    input_tree = integration.project_tree_digest(inputs)
    temporary_root = Path(tempfile.mkdtemp(
        prefix=".shattered-opening-build-", dir=output.parent
    ))
    candidate = temporary_root / "project"
    try:
        base = base_builder.extract_base_archive(
            archive, temporary_root / "authorized-base"
        )
        integration.stage_project(
            base, sources, inputs, source_plan, candidate, manifest,
            profile="initial_slice",
        )
        derived_native_plan, viridian_map_receipts = _upgrade_viridian_maps(
            candidate, install_plan
        )
        viridian_hashes = _stage_viridian_source(candidate)
        profile = integration._profile_config(manifest, "initial_slice")
        component_ids = set(profile["components"])
        profile_plugin_names = {
            item["name"] for item in manifest["components"]
            if item["id"] in component_ids and item["name"].startswith("Shattered ")
        }
        if not profile_plugin_names:
            raise ValueError("initial_slice manifest contains no Shattered runtime plugins")
        candidate_plugin_names = profile_plugin_names | {VIRIDIAN_PLUGIN}
        plugin_names = [
            name for name in manifest["load_order"]
            if name in candidate_plugin_names
        ]
        if set(plugin_names) != candidate_plugin_names:
            raise ValueError("manifest load order omits an initial-slice plugin")
        build_report_path = candidate / "SHATTERED_INTEGRATION_BUILD.json"
        build_report = _read_json(build_report_path, "staged integration report")
        build_report["declared_plugin_load_order"] = plugin_names
        _write_json(build_report_path, build_report)
        compiled = _run_ruby(
            "compile_private_plugins.rb",
            ["--project", candidate, *(
                item for name in plugin_names for item in ("--plugin", name)
            )],
        )
        isolated = _run_ruby("finalize_private_runtime.rb", ["--project", candidate])
        if not isolated.get("runtime_plugin_names") or \
           compiled.get("compiled_archive_sha256") != isolated.get("compiled_archive_sha256"):
            raise RuntimeError("compiled runtime archive failed isolation verification")

        native_candidate = {
            "source_sha": source_sha,
            "compiled_plugin_archive_sha256": _sha(
                candidate / "Data/PluginScripts.rxdata"
            ),
        }
        _write_json(candidate / NATIVE_CANDIDATE, native_candidate)
        handoff = prepare_native_handoff(
            candidate, sources, derived_native_plan, manifest
        )
        if handoff.get("status") != "native_install_pending" or \
           handoff.get("native_execution_verified") is not False or \
           handoff.get("gameplay_verified") is not False or \
           handoff.get("save_reload_verified") is not False:
            raise RuntimeError("native handoff receipt failed verification")

        pbs = None
        native_install = None
        if native_engine is not None:
            pbs_result = _run_ruby(
                "compile_private_pbs_native.rb",
                ["--project", candidate, "--engine", native_engine],
            )
            pbs = _native_pbs_receipt(candidate, pbs_result)
            native_install = _run_ruby(
                "install_private_initial_slice_native.rb",
                ["--project", candidate, "--engine", native_engine],
            )
            if native_install.get("kind") != \
               "actual_private_essentials_native_initial_slice_install_not_gameplay_acceptance" or \
               native_install.get("native_map_install_completed") is not True or \
               native_install.get("source_sha") != source_sha or \
               native_install.get("plan_sha256") != handoff.get("plan_sha256") or \
               native_install.get("gameplay_verified") is not False or \
               native_install.get("save_reload_verified") is not False:
                raise RuntimeError("native initial-slice installer receipt failed verification")

        aliases = base_builder.prepare_linux_aliases(candidate) if linux_aliases else None
        result = {
            "kind": "private_initial_slice_candidate_not_playable_acceptance",
            "source_sha": source_sha,
            "source_sha_verified_git_checkout": source_verified,
            "base_archive_sha256": base_provenance["archive_sha256"],
            "base_rights_record_sha256": rights_sha,
            "source_bundle_tree_sha256": source_tree["sha256"],
            "source_bundle_file_count": source_tree["file_count"],
            "private_inputs_tree_sha256": input_tree["sha256"],
            "private_inputs_file_count": input_tree["file_count"],
            "compiled_plugin_archive_sha256": _sha(
                candidate / "Data/PluginScripts.rxdata"
            ),
            "compiled_plugins": compiled.get("plugin_names", []),
            "offline_installers_isolated": len(isolated.get("moved", [])),
            "viridian_source_sha256": viridian_hashes,
            "viridian_migration_scripts_sha256": {
                name: _sha(_regular_file(ROOT / "scripts" / name, name))
                for name in (
                    "upgrade_private_viridian_handoff.rb",
                    "upgrade_private_viridian_escort.rb",
                )
            },
            "native_installer": handoff,
            "viridian_map_migrations": viridian_map_receipts,
            "native_pbs_compiled": pbs is not None,
            "native_pbs_receipt_sha256": _sha(
                candidate / "SHATTERED_NATIVE_PBS_COMPILE_REPORT.json"
            ) if pbs is not None else None,
            "native_maps_installed": native_install is not None,
            "viridian_map_data_migrated": True,
            "viridian_engine_verified": False,
            "native_map_install_receipt_sha256": _sha(
                candidate / "SHATTERED_NATIVE_INITIAL_SLICE_INSTALL_REPORT.json"
            ) if native_install is not None else None,
            "linux_map_alias_count": aliases["alias_count"] if aliases else None,
            "native_game_launched": False,
            "gameplay_verified": False,
            "save_reload_verified": False,
            "android_verified": False,
            "distributable": False,
        }
        _write_json(candidate / REPORT, result)
        candidate.chmod(0o700)
        candidate.rename(output)
        return result
    finally:
        shutil.rmtree(temporary_root, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-archive", required=True, help="local authorized Essentials 21.1 ZIP")
    parser.add_argument("--rights-record", required=True, help="local JSON attestation pinned to the ZIP SHA256")
    parser.add_argument("--sources", required=True, help="exact source bundle exported from the pinned manifest")
    parser.add_argument("--inputs", required=True, help="local licensed assets and plugin archives")
    parser.add_argument("--stage-plan", required=True, help="reviewed private initial-slice staging plan")
    parser.add_argument("--native-plan", required=True, help="reviewed private native map/event plan")
    parser.add_argument("--output", required=True, help="fresh private candidate directory")
    parser.add_argument("--manifest", default=str(integration.MANIFEST_PATH))
    parser.add_argument("--source-sha", help="required when source-only bundle lacks a clean Git checkout")
    parser.add_argument("--native-engine", help="optional mkxp-z path; compiles PBS and installs native Gate/Route22 maps")
    parser.add_argument("--linux-map-aliases", action="store_true")
    args = parser.parse_args()
    result = build(
        args.base_archive, args.rights_record, args.sources, args.inputs,
        args.stage_plan, args.native_plan, args.output, args.manifest,
        args.source_sha, args.native_engine, args.linux_map_aliases,
    )
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
