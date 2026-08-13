#!/usr/bin/env python3
"""Builds the ordinary-dictation corpus from a directory of real recordings.

Why this exists, next to `extract-real-audio.sh`
------------------------------------------------
The near-miss suite is adversarial by construction: every case puts a decoy on screen that is
almost what was said. That is the right instrument for measuring substitution and the wrong one
for choosing a default backend, which is what it had started to be used for. Ordinary dictation —
someone talking normally, with nothing on screen contradicting them — is the distribution the
default actually serves, and nothing in `eval/` measured it.

What this produces is deliberately *not* a scored suite. There is no ground truth here and
inventing one by machine would make every number circular. See `dnt-eval dictation` for what can
be measured without it: latency against clip length, failure rate, and cross-backend disagreement,
which doubles as a review queue for the handful of clips a human should actually listen to.

Privacy
-------
These clips are extracts of the user's own recordings. `eval/audio/` is gitignored and the clips
stay on the machine that made them; only the manifest, which carries hashes and offsets rather
than audio or transcripts, is safe to share.

Usage:  ./build-dictation-corpus.py [--source ~/Movies] [--count 100] [--out eval/dictation]
"""

import argparse
import hashlib
import json
import random
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# Weighted toward short, because that is what dictation actually is: most utterances are a
# sentence. The long tail is kept because it is the only thing that exercises AudioChunker's
# split-and-stitch path, which is a real product risk and otherwise untested on real speech.
LENGTH_PLAN = [(3, 12), (5, 18), (10, 25), (20, 18), (30, 12), (60, 10), (120, 5)]

MEDIA_SUFFIXES = {".mp4", ".mkv", ".mov", ".m4a", ".mp3", ".wav", ".webm"}

# A clip below this is silence or room tone, not speech. Measured in dBFS by `volumedetect`.
MIN_MEAN_DBFS = -38.0
# Above this fraction of detected silence the clip is mostly gaps, which measures the recogniser's
# endpointing rather than its transcription.
MAX_SILENCE_FRACTION = 0.55


def run(args: list[str]) -> str:
    """ffmpeg writes its measurements to stderr, so both streams are captured."""
    result = subprocess.run(args, capture_output=True, text=True)
    return result.stdout + result.stderr


def probe_duration(path: Path) -> float:
    out = run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
               "-of", "csv=p=0", str(path)]).strip()
    try:
        return float(out.splitlines()[0])
    except (ValueError, IndexError):
        return 0.0


def has_audio(path: Path) -> bool:
    out = run(["ffprobe", "-v", "error", "-select_streams", "a",
               "-show_entries", "stream=codec_name", "-of", "csv=p=0", str(path)])
    return bool(out.strip())


def speech_quality(path: Path, offset: float, seconds: float) -> tuple[float, float]:
    """Returns (mean dBFS, silent fraction) for a candidate span, without writing a file."""
    out = run([
        "ffmpeg", "-nostdin", "-v", "info", "-ss", str(offset), "-t", str(seconds),
        "-i", str(path), "-af", "volumedetect,silencedetect=noise=-35dB:d=0.4",
        "-f", "null", "-",
    ])

    mean = -99.0
    if match := re.search(r"mean_volume:\s*(-?\d+(?:\.\d+)?) dB", out):
        mean = float(match.group(1))

    silent = sum(float(d) for d in re.findall(r"silence_duration:\s*(\d+(?:\.\d+)?)", out))
    return mean, min(silent / seconds, 1.0)


def extract(source: Path, offset: float, seconds: float, target: Path) -> bool:
    # -ac 1 -ar 16000 matches what every platform records, so the corpus measures the audio the
    # apps actually send rather than a higher-fidelity stand-in.
    run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-ss", str(offset), "-t", str(seconds),
         "-i", str(source), "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(target)])
    return target.exists() and target.stat().st_size > 1024


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def collect_sources(root: Path) -> list[tuple[Path, float]]:
    """Media with an audio track, de-duplicated by duration.

    The source directory holds several recordings twice — an `.mkv` screen capture and an `.mp3`
    of the same session, identical in length. Sampling both would silently double-weight that
    speaker and that day's vocabulary.
    """
    candidates = [p for p in sorted(root.iterdir())
                  if p.is_file() and p.suffix.lower() in MEDIA_SUFFIXES]

    with ThreadPoolExecutor(max_workers=8) as pool:
        durations = list(pool.map(probe_duration, candidates))
        audio_flags = list(pool.map(has_audio, candidates))

    seen: dict[int, Path] = {}
    for path, duration, audio in zip(candidates, durations, audio_flags):
        if not audio or duration < 150:
            continue
        # Round to the second: the two copies of one session differ by milliseconds at most.
        key = int(round(duration))
        if key not in seen:
            seen[key] = path
    return sorted(((path, float(key)) for key, path in seen.items()),
                  key=lambda item: item[0].name)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", default=str(Path.home() / "Movies"))
    parser.add_argument("--out", default="eval/dictation")
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--seed", type=int, default=20260812,
                        help="Fixed so the corpus is rebuildable clip for clip.")
    parser.add_argument("--attempts", type=int, default=14,
                        help="Offsets tried per clip before giving up on a source.")
    args = parser.parse_args()

    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        print("ffmpeg and ffprobe are required", file=sys.stderr)
        return 1

    root = Path(args.source).expanduser()
    if not root.is_dir():
        print(f"no such directory: {root}", file=sys.stderr)
        return 1

    out_dir = Path(args.out)
    audio_dir = out_dir / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)

    print(f"scanning {root} …")
    sources = collect_sources(root)
    if not sources:
        print("no usable recordings found", file=sys.stderr)
        return 1
    print(f"{len(sources)} distinct recordings with audio\n")

    # Scale the plan if a smaller corpus was asked for, keeping the shape.
    total_planned = sum(n for _, n in LENGTH_PLAN)
    plan = [(secs, max(1, round(n * args.count / total_planned))) for secs, n in LENGTH_PLAN]

    rng = random.Random(args.seed)
    entries: list[dict] = []
    rejected = 0
    # Round-robin across sources so no single recording dominates, and so one speaker's voice
    # cannot account for a whole length bucket.
    source_cursor = 0

    for seconds, wanted in plan:
        usable = [(p, d) for p, d in sources if d >= seconds + 60]
        if not usable:
            print(f"  {seconds:>4}s  skipped — no recording long enough")
            continue

        made = 0
        while made < wanted:
            source, duration = usable[source_cursor % len(usable)]
            source_cursor += 1

            placed = False
            for _ in range(args.attempts):
                # Avoid the first tenth and last twentieth: intros, outros and trailing silence.
                low, high = duration * 0.10, duration * 0.95 - seconds
                if high <= low:
                    break
                offset = round(rng.uniform(low, high), 2)

                mean, silent = speech_quality(source, offset, seconds)
                if mean < MIN_MEAN_DBFS or silent > MAX_SILENCE_FRACTION:
                    rejected += 1
                    continue

                index = len(entries) + 1
                name = f"d{index:03d}-{seconds:03d}s.wav"
                target = audio_dir / name
                if not extract(source, offset, seconds, target):
                    rejected += 1
                    continue

                entries.append({
                    "id": target.stem,
                    "audio": f"audio/{name}",
                    "seconds": seconds,
                    "source": source.name,
                    "offsetSeconds": offset,
                    "meanDbfs": round(mean, 1),
                    "silentFraction": round(silent, 3),
                    "sha256": sha256(target),
                })
                made += 1
                placed = True
                break

            if not placed:
                # This source has no speech-dense span of this length; drop it for this bucket.
                usable = [item for item in usable if item[0] != source]
                if not usable:
                    print(f"  {seconds:>4}s  only {made}/{wanted} — ran out of sources")
                    break

        print(f"  {seconds:>4}s  {made:>3} clips")

    manifest = {
        "corpus": "ordinary-dictation",
        "purpose": ("Ordinary speech with nothing on screen contradicting it — the distribution "
                    "the default backend actually serves. No ground truth: see dnt-eval "
                    "dictation for what is measurable without it."),
        "builtBy": "eval/build-dictation-corpus.py",
        "seed": args.seed,
        "source": str(root),
        "clips": len(entries),
        "totalSeconds": sum(e["seconds"] for e in entries),
        "byLength": {str(secs): sum(1 for e in entries if e["seconds"] == secs)
                     for secs, _ in LENGTH_PLAN},
        "distinctSources": len({e["source"] for e in entries}),
        "entries": entries,
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    minutes = manifest["totalSeconds"] / 60
    print(f"\n{len(entries)} clips, {minutes:.1f} minutes of speech, "
          f"{manifest['distinctSources']} distinct recordings ({rejected} spans rejected as silence)")
    print(f"manifest: {out_dir / 'manifest.json'}")
    print("\nThe audio stays local — eval/ audio is gitignored. There is no ground truth here;")
    print("run `dnt-eval dictation` for latency, failure rate and cross-backend disagreement.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
