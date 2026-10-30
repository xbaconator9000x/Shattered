#!/usr/bin/env python3
"""Export pinned sources, assemble a synthetic plugin tree, and run component tests."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import shattered_integration as integration


def _assemble_contract_tree(source_root, output, manifest, profile=None):
    profile_config = integration._profile_config(manifest, profile)
    selected_prs = set(profile_config["source_prs"])
    selected_components = [
        item for item in manifest["components"] if item["id"] in profile_config["components"]
    ]
    output.mkdir(parents=True, exist_ok=False)
    plugins = output / "Plugins"
    pbs = output / "PBS"
    plugins.mkdir()
    pbs.mkdir()
    source_files = {}
    for item in manifest["required_source_files"]:
        if item["pr"] not in selected_prs or not item.get("stage"):
            continue
        source = source_root / f"pr-{item['pr']}" / item["path"]
        source_files[(item["pr"], item["path"])] = source
        relative = Path(item["path"])
        if relative.parts[:2] == ("essentials", "Plugins"):
            destination = plugins.joinpath(*relative.parts[2:])
            if destination.exists():
                raise integration.IntegrationError(
                    f"duplicate assembled plugin path: {destination.relative_to(output)}"
                )
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)

    installed = {}
    for metadata in sorted(plugins.glob("*/meta.txt")):
        info = integration._parse_meta(metadata.read_text(encoding="utf-8-sig"))
        name, version = info.get("name"), info.get("version")
        if not name or not version:
            raise integration.IntegrationError(f"plugin metadata incomplete: {metadata.parent.name}")
        if name in installed:
            raise integration.IntegrationError(f"duplicate plugin name in synthetic tree: {name}")
        installed[name] = version

    for item in manifest["required_source_files"]:
        if item["pr"] not in selected_prs:
            continue
        target = item.get("pbs_target")
        if not target:
            continue
        source = source_root / f"pr-{item['pr']}" / item["path"]
        destination = pbs / Path(target).name
        sections = integration._pbs_sections(source)
        prior = integration._pbs_sections(destination) if destination.exists() else []
        overlap = set(sections) & set(prior)
        if overlap:
            raise integration.IntegrationError(
                f"duplicate assembled PBS section in {target}: {sorted(overlap)}"
            )
        with destination.open("ab") as stream:
            stream.write(source.read_bytes())

    expected_names = {component["name"] for component in selected_components}
    if set(installed) != expected_names:
        raise integration.IntegrationError(
            f"assembled plugin inventory mismatch: missing={sorted(expected_names - set(installed))}, "
            f"extra={sorted(set(installed) - expected_names)}"
        )
    component_names = set(installed)
    archive_names = {
        archive["name"] for archive in manifest["plugin_archives"]
        if archive["id"] in profile_config["archives"]
    }
    declared_order = [
        name for name in manifest["load_order"]
        if name in expected_names or name in archive_names
    ]
    return {
        "plugin_count": len(installed),
        "plugin_names": [name for name in manifest["load_order"] if name in component_names],
        "declared_load_order": declared_order,
        "archives_not_in_synthetic_tree": sorted(archive_names),
        "pbs_sections": {
            path.name: integration._pbs_sections(path)
            for path in sorted(pbs.glob("*.txt"))
        },
        "runtime_verified": False,
    }


def _prepare_test_dependencies(source_root, manifest, profile=None):
    selected_prs = set(integration._profile_config(manifest, profile)["source_prs"])
    prs = {pr["id"]: pr for pr in manifest["pull_requests"]}
    components_by_pr = {component["pr"]: component for component in manifest["components"]}
    sources_by_pr = {}
    for item in manifest["required_source_files"]:
        if item.get("stage") and item["path"].startswith("essentials/Plugins/"):
            sources_by_pr.setdefault(item["pr"], []).append(item)

    for suite in manifest["contract_test_suites"]:
        if suite["pr"] not in selected_prs:
            continue
        component = components_by_pr.get(suite["pr"])
        if not component:
            continue
        pending = list(component.get("build_requires", []))
        dependencies = set()
        while pending:
            dependency = pending.pop()
            if dependency in dependencies:
                continue
            dependencies.add(dependency)
            pending.extend(prs[dependency].get("build_requires", []))
        test_root = source_root / f"pr-{suite['pr']}"
        for dependency in sorted(dependencies):
            for item in sources_by_pr.get(dependency, []):
                source = source_root / f"pr-{dependency}" / item["path"]
                relative = Path(item["path"])
                destination = test_root.joinpath(*relative.parts)
                if destination.exists():
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)


def _run_tests(source_root, manifest, git_repo, profile=None):
    selected_prs = set(integration._profile_config(manifest, profile)["source_prs"])
    _prepare_test_dependencies(source_root, manifest, profile)
    results = []
    for suite in manifest["contract_test_suites"]:
        if suite["pr"] not in selected_prs:
            continue
        working_directory = source_root / f"pr-{suite['pr']}"
        for path in suite.get("support_from_main", []):
            integration.safe_relative(path, "main test support file")
            support = integration._git(
                git_repo, "show", f"{manifest['main']['commit']}:{path}", binary=True
            )
            destination = working_directory / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(support)
        for command in suite["commands"]:
            result = subprocess.run(
                command,
                cwd=working_directory,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            results.append({
                "pr": suite["pr"],
                "commit": next(
                    pr["head"] for pr in manifest["pull_requests"]
                    if pr["id"] == suite["pr"]
                ),
                "command": command,
                "exit_code": result.returncode,
                "output": result.stdout,
            })
            if result.returncode:
                raise integration.IntegrationError(
                    f"PR #{suite['pr']} component test failed ({' '.join(command)}):\n"
                    f"{result.stdout}"
                )
    return results


def run_contract(git_repo, manifest, profile=None):
    integration.validate_manifest(manifest)
    with tempfile.TemporaryDirectory(prefix="shattered-contract-") as temp:
        temp_root = Path(temp)
        source_root = temp_root / "sources"
        tree_root = temp_root / "assembled"
        export = integration.export_sources(git_repo, source_root, manifest, profile=profile)
        lock = integration.verify_source_bundle(source_root, manifest, profile=profile)
        assembly = _assemble_contract_tree(source_root, tree_root, manifest, profile=profile)
        integration._verify_first_party_hooks(
            source_root, manifest,
            set(integration._profile_config(manifest, profile)["components"]),
        )
        tests = _run_tests(source_root, manifest, git_repo, profile=profile)
        return {
            "status": "synthetic_contract_passed",
            "evidence_tier": "rights-cleared-synthetic-source-contract",
            "profile": profile or "full",
            "git_verified": export["git_verified"],
            "source_prs": [
                {
                    "id": pr["id"], "commit": pr["head"], "base": pr["base"],
                    "resolved_ref": pr["source_ref"], "resolved_commit": pr["source_commit"],
                }
                for pr in lock["pull_requests"]
            ],
            "source_files": len(lock["files"]),
            "assembled_tree": assembly,
            "component_test_commands": len(tests),
            "component_tests": [
                {key: value for key, value in result.items() if key != "output"}
                for result in tests
            ],
            "native_essentials_verified": False,
            "gameplay_or_save_reload_verified": False,
            "android_verified": False,
        }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--git-repo", required=True, help="full local Shattered Git checkout")
    parser.add_argument("--manifest", default=str(integration.MANIFEST_PATH))
    parser.add_argument("--profile", choices=["initial_slice"])
    args = parser.parse_args(argv)
    try:
        manifest = integration.load_manifest(args.manifest)
        print(json.dumps(
            run_contract(args.git_repo, manifest, profile=args.profile),
            indent=2,
            sort_keys=True,
        ))
        return 0
    except (integration.IntegrationError, OSError, subprocess.SubprocessError) as exc:
        print(f"integration contract failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
