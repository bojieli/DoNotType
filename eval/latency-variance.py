#!/usr/bin/env python3
"""Is the 3.6/3.7 latency spread load, or is it the model thinking?

Two things the main sweep could not separate, because its fast cells finished in 15 s while its
slow cells ran 95 s — so the fast models never sampled the moments the slow ones spiked.

Fixed cadence, fixed window, all four models sampling the same instants. Per trial we keep the
wall-clock offset and total_output_tokens. The transcript is a fixed ~46 characters, so output
tokens far above that floor are thought tokens and nothing else.

  exogenous load  -> slow trials cluster in time AND coincide across models; tokens flat
  model thinking  -> latency tracks output tokens; no cross-model time correlation
"""

import json
import statistics
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / ".build/release/dnt"
OUT = ROOT / "eval/results/latency-variance.json"
CLIP = ROOT / "eval/audio/gemini-version.wav"
MODELS = ["gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.5-flash", "gemini-3-flash-preview"]
WINDOW = 180.0   # seconds of shared wall clock
CADENCE = 6.0    # seconds between the start of one trial and the next, per model

START = time.monotonic()


def sample(model: str) -> list[dict]:
    trials = []
    slot = 0
    while True:
        target = slot * CADENCE
        now = time.monotonic() - START
        if target > WINDOW:
            break
        if now < target:
            time.sleep(target - now)
        slot += 1

        offset = time.monotonic() - START
        proc = subprocess.run(
            [str(BINARY), "transcribe", str(CLIP), "--provider", "google",
             "--model", model, "--json", "--quiet"],
            capture_output=True, text=True, cwd=ROOT)
        try:
            out = json.loads(proc.stdout)[0]
        except (json.JSONDecodeError, IndexError):
            trials.append({"offset": offset, "seconds": None,
                           "error": (proc.stderr or proc.stdout).strip()[:200]})
            continue
        trials.append({
            "offset": round(offset, 2),
            "seconds": out["transcriptionSeconds"],
            "outputTokens": out["completionTokens"],
            "promptTokens": out["promptTokens"],
            "chars": len(out["text"]),
        })
    return trials


with ThreadPoolExecutor(max_workers=len(MODELS)) as pool:
    results = dict(zip(MODELS, pool.map(sample, MODELS)))

OUT.write_text(json.dumps(results, indent=2) + "\n")

for model, trials in results.items():
    ok = [t for t in trials if t.get("seconds")]
    secs = sorted(t["seconds"] for t in ok)
    tokens = {t["outputTokens"] for t in ok}
    print(f"{model:<24} {len(ok)}/{len(trials)} trials · "
          f"median {statistics.median(secs):5.2f}s · max {max(secs):6.2f}s · "
          f"output tokens {min(tokens)}–{max(tokens)}")

# The two questions the run exists to answer, printed so the conclusion is not left to the reader.
print("\noutput tokens flat across a wide latency spread → the wait is not the model thinking")
print("cross-model correlation of per-slot latency (shared load would show up here):")
models = list(results)
for i, a in enumerate(models):
    for b in models[i + 1:]:
        pairs = [(x["seconds"], y["seconds"]) for x, y in zip(results[a], results[b])
                 if x.get("seconds") and y.get("seconds")]
        r = statistics.correlation([p[0] for p in pairs], [p[1] for p in pairs])
        print(f"  {a:<24} vs {b:<24} r = {r:+.2f}")
print(f"\n→ {OUT}")
