#!/usr/bin/env python3
"""Turn restored per-movie cinematic masters into the importable delivery pack.

Run after `personal_cinematics.py --run`. Every completed master under
`<work-dir>/cinematic-masters` is composed into one manifest (hard links where
possible) and then encoded to HEVC delivery files. Both steps are resumable and
write only below a new external output directory.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))
from protector_native.content_package import digest_file
from tools.compose_cinematic_packs import compose
from tools.encode_cinematic_delivery import encode

RECIPES = ROOT / "reference/personal_cinematic_recipes.json"


def expected_movies() -> list[str]:
    contract = json.loads(RECIPES.read_text())
    movies = [entry["recipe"]["movie"] for entry in contract["entries"]]
    if len(movies) != 76 or len(set(movies)) != 76:
        raise ValueError("The cinematic recipe contract must list 76 distinct movies")
    return movies


def completed_masters(work: Path, movies: list[str]) -> list[dict]:
    packs = []
    for movie in movies:
        folder = work / "cinematic-masters" / Path(movie).stem
        receipt_path, manifest = folder / "receipt.json", folder / "cinematics.json"
        if not receipt_path.is_file() or not manifest.is_file():
            raise ValueError(f"{movie} has not been restored; run personal_cinematics.py --run first")
        receipt = json.loads(receipt_path.read_text())
        if receipt.get("status") != "complete-candidate":
            raise ValueError(f"{movie} restoration is incomplete; rerun personal_cinematics.py --run")
        if [entry.get("movie") for entry in json.loads(manifest.read_text()).get("entries", [])] != [movie]:
            raise ValueError(f"{movie} master manifest does not describe exactly that movie")
        packs.append({"path": str(manifest.resolve(strict=True)), "sha256": digest_file(manifest)})
    return packs


def build(work: Path, output: Path, mbps: int, movies: list[str] | None) -> dict:
    work = work.resolve(strict=True)
    output = output.resolve()
    if output.is_relative_to(ROOT) or output.is_relative_to(work):
        raise ValueError("Use a new output directory outside the source tree and the cinematic work directory")
    selected = movies or expected_movies()
    unknown = set(selected) - set(expected_movies())
    if unknown:
        raise ValueError("Unknown movie: " + ", ".join(sorted(unknown)))
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    recipe = output / "composition.json"
    config = {"schema": "protector-native.cinematic-composition/v1",
              "pack_id": "personal-cinematic-masters", "packs": completed_masters(work, selected)}
    masters = output / "masters"
    if masters.exists():
        if not recipe.is_file() or json.loads(recipe.read_text()) != config:
            raise ValueError("Existing composed masters belong to different restorations; use a new output")
    else:
        recipe.write_text(json.dumps(config, indent=2) + "\n")
        compose(recipe, masters)
    result = encode(masters / "cinematics.json", output / "RestoredCinematics", mbps, None)
    result["complete_library"] = movies is None
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True, help="the personal_cinematics.py work directory")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mbps", type=int, default=12)
    parser.add_argument("--movie", action="append", help="check only these movies; the result cannot be packaged")
    args = parser.parse_args()
    try:
        print(json.dumps(build(args.work_dir, args.output, args.mbps, args.movie), indent=2))
    except (OSError, ValueError, KeyError) as error:
        parser.exit(2, f"Cinematic delivery: {error}\n")


if __name__ == "__main__":
    main()
