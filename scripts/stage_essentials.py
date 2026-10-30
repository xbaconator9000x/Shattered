#!/usr/bin/env python3
"""Safely stage Shattered Core and optionally approved upstream plugin ZIPs.

Never modifies original. Doesn't compile plugin scripts or test Android runtime.
"""
import argparse
import binascii
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / 'development' / 'plugin_manifest.json'
ALLOW_ROOTS = {'Audio', 'Graphics', 'Plugins', 'Data', 'PBS'}
MAX_ENTRIES = 20000
MAX_ARCHIVE_BYTES = 600 * 1024 * 1024
MAX_INDIVIDUAL_BYTES = 80 * 1024 * 1024


def plugins_by_id():
    return {p['id']: p for p in json.loads(MANIFEST.read_text())['plugins']}


def clean_path(name):
    raw = name.replace('\\', '/')
    if raw.startswith('/') or re.match(r'^[a-zA-Z]:', raw):
        raise ValueError('absolute ZIP member path: ' + name)
    parts = list(PurePosixPath(raw).parts)
    if '..' in parts or '.' in parts or '\x00' in name:
        raise ValueError('unsafe ZIP member path: ' + name)
    # Only strip one generic top-level ZIP folder when followed by an expected game root.
    if len(parts) >= 2 and parts[0] not in ALLOW_ROOTS and parts[1] in ALLOW_ROOTS:
        parts = parts[1:]
    if not parts or parts[0] not in ALLOW_ROOTS:
        raise ValueError('unsupported ZIP member destination: ' + name)
    if len(parts) < 2:
        return None  # directory of allowed root
    return Path(*parts)


def reject_symlinked_project(project):
    """Never copy a source project through links to data outside the authorised tree."""
    project = Path(project)
    for ancestor in (project, *project.parents):
        if ancestor.is_symlink():
            raise ValueError(f'project path contains symlink: {ancestor}')
    for root, dirs, files in os.walk(project, followlinks=False):
        for name in dirs + files:
            entry = Path(root) / name
            info = entry.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise ValueError(f'project contains symlink: {entry}')
            if stat.S_ISDIR(info.st_mode):
                continue
            if not stat.S_ISREG(info.st_mode):
                raise ValueError(f'project contains unsupported special file: {entry}')
            if info.st_nlink > 1:
                raise ValueError(f'project contains hardlinked file: {entry}')


def reject_linked_destination(dest, path, overwrite):
    """Prevent archive writes through symlinks or shared hardlinked files."""
    root = Path(dest).absolute()
    for ancestor in (root, *root.parents):
        if ancestor.is_symlink():
            raise ValueError(f'archive destination contains symlink: {ancestor}')
    target = root
    for part in path.parts:
        target = target / part
        if target.is_symlink():
            raise ValueError(f'archive destination contains symlink: {target}')
    if overwrite and target.exists():
        # is_file() is false for FIFOs, sockets and directories. Opening a FIFO
        # for writing could hang the staging job; reject every non-regular target.
        info = target.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink > 1:
            raise ValueError(f'unsafe archive overwrite target: {path}')


def safe_zip_install(archive, dest, plugin_id, overwrite=False):
    staged = []
    seen_paths = set()
    seen_parent_paths = set()
    with zipfile.ZipFile(archive) as z:
        members = z.infolist()
        if len(members) > MAX_ENTRIES or sum(m.file_size for m in members) > MAX_ARCHIVE_BYTES:
            raise ValueError('plugin ZIP exceeds safety limits')
        # Validate ALL members first to avoid partial writes from malformed archives.
        for member in members:
            if (member.external_attr >> 16) & 0o170000 == stat.S_IFLNK:
                raise ValueError('ZIP symlink rejected: ' + member.filename)
            if member.file_size > MAX_INDIVIDUAL_BYTES:
                raise ValueError('oversized ZIP member: ' + member.filename)
            path = clean_path(member.filename)
            if path is None or member.is_dir():
                continue
            # RPG Maker projects may be staged on case-insensitive filesystems.
            # Reject case-only duplicates and file-vs-directory conflicts before
            # writing any member, regardless of the current host filesystem.
            key = tuple(part.casefold() for part in path.parts)
            if (key in seen_paths or key in seen_parent_paths or
                    any(key[:i] in seen_paths for i in range(1, len(key)))):
                raise ValueError(f'duplicate archive destination or path conflict: {path}')
            seen_paths.add(key)
            seen_parent_paths.update(key[:i] for i in range(1, len(key)))
            reject_linked_destination(dest, path, overwrite)
            if path.parts[0] == 'PBS' and path.name == 'pokemon.txt':
                raise ValueError('refusing to replace entire PBS/pokemon.txt')
            if path.parts[0] == 'Data' and path.name == 'Scripts.rxdata':
                raise ValueError('refusing to replace the RPG Maker scripts archive')
            target = dest / path
            if target.exists() and not overwrite:
                raise ValueError(f'overwrite requires review: {path} ({plugin_id})')
            staged.append((member, path))
        # A ZIP can have valid headers but a corrupt later member. Validate
        # every member's decompression and CRC before touching the project,
        # otherwise an early member could be written before a later CRC error.
        # Stream in bounded chunks; do not hold plugin archives in memory.
        for member, _path in staged:
            with z.open(member) as stream:
                while stream.read(1024 * 1024):
                    pass
        for member, path in staged:
            target = dest / path
            target.parent.mkdir(parents=True, exist_ok=True)
            with z.open(member) as stream, target.open('wb') as out:
                shutil.copyfileobj(stream, out)
    return [str(path) for _, path in staged]


def install_shattered_core(dest):
    source = ROOT / 'essentials' / 'Plugins' / 'Shattered Core'
    target = dest / 'Plugins' / 'Shattered Core'
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source, target)
    species = dest / 'PBS' / 'pokemon.txt'
    if not species.is_file():
        raise ValueError('missing PBS/pokemon.txt (not an Essentials v21.1 project?)')
    original = species.read_text(encoding='utf-8-sig')
    if re.search(r'^\[HUMAN\]\s*$', original, flags=re.M):
        return {'core': str(target.relative_to(dest)), 'human_pbs': 'already-present'}
    addition = (ROOT / 'essentials' / 'PBS' / 'HUMAN.pbs').read_text()
    species.write_text(original.rstrip() + '\n#-------------------------------\n' + addition, encoding='utf-8')
    return {'core': str(target.relative_to(dest)), 'human_pbs': 'appended'}


EQUIPMENT_ITEMS = ('KNIFE', 'BRAZIER', 'SLING', 'SPRAYGUN', 'BUCKLER')
EQUIPMENT_MOVES = ('SLASH', 'EMBER', 'ROCKTHROW', 'BUBBLE', 'DEFENSECURL')


def install_shattered_equipment(dest):
    """Opt-in source staging only; never invent missing native item/move PBS."""
    source = ROOT / 'essentials' / 'Plugins' / 'Shattered Equipment'
    if not all((source / name).is_file() for name in ('001_Equipment.rb', 'meta.txt')):
        raise ValueError('Shattered Equipment source plugin is missing')
    plugins = dest / 'Plugins'
    if plugins.is_dir() and any(
        entry.name.casefold() == 'shattered equipment' for entry in plugins.iterdir()
    ):
        raise ValueError('Shattered Equipment would overwrite an existing plugin')
    for relative, ids in (
        ('PBS/items.txt', EQUIPMENT_ITEMS),
        ('PBS/moves.txt', EQUIPMENT_MOVES),
    ):
        path = dest / relative
        if not path.is_file():
            raise ValueError(f'Shattered Equipment requires reviewed {relative}')
        contents = path.read_text(encoding='utf-8-sig')
        missing = [
            item for item in ids
            if re.search(r'^\[' + re.escape(item) + r'\]\s*$', contents, flags=re.M) is None
        ]
        if missing:
            raise ValueError(
                f'Shattered Equipment missing {relative} IDs: ' + ', '.join(missing)
            )
    target = plugins / 'Shattered Equipment'
    shutil.copytree(source, target)
    return {
        'plugin': str(target.relative_to(dest)),
        'pbs_items_checked': list(EQUIPMENT_ITEMS),
        'pbs_moves_checked': list(EQUIPMENT_MOVES),
        'runtime_verified': False,
    }


def install_hns_gate(dest, gate_data, gate_image):
    data = Path(gate_data)
    image = Path(gate_image)
    bundle = json.loads(data.read_text(encoding="utf-8"))
    if bundle.get("format") != "shattered-hns-rmxp-map" or bundle.get("format_version") != 1:
        raise ValueError("unsupported HnS reception gate bundle")
    image_name = bundle.get("target", {}).get("tileset_image")
    if not isinstance(image_name, str) or not re.fullmatch(r"[A-Za-z0-9_-]+\.png", image_name):
        raise ValueError("invalid HnS gate tileset image name")
    image_bytes = image.read_bytes()
    width, height = png_dimensions(image_bytes)
    if width != 256 or height == 0 or height % 32:
        raise ValueError("HnS gate tileset PNG must be 256 pixels wide and a multiple of 32 high")
    plugin_source = ROOT / "essentials" / "Plugins" / "Shattered HnS Gate" / "001_Import.rb"
    meta_source = ROOT / "essentials" / "Plugins" / "Shattered HnS Gate" / "meta.txt"
    plugin_target = dest / "Plugins" / "Shattered HnS Gate"
    graphics_target = dest / "Graphics" / "Tilesets" / image_name
    if plugin_target.exists() or graphics_target.exists():
        raise ValueError("HnS gate import would overwrite existing project files")
    plugin_target.mkdir(parents=True)
    shutil.copyfile(plugin_source, plugin_target / "001_Import.rb")
    shutil.copyfile(meta_source, plugin_target / "meta.txt")
    shutil.copyfile(data, plugin_target / "reception_gate.json")
    graphics_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(image, graphics_target)
    return {
        "plugin": str((plugin_target / "001_Import.rb").relative_to(dest)),
        "bundle": str((plugin_target / "reception_gate.json").relative_to(dest)),
        "tileset_image": str(graphics_target.relative_to(dest)),
        "native_map_generated": False,
    }


def png_dimensions(data):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("HnS gate tileset must be a PNG")
    offset = 8
    width = height = 0
    saw_idat = saw_iend = False
    while offset + 12 <= len(data):
        length = int.from_bytes(data[offset:offset + 4], "big")
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        if end > len(data):
            raise ValueError("invalid/truncated HnS gate PNG")
        chunk = data[offset + 4:end - 4]
        expected_crc = int.from_bytes(data[end - 4:end], "big")
        if binascii.crc32(chunk) & 0xFFFFFFFF != expected_crc:
            raise ValueError("invalid HnS gate PNG chunk checksum")
        payload = data[offset + 8:end - 4]
        if offset == 8:
            if kind != b"IHDR" or length != 13:
                raise ValueError("invalid HnS gate PNG header")
            width = int.from_bytes(payload[:4], "big")
            height = int.from_bytes(payload[4:8], "big")
        elif kind == b"IDAT":
            saw_idat = True
        elif kind == b"IEND":
            saw_iend = length == 0 and end == len(data)
            break
        offset = end
    if not width or not height or not saw_idat or not saw_iend:
        raise ValueError("invalid/incomplete HnS gate PNG")
    return width, height


def stage(project, output, archives=(), overwrite=False, gate_data=None, gate_image=None,
          include_equipment=False):
    project = Path(project).absolute()
    reject_symlinked_project(project)
    project = project.resolve()
    output = Path(output).resolve()
    if not (project / 'Game.ini').is_file() or not (project / 'PBS' / 'pokemon.txt').is_file():
        raise ValueError('input must contain Game.ini and PBS/pokemon.txt')
    if project == output or project in output.parents or output in project.parents:
        raise ValueError('input/output must be separate directories, not nested')
    if output.exists():
        raise ValueError('output exists; choose a fresh staging directory')
    if (gate_data is None) != (gate_image is None):
        raise ValueError("HnS gate staging requires both --gate-data and --gate-tileset-image")
    known = plugins_by_id()
    requested = {}
    for item in archives:
        key, sep, name = item.partition('=')
        if not sep or key not in known or key == 'shattered_core':
            raise ValueError(f'invalid archive argument: {item}')
        if key in requested:
            raise ValueError('duplicate archive for ' + key)
        requested[key] = Path(name).resolve()
        if not requested[key].is_file():
            raise ValueError('plugin ZIP file missing: ' + name)
    # Explicit upstream deps must be supplied with this staging or exist in base project.
    base_meta = list((project / 'Plugins').glob('*/meta.txt')) if (project / 'Plugins').is_dir() else []
    known_names = [f.read_text(encoding='utf-8-sig', errors='replace') for f in base_meta]
    for key in requested:
        for dep in known[key]['dependencies']:
            if dep in requested:
                continue
            dep_name = known[dep]['name']
            if not any(re.search(r'^Name\s*=\s*'+re.escape(dep_name)+r'\s*$', m, re.M) for m in known_names):
                raise ValueError(f'{key} requires {dep}; provide its archive or install in base')
    # Install into a staging temp dir and atomically rename on success.
    with tempfile.TemporaryDirectory(prefix='shattered-stage-', dir=output.parent) as temp:
        target = Path(temp) / 'project'
        shutil.copytree(project, target)
        report = {'engine': 'Essentials 21.1', 'source': str(project),
                  'runtime_verified': False, 'plugin_archives': {},
                  'core': install_shattered_core(target),
                  'caveats': ['Requires Essentials debug compilation of PluginScripts.rxdata',
                              'JoiPlay/NaviaXP testing not done',
                              'Plugin version/license/manual conflict review required']}
        if include_equipment:
            report['equipment'] = install_shattered_equipment(target)
            report['caveats'].append(
                'Equipment PBS IDs checked, but native script compilation, item ownership, '
                'battle move UI and save/reload remain unverified')
        if gate_data is not None:
            report["hns_gate"] = install_hns_gate(target, gate_data, gate_image)
            report["caveats"].append(
                "Run pbInstallShatteredHNSReceptionGate in Essentials to create native map data; "
                "engine compilation and warp/collision playtest remain required")
        for key, archive in requested.items():
            report['plugin_archives'][key] = safe_zip_install(archive, target, key, overwrite)
        (target / 'SHATTERED_STAGING_REPORT.json').write_text(json.dumps(report, indent=2) + '\n')
        shutil.move(str(target), str(output))
    return report


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--project', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--archive', action='append', default=[], help='pluginid=/local/verified.zip')
    p.add_argument('--allow-overwrite', action='store_true', help='only after reviewing collisions')
    p.add_argument('--include-equipment', action='store_true',
                   help='stage in-repo equipment adapter only after validating native item/move PBS IDs')
    p.add_argument('--gate-data', help='converted SE-013 reception gate JSON bundle')
    p.add_argument('--gate-tileset-image', help='rights-cleared 256px-wide XP tileset PNG')
    a = p.parse_args()
    print(json.dumps(stage(a.project, a.output, a.archive, a.allow_overwrite,
                           a.gate_data, a.gate_tileset_image, a.include_equipment), indent=2))


if __name__ == '__main__':
    main()
