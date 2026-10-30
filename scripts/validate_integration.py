#!/usr/bin/env python3
"""Validate integration manifest and dependency queue, no external dependencies."""
import json
from pathlib import Path
import re

BASE = Path(__file__).resolve().parent.parent

VERSION = re.compile(r'^\d+(?:\.\d+){1,3}$')
OVERRIDE = re.compile(r'^[A-Za-z_]\w*#[A-Za-z_]\w*$')
COMPARISON = re.compile(r'^(==|>=|<=|>|<)\s*(\d+(?:\.\d+){1,3})$')
PLUGIN_FIELDS = {
    'id', 'name', 'version', 'source', 'dependencies',
    'dependency_version_constraints', 'engine_target', 'source_verification',
    'version_verification', 'license_verification', 'runtime_verified',
    'declared_overrides', 'override_verification', 'status',
}
STATUSES = {
    'needs_upgrade', 'archive_needed', 'conflict_audit_required',
    'integration_scaffold', 'installed',
}


def version_tuple(version):
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError(f'invalid numeric version {version!r}')
    return tuple(int(part) for part in version.split('.'))


def compare_versions(left, right):
    size = max(len(left), len(right))
    left = left + (0,) * (size - len(left))
    right = right + (0,) * (size - len(right))
    return (left > right) - (left < right)


def validate_plugin_manifest(manifest):
    if manifest.get('schema_version') != 1:
        raise ValueError('unsupported plugin manifest schema_version')
    engine = manifest.get('engine')
    if not isinstance(engine, str) or not engine.strip():
        raise ValueError('plugin manifest missing engine')
    plugins = manifest.get('plugins')
    if not isinstance(plugins, list) or not plugins:
        raise ValueError('plugin manifest plugins must be a non-empty list')

    ids = []
    byid = {}
    overrides = {}
    for plugin in plugins:
        if not isinstance(plugin, dict) or not PLUGIN_FIELDS.issubset(plugin):
            raise ValueError('plugin entry missing required fields')
        plugin_id = plugin['id']
        if not isinstance(plugin_id, str) or not plugin_id.strip():
            raise ValueError('plugin id must be a non-empty string')
        ids.append(plugin_id)
        byid[plugin_id] = plugin
        if not isinstance(plugin['name'], str) or not plugin['name'].strip():
            raise ValueError(f'{plugin_id}: name must be a non-empty string')
        version_tuple(plugin['version'])
        if not isinstance(plugin['source'], str) or not plugin['source'].strip():
            raise ValueError(f'{plugin_id}: source must be a non-empty string')
        if plugin['engine_target'] != engine:
            raise ValueError(f"{plugin_id}: engine target {plugin['engine_target']!r} "
                             f"is incompatible with {engine!r}")
        if plugin['status'] not in STATUSES:
            raise ValueError(f'{plugin_id}: invalid plugin status')
        if not isinstance(plugin['runtime_verified'], bool):
            raise ValueError(f'{plugin_id}: runtime_verified must be boolean')
        if plugin['status'] != 'installed' and plugin['runtime_verified']:
            raise ValueError(f'{plugin_id}: uninstalled plugin cannot be runtime-verified')
        if plugin['source_verification'] not in {'verified', 'unverified'}:
            raise ValueError(f'{plugin_id}: invalid source_verification')
        if plugin['version_verification'] not in {'verified', 'unverified'}:
            raise ValueError(f'{plugin_id}: invalid version_verification')
        if plugin['license_verification'] not in {'verified', 'unknown', 'unverified'}:
            raise ValueError(f'{plugin_id}: invalid license_verification')
        if plugin['override_verification'] not in {
                'verified', 'unverified', 'not_applicable'}:
            raise ValueError(f'{plugin_id}: invalid override_verification')
        dependencies = plugin['dependencies']
        if not isinstance(dependencies, list) or any(
                not isinstance(dep, str) for dep in dependencies):
            raise ValueError(f'{plugin_id}: dependencies must be a list of plugin ids')
        if len(dependencies) != len(set(dependencies)):
            raise ValueError(f'{plugin_id}: duplicate dependencies')
        constraints = plugin['dependency_version_constraints']
        if not isinstance(constraints, dict):
            raise ValueError(f'{plugin_id}: dependency_version_constraints must be an object')
        if set(constraints) - set(dependencies):
            raise ValueError(f'{plugin_id}: version constraint for a non-dependency')
        for constraint in constraints.values():
            match = COMPARISON.fullmatch(constraint) if isinstance(constraint, str) else None
            if not match:
                raise ValueError(f'{plugin_id}: invalid dependency version constraint '
                                 f'{constraint!r}')
        declared_overrides = plugin['declared_overrides']
        if not isinstance(declared_overrides, list):
            raise ValueError(f'{plugin_id}: declared_overrides must be a list')
        if len(declared_overrides) != len(set(declared_overrides)):
            raise ValueError(f'{plugin_id}: duplicate declared overrides')
        for method in declared_overrides:
            if not isinstance(method, str) or not OVERRIDE.fullmatch(method):
                raise ValueError(f'{plugin_id}: invalid declared override {method!r}')
            if method in overrides:
                raise ValueError(f'conflicting override {method}: '
                                 f'{overrides[method]} and {plugin_id}')
            overrides[method] = plugin_id

    if len(ids) != len(set(ids)):
        raise ValueError('duplicate plugin ids')
    for plugin in plugins:
        for dep in plugin['dependencies']:
            if dep not in byid:
                raise ValueError(f"{plugin['id']}: missing dependency {dep}")
            constraint = plugin['dependency_version_constraints'].get(dep)
            if constraint:
                match = COMPARISON.fullmatch(constraint)
                operator, required = match.groups()
                actual = version_tuple(byid[dep]['version'])
                required = version_tuple(required)
                comparison = compare_versions(actual, required)
                if not {
                    '==': comparison == 0,
                    '>=': comparison >= 0,
                    '<=': comparison <= 0,
                    '>': comparison > 0,
                    '<': comparison < 0,
                }[operator]:
                    raise ValueError(f"{plugin['id']}: dependency {dep} version "
                                     f"{byid[dep]['version']} violates {constraint}")
    visit_graph(plugins, 'plugin')
    return plugins


def visit_graph(group, group_name, dependencies_key='dependencies'):
    ids = [item['id'] for item in group]
    byid = {item['id']: item for item in group}
    visited = set()
    active = set()

    def visit(key):
        if key in active:
            raise ValueError(f'cycle at {key}')
        if key in visited:
            return
        active.add(key)
        for dep in byid[key][dependencies_key]:
            if dep not in byid:
                raise ValueError(f"{key}: missing dependency {dep}")
            visit(dep)
        active.remove(key)
        visited.add(key)

    for key in ids:
        visit(key)


def validate():
    manifest = json.loads((BASE / 'development/plugin_manifest.json').read_text())
    plugins = validate_plugin_manifest(manifest)
    tasks = json.loads((BASE / 'development/integration_queue.json').read_text())['tasks']
    for group, group_name, dependencies_key in (
            (tasks, 'task', 'depends_on'),):
        ids = [i['id'] for i in group]
        if len(ids) != len(set(ids)):
            raise ValueError(f'duplicate {group_name} ids')
        byid = {i['id']: i for i in group}
        for i in group:
            for dep in i[dependencies_key]:
                if dep not in byid:
                    raise ValueError(f"{i['id']}: missing dependency {dep}")
        visit_graph(group, group_name, dependencies_key)
    for t in tasks:
        if t['status'] not in {'done','queued','blocked','in_progress'}:
            raise ValueError(f"invalid task status {t['id']}")
        if t['status'] == 'done' and not t.get('evidence'):
            raise ValueError(f"done task {t['id']} missing evidence")
    return {'plugins': len(plugins), 'tasks': len(tasks), 'ready':
            [t['id'] for t in tasks if t['status'] in ('queued', 'in_progress') and
             all(next(x for x in tasks if x['id'] == dep)['status'] == 'done'
                 for dep in t['depends_on'])]}


if __name__ == '__main__':
    print(json.dumps(validate(), indent=2))
