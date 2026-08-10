#!/usr/bin/env python3
"""Download and verify a real Hugging Face model checkpoint.

This is deliberately separate from the OpenAI-compatible benchmark client: serving tools may
download weights implicitly, which makes it too easy to accidentally benchmark a placeholder
model.  The command resolves a revision, verifies that the snapshot contains a config and model
weights, and prints the exact local path to use with a runtime.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from huggingface_hub import snapshot_download


DEFAULT_MODEL = "mistralai/Voxtral-Small-24B-2507"


def verify_snapshot(path: Path) -> dict:
    config_path = path / "config.json"
    if not config_path.is_file():
        raise RuntimeError(f"checkpoint is missing config.json: {path}")
    config = json.loads(config_path.read_text())
    all_weights = sorted(
        p
        for pattern in ("*.safetensors", "*.bin", "*.gguf")
        for p in path.glob(pattern)
        if p.is_file()
    )
    if not all_weights:
        raise RuntimeError(f"checkpoint has no model weight files: {path}")
    weights = all_weights
    for index_name in ("model.safetensors.index.json", "pytorch_model.bin.index.json"):
        index_path = path / index_name
        if not index_path.is_file():
            continue
        index = json.loads(index_path.read_text())
        required = {path / name for name in index.get("weight_map", {}).values()}
        missing = sorted(str(weight) for weight in required if not weight.is_file())
        if missing:
            raise RuntimeError(
                f"checkpoint is incomplete; {len(missing)} indexed weight file(s) are missing: "
                + ", ".join(missing)
            )
        # Some repositories also ship a consolidated copy. Count the indexed shards once rather
        # than double-counting that alternate representation in the manifest.
        weights = sorted(required)
        break
    return {
        "path": str(path),
        "revision": path.name,
        "model_type": config.get("model_type"),
        "weight_files": len(weights),
        "weight_bytes": sum(p.stat().st_size for p in weights),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", nargs="?", default=DEFAULT_MODEL)
    parser.add_argument("--revision", help="branch, tag, or commit; defaults to the Hub revision")
    parser.add_argument("--cache-dir", type=Path, help="optional Hugging Face cache directory")
    parser.add_argument(
        "--local-files-only",
        action="store_true",
        help="verify an existing snapshot without contacting Hugging Face",
    )
    args = parser.parse_args()
    snapshot = snapshot_download(
        args.model,
        revision=args.revision,
        cache_dir=str(args.cache_dir) if args.cache_dir else None,
        local_files_only=args.local_files_only,
    )
    print(json.dumps(verify_snapshot(Path(snapshot)), sort_keys=True))


if __name__ == "__main__":
    main()
