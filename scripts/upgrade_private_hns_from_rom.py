#!/usr/bin/env python3
"""Rebuild a private H&S candidate and install authenticated ROM guard art."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from extract_shattered_field_sprites import export
from extract_shattered_viridian_dialogue import extract as extract_dialogue
from extract_shattered_training import extract as extract_training
from extract_shattered_night_raid import extract as extract_night
from extract_shattered_forest_confrontation import extract as extract_forest

ROOT = Path(__file__).resolve().parents[1]


def upgrade(candidate, rom, output, ruby="ruby"):
    output = Path(output).absolute()
    candidate = Path(candidate).resolve()
    if output.exists() or output.is_symlink() or output == candidate or candidate in output.parents:
        raise ValueError("use a fresh output outside the original candidate")
    with tempfile.TemporaryDirectory(prefix="shattered-rom-guard-") as temporary:
        extracted = Path(temporary) / "guard"
        export(rom, extracted)  # Validate source ROM before copying the project.
        dialogue = Path(temporary) / 'viridian_dialogue.json'
        extract_dialogue(rom, dialogue)
        training = Path(temporary) / 'training.json'
        extract_training(rom, training)
        night = Path(temporary) / 'night.json'
        extract_night(rom, night)
        forest = Path(temporary) / 'forest.json'
        extract_forest(rom, forest)
        def run(script, *args):
            result = subprocess.run([ruby, str(ROOT / "scripts" / script), *map(str, args)],
                                    check=True, capture_output=True, text=True, timeout=180)
            return json.loads(result.stdout)
        try:
            runtime = run("upgrade_private_hns_candidate.rb", "--candidate", candidate,
                          "--output", output, "--source", ROOT)
            guard = run("install_private_rom_guard.rb", output, extracted)
            chapter = run('install_private_viridian_chapter.rb', output, dialogue, training, night, forest)
            syntax = run("audit_native_script_syntax.rb", "--project", output)
            if not syntax["syntax_pass"]:
                raise ValueError("rebuilt native script archive failed syntax preflight")
            report = {"kind": "private_rom_guard_candidate_upgrade",
                      "runtime_upgrade": runtime, "rom_guard": guard, "viridian_chapter": chapter,
                      "syntax_audit": syntax, "native_gameplay_verified": False}
            (output / "SHATTERED_ROM_CANDIDATE_REPORT.json").write_text(
                json.dumps(report, indent=2) + "\n")
            return report
        except BaseException:
            if output.is_dir() and not output.is_symlink():
                shutil.rmtree(output)
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--rom", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ruby", default="ruby")
    args = parser.parse_args()
    print(json.dumps(upgrade(args.candidate, args.rom, args.output, args.ruby), indent=2))

