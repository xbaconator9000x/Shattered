#!/usr/bin/env python3
"""Safely stage Shattered Core and optionally approved upstream plugin ZIPs.

Never modifies original. Doesn't compile plugin scripts or test Android runtime.
"""
import argparse
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


def safe_zip_install(archive, dest, plugin_id, overwrite=False):
    staged = []
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
            if path.parts[0] == 'PBS' and path.name == 'pokemon.txt':
                raise ValueError('refusing to replace entire PBS/pokemon.txt')
            if path.parts[0] == 'Data' and path.name == 'Scripts.rxdata':
                raise ValueError('refusing to replace the RPG Maker scripts archive')
            target = dest / path
            if target.exists() and not overwrite:
                raise ValueError(f'overwrite requires review: {path} ({plugin_id})')
            staged.append((member, path))
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


def stage(project, output, archives=(), overwrite=False):
    project = Path(project).resolve()
    output = Path(output).resolve()
    if not (project / 'Game.ini').is_file() or not (project / 'PBS' / 'pokemon.txt').is_file():
        raise ValueError('input must contain Game.ini and PBS/pokemon.txt')
    if project == output or project in output.parents or output in project.parents:
        raise ValueError('input/output must be separate directories, not nested')
    if output.exists():
        raise ValueError('output exists; choose a fresh staging directory')
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
    a = p.parse_args()
    print(json.dumps(stage(a.project, a.output, a.archive, a.allow_overwrite), indent=2))


if __name__ == '__main__':
    main()
