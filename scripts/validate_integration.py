#!/usr/bin/env python3
"""Validate integration manifest and dependency queue, no external dependencies."""
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent


def validate():
    plugins = json.loads((BASE / 'development/plugin_manifest.json').read_text())['plugins']
    tasks = json.loads((BASE / 'development/integration_queue.json').read_text())['tasks']
    for group, group_name in ((plugins, 'plugin'), (tasks, 'task')):
        ids = [i['id'] for i in group]
        if len(ids) != len(set(ids)):
            raise ValueError(f'duplicate {group_name} ids')
        byid = {i['id']: i for i in group}
        for i in group:
            for dep in i['dependencies' if group_name == 'plugin' else 'depends_on']:
                if dep not in byid:
                    raise ValueError(f"{i['id']}: missing dependency {dep}")
        visited = set()
        active = set()
        def visit(key):
            if key in active:
                raise ValueError(f'cycle at {key}')
            if key in visited:
                return
            active.add(key)
            for dep in byid[key]['dependencies' if group_name == 'plugin' else 'depends_on']:
                visit(dep)
            active.remove(key)
            visited.add(key)
        for key in ids:
            visit(key)
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
