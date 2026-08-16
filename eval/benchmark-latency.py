#!/usr/bin/env python3
"""Latency of the audio models, against clip length.

Separate from benchmark-models.sh because that script answers "is this transcript correct" and
throws the clock away. This one throws the transcript away and keeps the clock — but reports a
distribution rather than a mean, because the same clip and model have measured 6 s in one session
and 36 s in another. That spread is server-side load, not a property of the model (see the
2026-08-14 corrections in docs/EVALUATION.md), which is exactly why a bare mean is not reportable:
min and max say how much of the number is the model and how much was the afternoon.

Two clip lengths, because they cost differently. A dictation phrase is ~3 s of audio and the wait
is dominated by time-to-first-token; a 20 s recording adds audio tokens to the prompt and words to
the output, so the two do not scale together and a single number cannot stand for both.

Latency is `transcriptionSeconds` out of `dnt transcribe --json`: measured in-process around the
request only, so decode and process startup are excluded. One process per cell, transcribing the
clip TRIALS+1 times; the first is discarded as a warm-up so a TLS handshake is not charged to one
model's first trial and to no other trial anywhere.

Cells run concurrently — otherwise the sweep is dominated by whichever model is slowest that day
and nobody re-runs it. Trials *within* a cell stay sequential, because that is the number being
reported: a cell measures one request at a time against a model. What concurrency costs is that
each model has its two clips in flight at once, so a number here is "latency while the account has
`--workers` requests open", not "latency of an idle account". Pass `--workers 1` for the strictly
serial condition; the printed header records which was used, because it is a measurement
condition and not a scheduling detail.

No screen context is sent. Grounding adds a few hundred prompt tokens to every request, which
would be a constant across the models measured here and would hide the thing being measured.

Usage:  eval/benchmark-latency.py [--trials 10] [--models a,b] [--json out.json]
Results are committed to docs/MODELS.md.
"""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / ".build/release/dnt"

# The Gemini Flash family as shipped: 3.6 is the default, 3.7 its successor, 3.5 and the 3
# preview its predecessors. Same provider for all four so the transport is not a variable.
DEFAULT_MODELS = [
    "gemini-3.6-flash",
    "gemini-3.7-flash",
    "gemini-3.5-flash",
    "gemini-3-flash-preview",
]

# `gemini-version.wav` is synthesized and `real-talk-gemini15.wav` is a real recorded talk. That
# difference matters for accuracy and not for latency: what is billed is seconds of audio.
CLIPS = [
    ("short", ROOT / "eval/audio/gemini-version.wav"),
    ("long", ROOT / "eval/audio/real-talk-gemini15.wav"),
]


def cheapest_thinking_level(model: str) -> str:
    """Mirror of GeminiProvider.cheapestThinkingLevel — reported, not sent.

    The provider picks this per model family because 3.7 rejects `minimal` outright. It is the
    single largest lever on these numbers, so a table that omits it is unreadable.
    """
    return "low" if model.startswith(("gemini-3.7", "gemini-4")) else "minimal"


def run_cell(model: str, clip: Path, trials: int) -> dict:
    """One model, one clip. Returns the kept trials plus whatever failed."""
    # trials + 1 invocations, sequentially in one process; entry 0 is the warm-up.
    result = subprocess.run(
        [
            str(BINARY), "transcribe", *([str(clip)] * (trials + 1)),
            "--provider", "google", "--model", model, "--json", "--quiet",
        ],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    try:
        outcomes = json.loads(result.stdout)
    except json.JSONDecodeError:
        # Uncut: a script driving a paid API has to be able to say exactly why it produced nothing.
        return {"error": (result.stderr or result.stdout).strip(), "seconds": []}

    kept = outcomes[1:]
    return {
        "warmupSeconds": outcomes[0]["transcriptionSeconds"] if outcomes else None,
        "seconds": [o["transcriptionSeconds"] for o in kept],
        "audioTokens": kept[0].get("audioTokens") if kept else None,
        "outputChars": (
            round(statistics.mean(len(o["text"]) for o in kept)) if kept else None
        ),
        "sample": kept[0]["text"][:120] if kept else "",
        # A cell that asked for 10 and got 7 is not a 7-trial cell; the gap is the finding.
        "failed": (trials + 1) - len(outcomes),
        "stderr": result.stderr.strip() if len(outcomes) < trials + 1 else "",
    }


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))
    return ordered[index]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trials", type=int, default=10, help="Kept trials per model per clip.")
    parser.add_argument("--models", default=",".join(DEFAULT_MODELS))
    parser.add_argument("--json", dest="json_out", help="Write the raw per-trial seconds here.")
    parser.add_argument(
        "--workers", type=int, default=0,
        help="Cells in flight at once. 0 runs every cell concurrently; 1 is strictly serial.")
    args = parser.parse_args()

    # Below ~3 the median is the middle of three numbers and the spread columns say nothing.
    if args.trials < 3:
        print("--trials must be at least 3 to report a distribution", file=sys.stderr)
        return 1

    models = [m.strip() for m in args.models.split(",") if m.strip()]
    if not BINARY.exists():
        print(f"missing {BINARY} — run: swift build -c release", file=sys.stderr)
        return 1
    for _, clip in CLIPS:
        if not clip.exists():
            print(f"missing {clip}", file=sys.stderr)
            return 1

    cells = [(model, label, clip) for model in models for label, clip in CLIPS]
    workers = args.workers or len(cells)

    print(f"provider google · {args.trials} kept trials per cell (+1 discarded warm-up) · "
          f"{workers} cells in flight")
    for label, clip in CLIPS:
        print(f"{label:<6} {clip.name} · {seconds_of(clip):.1f} s of audio")
    print()

    # Submitted in table order, so with --workers 1 the run is exactly the serial condition.
    with ThreadPoolExecutor(max_workers=workers) as pool:
        finished = list(
            pool.map(lambda cell: run_cell(cell[0], cell[2], args.trials), cells))

    records: dict[str, dict] = {}
    header = f"{'model':<24} {'think':<8} {'clip':<6} {'n':>3} {'min':>7} {'med':>7} {'mean':>7} {'p90':>7} {'max':>7}  note"
    print(header)
    print("─" * len(header))

    for (model, label, _), cell in zip(cells, finished):
        records[f"{model}/{label}"] = cell
        seconds = cell["seconds"]
        level = cheapest_thinking_level(model)
        if not seconds:
            note = cell.get("error") or cell.get("stderr") or "no successful trials"
            print(f"{model:<24} {level:<8} {label:<6} {0:>3} {'—':>7} {'—':>7} {'—':>7} {'—':>7} {'—':>7}  {note}")
            continue

        note = f"{cell['audioTokens']} audio tok · {cell['outputChars']} chars out"
        if cell["failed"]:
            note = f"{cell['failed']} failed · " + note
        print(
            f"{model:<24} {level:<8} {label:<6} {len(seconds):>3} "
            f"{min(seconds):>6.2f}s {statistics.median(seconds):>6.2f}s "
            f"{statistics.mean(seconds):>6.2f}s {percentile(seconds, 0.9):>6.2f}s "
            f"{max(seconds):>6.2f}s  {note}"
        )

    print("\nRead min/max before the median. When they are far apart the cell is measuring the "
          "API's\nload that afternoon as much as the model, and only same-session comparisons "
          "between models\nsurvive that.")

    if args.json_out:
        # `workers` travels with the numbers: a cell measured with eight requests open is not
        # comparable to one measured alone, and the table alone would not say which it was.
        payload = {"provider": "google", "trials": args.trials, "workers": workers,
                   "cells": records}
        Path(args.json_out).write_text(json.dumps(payload, indent=2) + "\n")
        print(f"\nraw per-trial seconds → {args.json_out}")
    return 0


def seconds_of(clip: Path) -> float:
    """Duration from the WAV header, so ffprobe is not a dependency of the benchmark."""
    import wave

    with wave.open(str(clip)) as handle:
        return handle.getnframes() / handle.getframerate()


if __name__ == "__main__":
    sys.exit(main())
