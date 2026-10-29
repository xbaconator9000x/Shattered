#!/usr/bin/env python3
"""Idempotently create GitHub issues for the next dependency-ready tasks.

GitHub Actions cron runs this automatically, but this does not write code.
"""
import json
import os
from pathlib import Path
from urllib import request, parse

ROOT = Path(__file__).resolve().parent.parent
QUEUE = ROOT / 'development/integration_queue.json'
PREFIX = '[SHATTERED QUEUE]'


def ready_tasks(queue, max_jobs=3):
    tasks = queue['tasks']
    byid = {t['id']: t for t in tasks}
    return [t for t in tasks if t['status'] in ('queued', 'in_progress') and
            all(byid[d]['status'] == 'done' for d in t['depends_on'])][:max_jobs]


def api(path, method='GET', payload=None):
    repo = os.environ['GITHUB_REPOSITORY']
    token = os.environ['GITHUB_TOKEN']
    body = json.dumps(payload).encode() if payload is not None else None
    url = f'https://api.github.com/repos/{repo}/{path}'
    req = request.Request(url, method=method, data=body,
                          headers={'Authorization': f'Bearer {token}',
                                   'Accept': 'application/vnd.github+json',
                                   'X-GitHub-Api-Version': '2022-11-28',
                                   'Content-Type': 'application/json'})
    with request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def main():
    q = json.loads(QUEUE.read_text())
    ready = ready_tasks(q)
    if not ready:
        print('No ready tasks'); return
    # Read all pages, including closed issues, to avoid duplicates and spam.
    titles = set()
    page = 1
    while True:
        batch = api(f'issues?state=all&per_page=100&page={page}')
        for issue in batch:
            if 'pull_request' not in issue:
                titles.add(issue['title'])
        if len(batch) < 100:
            break
        page += 1
    for task in ready:
        title = f"{PREFIX} {task['id']}: {task['title']}"
        if title in titles:
            print('Existing:', title); continue
        text = (f"Source of truth: `development/integration_queue.json`\n\n"
                f"Task: **{task['id']}**\nDependencies: {', '.join(task['depends_on']) or 'None'}\n\n"
                + '\n'.join(f'- [ ] {item}' for item in task.get('validation', []))
                + '\n\nOnly mark done after meaningful code plus validation evidence. ' 
                  'Do not treat this issue as an autonomous coding agent.')
        issue = api('issues', 'POST', {'title': title, 'body': text})
        print('Created:', issue['html_url'])


if __name__ == '__main__':
    main()
