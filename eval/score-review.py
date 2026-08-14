#!/usr/bin/env python3
"""Scores each backend against transcripts a human verified by ear.

This is the other half of `make-review-sheet.py`, and together they are the only route this
project has to an *accuracy* number on ordinary dictation. Everything `dnt-eval dictation` reports
— latency, failure rate, cross-backend agreement — is measurable without ground truth, and none of
it says whether a transcript is right. Agreement in particular is not correctness: two backends
can agree on the same mistake.

The metric is word error rate over the same tokenisation the rest of the project uses: Latin words
and CJK per character. Reported per backend and per language, because the two behave nothing alike
here — Deepgram manages 0.12 of the character density on Chinese that it manages on English.

Deliberately makes no attempt to score clips nobody verified. A partial corpus honestly labelled
is worth more than a full one where most of the ground truth was guessed.

Usage:  ./score-review.py [--verified ~/Downloads/verified.json] [--corpus eval/dictation]
"""

import argparse
import collections
import json
import sys
from pathlib import Path


def tokens(text: str) -> list[str]:
    """Latin words, CJK per character — the split the rest of the eval uses."""
    out: list[str] = []
    current = ""
    for character in text.lower():
        codepoint = ord(character)
        if 0x4E00 <= codepoint <= 0x9FFF or 0x3040 <= codepoint <= 0x30FF:
            if current:
                out.append(current)
                current = ""
            out.append(character)
        elif character.isalnum():
            current += character
        else:
            if current:
                out.append(current)
                current = ""
    if current:
        out.append(current)
    return out


def error_rate(reference: list[str], hypothesis: list[str]) -> float:
    """Levenshtein over tokens, divided by reference length. The standard WER."""
    if not reference:
        return 0.0 if not hypothesis else 1.0

    previous = list(range(len(hypothesis) + 1))
    for i, want in enumerate(reference, start=1):
        current = [i]
        for j, got in enumerate(hypothesis, start=1):
            current.append(min(
                previous[j] + 1,                                   # deletion
                current[j - 1] + 1,                                # insertion
                previous[j - 1] + (0 if want == got else 1),       # substitution
            ))
        previous = current
    return previous[-1] / len(reference)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--verified", default="eval/dictation/verified.json",
                        help="Exported by review.html.")
    parser.add_argument("--corpus", default="eval/dictation")
    args = parser.parse_args()

    root = Path(args.corpus)
    verified_path = Path(args.verified)
    try:
        verified = {row["clip"]: row["verified"]
                    for row in json.loads(verified_path.read_text())["verified"]}
        results = json.loads((root / "results.json").read_text())["results"]
    except FileNotFoundError as error:
        print(f"{error}\n\nVerify some clips first:\n"
              f"  ./eval/make-review-sheet.py && open {root}/review.html\n"
              f"then save the exported verified.json to {verified_path}", file=sys.stderr)
        return 1

    if not verified:
        print("verified.json has no entries yet", file=sys.stderr)
        return 1

    language = {row["clip"]: row.get("language", "")
                for row in results if row["provider"] == "xai"}

    scores: dict[tuple[str, str], list[float]] = collections.defaultdict(list)
    errored: collections.Counter[str] = collections.Counter()
    for row in results:
        truth = verified.get(row["clip"])
        if truth is None:
            continue
        family = "zh" if language.get(row["clip"]) in ("zh", "cmn") else "en"
        if row.get("error"):
            # A backend that returned nothing got every word wrong; excluding it would flatter it.
            scores[(row["provider"], family)].append(1.0)
            errored[row["provider"]] += 1
            continue
        scores[(row["provider"], family)].append(
            error_rate(tokens(truth), tokens(row.get("text", ""))))

    providers = sorted({p for p, _ in scores})
    print(f"word error rate against {len(verified)} human-verified clips")
    print("lower is better; 1.00 means nothing usable came back\n")
    print(f"{'backend':<12}{'english':>10}{'chinese':>10}{'overall':>10}{'failed':>9}")
    for provider in providers:
        english = scores.get((provider, "en"), [])
        chinese = scores.get((provider, "zh"), [])
        combined = english + chinese

        def show(values: list[float]) -> str:
            return f"{sum(values) / len(values):.2f}" if values else "—"

        print(f"{provider:<12}{show(english):>10}{show(chinese):>10}{show(combined):>10}"
              f"{errored[provider]:>9}")

    # Per backend, across both language buckets — the first bucket alone undercounts.
    counted = max(
        (len(scores.get((p, "en"), [])) + len(scores.get((p, "zh"), [])) for p in providers),
        default=0)
    print(f"\n{counted} clips scored per backend. Verify more in review.html to tighten this;")
    print("clips left blank there are simply not counted.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
