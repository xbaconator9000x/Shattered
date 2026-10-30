#!/usr/bin/env python3
"""Fail-closed first-playable acceptance receipt verifier.

A successful synthetic CI run is never evidence of native compilation or gameplay.
Receipts are private local evidence and must not include licensed assets.
"""
import argparse
import json
from pathlib import Path

GATES = (
    "rights_cleared_base",
    "pinned_plugin_archives",
    "native_essentials_compile",
    "new_game_hns_gate",
    "human_battle",
    "johto_collapse",
    "aipom_key",
    "route22_rattata",
    "save_reload",
    "android_playthrough",
)


def validate(receipt):
    failures = []
    if not isinstance(receipt, dict):
        return ["receipt must be a JSON object"]
    if receipt.get("project") != "Shattered Essentials v21.1":
        failures.append("project must identify the canonical Essentials v21.1 remake")
    if not isinstance(receipt.get("main_sha"), str) or len(receipt["main_sha"]) != 40 or any(c not in "0123456789abcdef" for c in receipt["main_sha"]):
        failures.append("main_sha must be a full lowercase commit SHA")
    gates = receipt.get("gates")
    if not isinstance(gates, dict):
        return failures + ["gates must be an object"]
    for name in GATES:
        evidence = gates.get(name)
        if not isinstance(evidence, dict) or evidence.get("status") != "verified":
            failures.append(f"{name}: not runtime verified")
            continue
        if not isinstance(evidence.get("evidence"), str) or not evidence["evidence"].strip():
            failures.append(f"{name}: missing evidence reference")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    args = parser.parse_args()
    problems = validate(json.loads(args.receipt.read_text(encoding="utf-8")))
    for problem in problems:
        print("BLOCKED:", problem)
    if not problems:
        print("PASS: all first-playable acceptance gates have evidence")
    return bool(problems)


if __name__ == "__main__":
    raise SystemExit(main())
