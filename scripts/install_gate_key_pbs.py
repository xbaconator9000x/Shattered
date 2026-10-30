#!/usr/bin/env python3
"""Install the original Shattered gate key item in a staged Essentials PBS project.

Does not compile PBS, distribute assets, or modify an original project.
"""
import argparse
from pathlib import Path
import re

KEY_SECTION = re.compile(r"(?m)^\[SHATTEREDGATEKEY\][ \t]*$")
SECTIONS = re.compile(r"(?m)^\[([^\]\r\n]+)\][ \t]*$")
TEMPLATE = Path(__file__).resolve().parents[1] / "essentials" / "PBS" / "SHATTEREDGATEKEY.pbs"


def install(project: Path, template: Path = TEMPLATE) -> str:
    project = Path(project)
    if not (project / "SHATTERED_STAGING_REPORT.json").is_file():
        raise ValueError("Refusing to modify a project without the Shattered staging marker")
    items = project / "PBS" / "items.txt"
    if not items.is_file():
        raise ValueError("Staged project lacks PBS/items.txt")
    snippet = template.read_text(encoding="utf-8")
    if len(KEY_SECTION.findall(snippet)) != 1 or len(SECTIONS.findall(snippet)) != 1:
        raise ValueError("Gate key template must contain exactly one item section")
    current = items.read_text(encoding="utf-8")
    if len(KEY_SECTION.findall(current)) > 1:
        raise ValueError("Duplicate gate key sections in target PBS")
    if KEY_SECTION.search(current):
        # Don't overwrite another author's conflicting item definition.
        tail = current[KEY_SECTION.search(current).start():]
        existing = SECTIONS.search(tail, 1)
        if existing:
            tail = tail[:existing.start()]
        normalized = lambda s: "\n".join(line.strip() for line in s.splitlines() if line.strip() and not line.lstrip().startswith("#"))
        if normalized(tail) != normalized(snippet):
            raise ValueError("Conflicting existing gate key definition")
        return "unchanged"
    if not current.endswith("\n"):
        current += "\n"
    # Atomic replacement and no temporary file left on ordinary failure.
    tmp = items.with_name(items.name + ".shattered-key.tmp")
    if tmp.exists():
        raise ValueError("Stale gate key staging temporary file")
    try:
        tmp.write_text(current + "\n" + snippet, encoding="utf-8")
        tmp.replace(items)
    finally:
        if tmp.exists():
            tmp.unlink()
    return "installed"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    args = parser.parse_args()
    print(install(args.project))


if __name__ == "__main__":
    main()
