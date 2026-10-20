#!/usr/bin/env python3
"""Materialize and replay source-checked cinematic recipes without dev paths.

Models are supplied locally and verified by hash; this tool never downloads
game content, model weights or uploads anything. Completed movies are reusable.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from protector_native.cinematics import bink_header
from protector_native.content_package import canonical, digest_file
from protector_native.executable_truth import RBNEG9_DOL_SHA256
from tools.personal_build import BuildError, outside_repo, write_json

RECIPES = ROOT / "reference/personal_cinematic_recipes.json"


def same_or_write(path: Path, value):
    if path.exists():
        if json.loads(path.read_text()) != value:
            raise BuildError(f"Existing cinematic input changed: {path.name}")
    else:
        write_json(path, value)


def prepare(game: Path, work: Path, models: Path) -> tuple[dict, list[Path]]:
    game, work, models = map(outside_repo, (game, work, models))
    contract = json.loads(RECIPES.read_text())
    if digest_file(game / "sys/main.dol") != RBNEG9_DOL_SHA256:
        raise BuildError("Unsupported original executable")
    if game == work or work.is_relative_to(game) or work.is_relative_to(models):
        raise BuildError("Cinematic outputs must be separate from game/model inputs")
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    inputs = work / "cinematic-inputs"
    inputs.mkdir(exist_ok=True, mode=0o700)
    owner = {"schema": "protector-native.personal-cinematics/v1", "source_root": str(game)}
    owner_path = inputs / "owner.json"
    if owner_path.exists():
        previous = json.loads(owner_path.read_text())
        if any(previous.get(key) != value for key, value in owner.items()):
            raise BuildError("Cinematic workspace belongs to another source")
    else:
        write_json(owner_path, owner)
    weights = {}
    expected = {value["sha256"]: name for name, value in contract["models"].items()}
    for path in sorted(models.iterdir()):
        if path.is_file() and not path.is_symlink() and path.suffix in (".pth", ".safetensors"):
            identity = digest_file(path)
            if identity in expected:
                weights[expected[identity]] = path.resolve()
    if set(weights) != set(contract["models"]):
        raise BuildError("Model directory does not contain both hash-pinned cinematic models; see the recipe contract for their upstream sources")
    rows = []
    for record in contract["entries"]:
        name = record["recipe"]["movie"]
        if Path(name).name != name or not name.endswith(".bik"):
            raise BuildError("Unsafe cinematic recipe")
        path = game / "files/Movies" / name
        if path.is_symlink() or digest_file(path) != record["source_sha256"]:
            raise BuildError(f"Original movie changed: {name}")
        with path.open("rb") as stream:
            header = bink_header(stream.read(44), path.stat().st_size)
        expected_header = {"width": record["source_width"], "height": record["source_height"],
            "frame_count": record["frame_count"], "frame_rate_numerator": record["rate_numerator"],
            "frame_rate_denominator": record["rate_denominator"]}
        if any(header[key] != value for key, value in expected_header.items()):
            raise BuildError(f"Original movie timing changed: {name}")
        rows.append({"path": f"files/Movies/{name}", "bytes": path.stat().st_size,
            "sha256": record["source_sha256"], **header})
    inventory = inputs / "inventory.json"
    same_or_write(inventory, {"schema": "protector-native.cinematic-source-inventory/v1",
        "title_dol_sha256": RBNEG9_DOL_SHA256, "source_root": str(game), "movies": rows,
        "scope": "exact supported movie hashes and Bink headers; full decode is verified after restoration"})
    local = []
    for record in contract["entries"]:
        config = copy.deepcopy(record["recipe"])
        model = config["model"]
        config["model"] = {**contract["models"][model], "weights": str(weights[model])}
        config.update(inventory=str(inventory), inventory_sha256=digest_file(inventory))
        # Changing one recipe does not invalidate other completed movies. Keep
        # prior materialized inputs as evidence instead of overwriting them.
        identity = hashlib.sha256(canonical(config)).hexdigest()[:16]
        path = inputs / (Path(config["movie"]).stem + "-" + identity + ".json")
        same_or_write(path, config)
        local.append(path)
    return contract, local


def run_selected(recipes: list[Path], work: Path, selected: list[str] | None, device: str):
    # Keep model/inference dependencies out of prepare-only and the small builder.
    from tools.personal_build import cinematic_doctor
    cinematic_doctor()
    from tools.restore_cinematic import run, verify_master
    if selected:
        wanted = set(selected)
        recipes = [p for p in recipes if json.loads(p.read_text())["movie"] in wanted]
        if {json.loads(p.read_text())["movie"] for p in recipes} != wanted:
            raise BuildError("An unknown movie was selected")
    outputs = []
    for recipe in recipes:
        config = json.loads(recipe.read_text())
        destination = work / "cinematic-masters" / Path(config["movie"]).stem
        if destination.exists():
            receipt = json.loads((destination / "receipt.json").read_text())
            if receipt.get("status") != "complete-candidate" or receipt.get("recipe_sha256") != digest_file(recipe):
                raise BuildError(f"Incomplete/changed movie {recipe.stem}; inspect its receipt before restarting that item")
            master = destination / receipt["master"]
            if digest_file(master) != receipt["master_sha256"]:
                raise BuildError("A completed cinematic master changed")
            verify_master(master, receipt["source"], config["output_dimensions"])
            print(f"Reused verified movie: {recipe.stem}", flush=True)
        else:
            if shutil.disk_usage(work).free < 2 * 1024**3:
                raise BuildError("Less than 2 GiB workspace headroom remains")
            receipt = run(recipe, destination, device)
        outputs.append({"movie": config["movie"], "manifest": str(destination / "cinematics.json"),
            "sha256": digest_file(destination / "cinematics.json"), "seconds": receipt.get("seconds"),
            "frames": receipt["frames_done"], "bytes": receipt["master_bytes"]})
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--run", action="store_true", help="run expensive restoration; default only prepares verified local recipes")
    parser.add_argument("--movie", action="append")
    parser.add_argument("--device", choices=("mps", "cpu"), default="mps")
    args = parser.parse_args()
    try:
        contract, recipes = prepare(args.game, args.work_dir, args.model_dir)
        result = {"prepared_movies": len(recipes), "media_generated": False}
        if args.run:
            result.update(media_generated=True, completed=run_selected(recipes, args.work_dir.resolve(), args.movie, args.device))
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, ImportError) as error:
        parser.exit(2, f"Cinematic builder: {error}\n")


if __name__ == "__main__":
    main()
