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
from pathlib import PurePosixPath
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile

from stage_essentials import ROOT, stage
from prepare_linux_map_aliases import prepare as prepare_linux_aliases

BASE_REQUIRED_FILES = (
    "Game.ini",
    "Data/PluginScripts.rxdata",
    "Data/Scripts.rxdata",
    "Data/MapInfos.rxdata",
    "Data/Tilesets.rxdata",
    "PBS/pokemon.txt",
    "PBS/items.txt",
)
MAX_BASE_ARCHIVE_ENTRIES = 150_000
MAX_BASE_ARCHIVE_BYTES = 4_000_000_000
MAX_BASE_ENTRY_BYTES = 1_000_000_000
RUNTIME_NAMES = (
    "Shattered Core", "Shattered Dojo", "Shattered Equipment",
    "Shattered Gate Story", "Shattered HnS Gate", "Shattered Murkrow Rescue",
    "Shattered Raid", "Shattered Route22", "Shattered Viridian",
    "Shattered World Links",
)
REPORT = "SHATTERED_NATIVE_CANDIDATE.json"


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


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


def validate_base_rights(archive, rights_record):
    archive_path = Path(archive).absolute()
    rights_path = Path(rights_record).absolute()
    if not archive_path.is_file() or archive_path.is_symlink():
        raise ValueError("base archive is missing or symlinked")
    if archive_path.stat().st_size > MAX_BASE_ARCHIVE_BYTES:
        raise ValueError("base archive exceeds the compressed size limit")
    if not rights_path.is_file() or rights_path.is_symlink():
        raise ValueError("base rights record is missing or symlinked")
    archive_sha = digest(archive_path)
    rights_bytes = rights_path.read_bytes()
    try:
        record = json.loads(rights_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("base rights record is not valid JSON") from error
    required_text = ("source", "license", "basis")
    if not isinstance(record, dict) or record.get("id") != "base_project" or \
       record.get("rights_cleared") is not True or \
       record.get("engine_version") != "21.1" or \
       record.get("type") != "essentials_project" or \
       any(not isinstance(record.get(key), str) or not record[key].strip()
           for key in required_text):
        raise ValueError("base rights record must attest an authorized Essentials 21.1 source")
    if record.get("archive_sha256") != archive_sha:
        raise ValueError("base archive SHA256 differs from its rights record")
    return {
        "kind": "authorized_essentials_21_1_distribution_zip",
        "archive_sha256": archive_sha,
        "rights_record_sha256": hashlib.sha256(rights_bytes).hexdigest(),
    }


def extract_base_archive(archive, destination):
    """Safely extract a local Essentials distribution and return its project root."""
    archive_path = Path(archive).absolute()
    destination = Path(destination).absolute()
    if not archive_path.is_file() or archive_path.is_symlink():
        raise ValueError("base archive is missing or symlinked")
    if destination.exists() or destination.is_symlink():
        raise ValueError("base extraction destination already exists")
    destination.mkdir(parents=True)
    try:
        return _extract_base_archive_contents(archive_path, destination)
    except BaseException:
        shutil.rmtree(destination, ignore_errors=True)
        raise


def _extract_base_archive_contents(archive_path, destination):
    try:
        with zipfile.ZipFile(archive_path) as bundle:
            members = bundle.infolist()
            if not members or len(members) > MAX_BASE_ARCHIVE_ENTRIES:
                raise ValueError("base archive has an invalid number of entries")
            total_size = sum(member.file_size for member in members)
            if total_size > MAX_BASE_ARCHIVE_BYTES:
                raise ValueError("base archive exceeds the uncompressed size limit")
            seen = set()
            files = []
            for member in members:
                name = member.filename.replace("\\", "/")
                parts = name.rstrip("/").split("/")
                if not name or name.startswith("/") or re.match(r"^[A-Za-z]:", name) or \
                   any(part in ("", ".", "..") for part in parts):
                    raise ValueError(f"unsafe base archive path: {member.filename}")
                normalized = PurePosixPath(*parts).as_posix()
                key = normalized.casefold()
                if key in seen:
                    raise ValueError(f"duplicate base archive path: {member.filename}")
                seen.add(key)
                mode = (member.external_attr >> 16) & 0o170000
                if mode == stat.S_IFLNK or mode not in (0, stat.S_IFDIR, stat.S_IFREG):
                    raise ValueError(f"non-regular base archive member: {member.filename}")
                if member.flag_bits & 0x1:
                    raise ValueError(f"encrypted base archive member: {member.filename}")
                if member.file_size > MAX_BASE_ENTRY_BYTES:
                    raise ValueError(f"oversized base archive member: {member.filename}")
                if not member.is_dir():
                    files.append((member, normalized))
            for member, normalized in files:
                target = destination.joinpath(*PurePosixPath(normalized).parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                written = 0
                with bundle.open(member) as source, target.open("xb") as output:
                    while True:
                        chunk = source.read(1024 * 1024)
                        if not chunk:
                            break
                        written += len(chunk)
                        if written > member.file_size or written > MAX_BASE_ENTRY_BYTES:
                            raise ValueError(f"base archive member expanded beyond its declared size: {normalized}")
                        output.write(chunk)
                if written != member.file_size:
                    raise ValueError(f"base archive member size mismatch: {normalized}")
    except (zipfile.BadZipFile, OSError, RuntimeError) as error:
        raise ValueError(f"cannot safely extract Essentials base archive: {error}") from error

    required = set(BASE_REQUIRED_FILES)
    roots = []
    for game_ini in destination.rglob("Game.ini"):
        root = game_ini.parent
        if all((root / relative).is_file() and not (root / relative).is_symlink()
               for relative in required):
            roots.append(root)
    if len(roots) != 1:
        raise ValueError("base archive must contain exactly one complete Essentials project root")
    return roots[0]


def _build_project(project, output, requested_sha=None, linux_aliases=False,
                   base_source=None, gate_data=None, gate_tileset_image=None):
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
    source_files["scripts/build_private_native_candidate.py"] = digest(
        ROOT / "scripts/build_private_native_candidate.py"
    )
    source_files["scripts/stage_essentials.py"] = digest(ROOT / "scripts/stage_essentials.py")
    source_files["scripts/compile_private_plugins.rb"] = digest(ROOT / "scripts/compile_private_plugins.rb")
    source_files["scripts/finalize_private_runtime.rb"] = digest(ROOT / "scripts/finalize_private_runtime.rb")
    source_files["scripts/prepare_linux_map_aliases.py"] = digest(
        ROOT / "scripts/prepare_linux_map_aliases.py"
    )
    with tempfile.TemporaryDirectory(prefix=".shattered-candidate-", dir=destination.parent) as temporary:
        candidate = Path(temporary) / "project"
        staged = stage(
            base, candidate, gate_data=gate_data,
            gate_image=gate_tileset_image, include_runtime_set=True
        )
        compiled = run_ruby(
            "compile_private_plugins.rb",
            ["--project", str(candidate), *(
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
            "linux_map_alias_count": aliases["alias_count"] if aliases else None,
            "hns_gate_source_staged": gate_data is not None,
            "hns_gate_installed": False,
            "native_pbs_compiled": False,
            "native_engine_launched": False,
            "gameplay_verified": False,
            "save_reload_verified": False,
            "android_verified": False,
            "distributable": False,
        }
        if base_source is not None:
            receipt["base_source"] = base_source
        if receipt["compiled_plugin_archive_sha256"] != compiled["compiled_archive_sha256"]:
            raise RuntimeError("candidate archive hash mismatch")
        (candidate / REPORT).write_text(json.dumps(receipt, indent=2) + "\n")
        candidate.rename(destination)
        return receipt


def build(project, output, requested_sha=None, linux_aliases=False, *,
          base_archive=None, rights_record=None, gate_data=None,
          gate_tileset_image=None):
    if (project is None) == (base_archive is None):
        raise ValueError("provide exactly one of an extracted project or a base archive")
    if (gate_data is None) != (gate_tileset_image is None):
        raise ValueError("--gate-data and --gate-tileset-image must be provided together")
    if base_archive is None:
        if rights_record is not None:
            raise ValueError("base rights record is only valid with --base-archive")
        return _build_project(
            project, output, requested_sha, linux_aliases,
            gate_data=gate_data, gate_tileset_image=gate_tileset_image
        )
    if rights_record is None:
        raise ValueError("--base-archive requires a SHA-pinned local --rights-record")
    provenance = validate_base_rights(base_archive, rights_record)
    destination = Path(output).absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError("candidate output already exists; use a fresh path")
    if not destination.parent.is_dir() or destination.parent.is_symlink():
        raise ValueError("candidate output parent is missing or unsafe")
    with tempfile.TemporaryDirectory(prefix=".shattered-base-", dir=destination.parent) as temporary:
        base = extract_base_archive(base_archive, Path(temporary) / "base")
        return _build_project(
            base, output, requested_sha, linux_aliases, provenance,
            gate_data, gate_tileset_image
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    base = parser.add_mutually_exclusive_group(required=True)
    base.add_argument("--project", help="private extracted authorised Essentials v21.1 project")
    base.add_argument("--base-archive", help="local authorized Essentials v21.1 distribution ZIP")
    parser.add_argument("--rights-record", help="local JSON rights attestation pinned to --base-archive SHA256")
    parser.add_argument("--output", required=True, help="fresh private candidate directory")
    parser.add_argument("--source-sha", help="required for source-only bundles without .git")
    parser.add_argument("--linux-map-aliases", action="store_true", help="create verified lowercase map aliases for Linux")
    parser.add_argument("--gate-data", help="private converted HnS reception-gate JSON bundle")
    parser.add_argument("--gate-tileset-image", help="rights-cleared 256px-wide gate tileset PNG")
    args = parser.parse_args()
    print(json.dumps(build(args.project, args.output, args.source_sha, args.linux_map_aliases,
                           base_archive=args.base_archive, rights_record=args.rights_record,
                           gate_data=args.gate_data,
                           gate_tileset_image=args.gate_tileset_image), indent=2))


if __name__ == "__main__":
    main()
