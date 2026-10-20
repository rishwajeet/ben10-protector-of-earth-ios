#!/usr/bin/env python3
"""Create/verify a private content pack; never uploads or modifies input assets."""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from protector_native.content_package import ROOTS, ContentError, write_package, verify_package


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create")
    for root in ROOTS:
        create.add_argument("--" + root.lower(), type=Path, required=True)
    create.add_argument("--output", type=Path, required=True)
    verify = sub.add_parser("verify")
    verify.add_argument("package", type=Path)
    args = parser.parse_args()
    try:
        result = (verify_package(args.package) if args.command == "verify" else
                  write_package({key: getattr(args, key.lower()) for key in ROOTS}, args.output))
    except (ContentError, OSError) as exc:
        parser.exit(2, f"Content package: {exc}\n")
    print(json.dumps({key: value for key, value in result.items() if key != "files"}, indent=2))


if __name__ == "__main__":
    main()
