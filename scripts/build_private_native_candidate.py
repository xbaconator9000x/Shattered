#!/usr/bin/env python3
"""Build ONE private, source-pinned Essentials runtime candidate.

Combines authorised local base + all reviewed Shattered source plugins, compiles
the native PluginScripts.rxdata archive, and moves offline-only installers out
of Essentials' debug plugin scan. Does NOT install the HnS map, compile PBS,
launch mkxp-z, test gameplay, or make a distributable release.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from stage_essentials import ROOT, stage
from prepare_linux_map_aliases import prepare as prepare_linux_aliases
from install_private_mount_composites import build as build_mount_composites

RUNTIME_NAMES = (
    "Shattered Companion", "Shattered Core", "Shattered Gameplay", "Shattered Dojo", "Shattered Equipment",
    "Shattered Gate Story", "Shattered HnS Gate", "Shattered Murkrow Rescue",
    "Shattered Raid", "Shattered Route22", "Shattered Viridian",
    "Shattered World Links",
)
REPORT = "SHATTERED_NATIVE_CANDIDATE.json"
STALE_RECEIPTS = (
    "SHATTERED_NATIVE_COMPILE_REPORT.json",
    "SHATTERED_RUNTIME_ISOLATION_REPORT.json",
    REPORT,
)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def install_available_mount_composites(candidate):
    """Install only source-backed rider sheets; unsupported mounts stay disabled."""
    characters = candidate / "Graphics" / "Characters"
    onix = candidate / "Graphics" / "Pokemon" / "Front" / "ONIX.png"
    players = [characters / f"{name}.png" for name in ("boy_run", "girl_run")]
    if not onix.is_file() or not any(path.is_file() for path in players):
        return None
    return build_mount_composites(candidate)


def reset_prior_runtime_outputs(candidate):
    """Remove only generated Shattered outputs from a transient rebuild stage."""
    for name in STALE_RECEIPTS:
        path = candidate / name
        if path.is_symlink():
            raise ValueError(f"unsafe stale runtime receipt: {name}")
        if path.exists():
            if not path.is_file():
                raise ValueError(f"stale runtime receipt is not a file: {name}")
            path.unlink()
    offline = candidate / "SHATTERED_OFFLINE_TOOLS"
    if offline.is_symlink():
        raise ValueError("unsafe stale offline tools directory")
    if offline.exists():
        if not offline.is_dir():
            raise ValueError("stale offline tools path is not a directory")
        for path in offline.rglob("*"):
            if path.is_symlink():
                raise ValueError("symlink in stale offline tools directory")
        shutil.rmtree(offline)


def source_pin(requested=None):
    if requested is not None and not re.fullmatch(r"[0-9a-f]{40}", requested):
        raise ValueError("source SHA must be a full lowercase Git commit")
    try:
        root = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "--show-toplevel"],
            check=True, capture_output=True, text=True, timeout=10
        ).stdout.strip()
        if Path(root).resolve() != ROOT.resolve():
            raise ValueError("source directory is not the Git checkout root")
        sha = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True, timeout=10
        ).stdout.strip()
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ValueError("Git returned an invalid source commit")
        if requested is not None and requested != sha:
            raise ValueError("requested source SHA does not match checkout HEAD")
        dirty = subprocess.run(
            ["git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=no"],
            check=True, capture_output=True, text=True, timeout=10
        ).stdout
        if dirty.strip():
            raise ValueError("source checkout has uncommitted tracked changes")
        return sha, True
    except (FileNotFoundError, subprocess.CalledProcessError):
        if requested is None:
            raise ValueError("source-only bundle requires explicit --source-sha")
        return requested, False


def run_ruby(script, args):
    command = ["ruby", str(ROOT / "scripts" / script), *args]
    result = subprocess.run(
        command, cwd=str(ROOT), capture_output=True, text=True,
        check=False, timeout=180
    )
    if result.returncode:
        raise RuntimeError(
            f"{script} failed (exit {result.returncode}): "
            + (result.stderr or result.stdout)[-2000:]
        )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"{script} returned invalid JSON") from error


def build(project, output, requested_sha=None, linux_aliases=False):
    sha, verified_checkout = source_pin(requested_sha)
    base = Path(project).resolve()
    destination = Path(output).absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError("candidate output already exists; use a fresh path")
    if not destination.parent.is_dir() or destination.parent.is_symlink():
        raise ValueError("candidate output parent is missing or unsafe")
    if base == destination or base in destination.parents or destination in base.parents:
        raise ValueError("private source and candidate must not be nested")
    base_archive = base / "Data" / "PluginScripts.rxdata"
    if not base_archive.is_file() or base_archive.is_symlink():
        raise ValueError("missing authorised native PluginScripts.rxdata")
    base_archive_sha = digest(base_archive)
    source_files = {}
    for name in RUNTIME_NAMES:
        for file in sorted((ROOT / "essentials" / "Plugins" / name).rglob("*")):
            if file.is_file():
                if file.is_symlink():
                    raise ValueError("symlinked repository plugin source")
                source_files[str(file.relative_to(ROOT))] = digest(file)
    source_files["essentials/PBS/HUMAN.pbs"] = digest(ROOT / "essentials/PBS/HUMAN.pbs")
    source_files["scripts/stage_essentials.py"] = digest(ROOT / "scripts/stage_essentials.py")
    source_files["scripts/compile_private_plugins.rb"] = digest(ROOT / "scripts/compile_private_plugins.rb")
    source_files["scripts/finalize_private_runtime.rb"] = digest(ROOT / "scripts/finalize_private_runtime.rb")
    with tempfile.TemporaryDirectory(prefix=".shattered-candidate-", dir=destination.parent) as temporary:
        candidate = Path(temporary) / "project"
        # A prior private Shattered candidate is a supported rebuild base. Replace
        # only reviewed runtime-plugin directories in the transient staging copy.
        staged = stage(base, candidate, include_runtime_set=True, replace_runtime_set=True)
        reset_prior_runtime_outputs(candidate)
        mounts = install_available_mount_composites(candidate)
        compiled = run_ruby(
            "compile_private_plugins.rb",
            ["--project", str(candidate), "--rebuild-existing", *(
                item for name in RUNTIME_NAMES for item in ("--plugin", name)
            )]
        )
        isolated = run_ruby("finalize_private_runtime.rb", ["--project", str(candidate)])
        if sorted(isolated["runtime_plugin_names"]) != sorted(
            name for name in RUNTIME_NAMES if name not in
            ("Shattered HnS Gate", "Shattered World Links")
        ):
            raise RuntimeError("native runtime plugin inventory incomplete")
        if compiled["compiled_archive_sha256"] != isolated["compiled_archive_sha256"]:
            raise RuntimeError("compiled native archive changed during isolation")
        aliases = prepare_linux_aliases(candidate) if linux_aliases else None
        receipt = {
            "kind": "private_compiled_shattered_source_candidate_not_playable_acceptance",
            "source_sha": sha,
            "source_sha_verified_git_checkout": verified_checkout,
            "source_file_sha256": source_files,
            "original_plugin_archive_sha256": base_archive_sha,
            "compiled_plugin_archive_sha256": digest(candidate / "Data/PluginScripts.rxdata"),
            "runtime_plugins": isolated["runtime_plugin_names"],
            "offline_installers_isolated": len(isolated["moved"]),
            "mount_composites": mounts,
            "linux_map_alias_count": aliases["alias_count"] if aliases else None,
            "hns_gate_installed": False,
            "native_pbs_compiled": False,
            "native_engine_launched": False,
            "gameplay_verified": False,
            "save_reload_verified": False,
            "android_verified": False,
            "distributable": False,
        }
        if receipt["compiled_plugin_archive_sha256"] != compiled["compiled_archive_sha256"]:
            raise RuntimeError("candidate archive hash mismatch")
        (candidate / REPORT).write_text(json.dumps(receipt, indent=2) + "\n")
        candidate.rename(destination)
        return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True, help="private extracted authorised Essentials v21.1 project")
    parser.add_argument("--output", required=True, help="fresh private candidate directory")
    parser.add_argument("--source-sha", help="required for source-only bundles without .git")
    parser.add_argument("--linux-map-aliases", action="store_true", help="create verified lowercase map aliases for Linux")
    args = parser.parse_args()
    print(json.dumps(build(args.project, args.output, args.source_sha, args.linux_map_aliases), indent=2))


if __name__ == "__main__":
    main()
