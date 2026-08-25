#!/usr/bin/env python3
"""Measure where a live segmentation policy would cut real dictations, and what it would cost.

Two questions, both answered without a single network call:

  1. Should boundaries come from frame energy (what `AudioChunker.bestBoundary` does today) or
     from Silero VAD (already shipped, currently used only as a speech/no-speech gate)?
  2. What does each transcription policy send — `incremental` sends each segment once, `whole`
     re-transcribes everything at every boundary.

Ports the two detectors and the boundary scorer from `Sources/DoNotTypeCore/AudioChunker.swift`
and `SpeechActivity.swift`. When either of those changes, this must change with it or it is
measuring a policy the app no longer has.

Reads the retained history audio and the checked-in Silero model. See docs/INCREMENTAL.md.
"""
import argparse
import glob
import os
import sys
import time
import wave

import numpy as np

SR = 16_000

# --- SpeechActivity.swift ---
WIN = 512                       # windowSamples
CTX = 64
THRESH = 0.5                    # threshold
NEG = 0.35                      # negativeThreshold
MIN_SPEECH = SR * 250 // 1000   # minimumSpeechMilliseconds
MIN_SIL = SR * 100 // 1000      # minimumSilenceMilliseconds

# --- AudioChunker.swift ---
FRAME_MS = 20
FRAME = SR * FRAME_MS // 1000
EVIDENCE_FRAMES = 5             # 100 ms of speech each side defeats isolated transients
EVIDENCE_WINDOW = 100           # two seconds

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL = os.path.join(REPO, "Sources", "DoNotTypeCore", "Resources", "silero_vad.onnx")
HISTORY = os.path.expanduser("~/Library/Application Support/DoNotType/audio")


# ---------------------------------------------------------------- pause detectors

def energy_pauses(x):
    """AudioChunker.bestBoundary's candidate finder: (start_s, mid_s, duration_s, depth_db)."""
    n = len(x) // FRAME
    if n < 3:
        return []
    f = (x[:n * FRAME] * 32768.0).reshape(n, FRAME)
    levels = 10 * np.log10((f * f).mean(axis=1) / (32768.0 * 32768.0) + 1e-12)
    floor = np.sort(levels)[min(len(levels) - 1, len(levels) // 50)]
    threshold = max(-65.0, floor + 8.0)
    speaking = levels > threshold

    out, i, m = [], 0, len(speaking)
    while i < m:
        if speaking[i]:
            i += 1
            continue
        start = i
        while i < m and not speaking[i]:
            i += 1
        end = i
        # A run counts only when it is surrounded by speech; uniform noise cannot masquerade
        # as one enormous pause.
        if (speaking[max(0, start - EVIDENCE_WINDOW):start].sum() < EVIDENCE_FRAMES
                or speaking[end:min(m, end + EVIDENCE_WINDOW)].sum() < EVIDENCE_FRAMES):
            continue
        mid = start + (end - start) // 2
        out.append((start * 0.02, mid * 0.02, (end - start) * 0.02,
                    max(0.0, threshold - levels[start:end].mean())))
    return out


class Silero:
    def __init__(self, path=MODEL):
        import onnxruntime as ort
        options = ort.SessionOptions()
        options.intra_op_num_threads = 1
        options.inter_op_num_threads = 1
        self.session = ort.InferenceSession(path, options, providers=["CPUExecutionProvider"])

    def probabilities(self, x):
        """One probability per 512-sample window, state and 64-sample context carried."""
        n = len(x)
        count = (n + WIN - 1) // WIN
        state = np.zeros((2, 1, 128), dtype=np.float32)
        ctx = np.zeros(CTX, dtype=np.float32)
        sr = np.array(SR, dtype=np.int64)
        buf = np.zeros(CTX + WIN, dtype=np.float32)
        out = np.empty(count, dtype=np.float32)
        for i in range(count):
            off = i * WIN
            take = min(WIN, n - off)
            buf[:CTX] = ctx
            buf[CTX:CTX + take] = x[off:off + take]
            if take < WIN:
                buf[CTX + take:] = 0.0
            probability, state = self.session.run(
                ["output", "stateN"],
                {"input": buf.reshape(1, -1), "state": state, "sr": sr})
            out[i] = probability[0, 0]
            ctx = buf[-CTX:].copy()
        return out

    @staticmethod
    def speech_segments(probs, total_samples):
        """finalisedSpeechSamples' hysteresis, emitting ranges instead of a total."""
        segments, start, possible_end = [], None, None
        for i, p in enumerate(probs):
            cur = WIN * i
            if p >= THRESH:
                possible_end = None
                if start is None:
                    start = cur
                continue
            if p >= NEG or start is None:
                continue
            if possible_end is None:
                possible_end = cur
            if cur - possible_end < MIN_SIL:
                continue
            if possible_end - start > MIN_SPEECH:
                segments.append((start, possible_end))
            start, possible_end = None, None
        if start is not None and total_samples - start > MIN_SPEECH:
            segments.append((start, total_samples))
        return segments

    def pauses(self, x):
        """Gaps between finalised speech segments, in the same shape as energy_pauses."""
        probs = self.probabilities(x)
        segments = self.speech_segments(probs, len(x))
        out = []
        for a, b in zip(segments, segments[1:]):
            gs, ge = a[1], b[0]
            if ge <= gs:
                continue
            w0, w1 = gs // WIN, max(gs // WIN + 1, ge // WIN)
            confidence = float(1.0 - probs[w0:w1].mean()) if w1 > w0 else 1.0
            # Scaled to the same 0-20 range the energy detector's depth uses, so one scorer
            # can rank candidates from either source.
            out.append((gs / SR, (gs + ge) / 2 / SR, (ge - gs) / SR, confidence * 20.0))
        return out


# ---------------------------------------------------------------- policy

class Policy:
    def __init__(self, minimum, target, horizon, min_pause, pref_pause, engage, soft):
        self.minimum, self.target, self.horizon = minimum, target, horizon
        self.min_pause, self.pref_pause = min_pause, pref_pause
        self.engage, self.soft = engage, soft

    def score(self, candidate):
        _, seconds, duration, depth = candidate
        base = ((3.0 if duration >= self.pref_pause else 0.0)
                + min(2.0, duration) * 4
                + min(20.0, depth) / 10)
        distance = abs(seconds - self.target)
        if self.soft:
            # Normalised by the width of the acceptable window. Unbounded, the linear penalty
            # dominates every quality term at a 30 s target: a 1.2 s sentence break at t=22
            # loses to a 0.45 s breath at t=30.
            return base - 6.0 * distance / max(1.0, self.horizon - self.minimum)
        return base - distance


LIVE = Policy(20, 30, 45, 0.40, 0.80, engage=45, soft=True)
OFFLINE = Policy(45, 60, 75, 0.32, 0.50, engage=90, soft=False)
# Rejected: demanding a sentence-length pause. Kept so the rejection stays reproducible.
STRICT = Policy(20, 30, 45, 0.80, 1.20, engage=45, soft=True)


def simulate(pauses, total, policy):
    """Greedy live segmentation. Returns (cut times, pause length used per cut, tail seconds)."""
    if total < policy.engage:
        return [], [], total
    cuts, used, origin = [], [], 0.0
    while True:
        candidates = [(s - origin, m - origin, d, dep) for (s, m, d, dep) in pauses
                      if m - origin >= policy.minimum and d >= policy.min_pause and m > origin]
        if not candidates:
            break
        preferred = [c for c in candidates if c[1] <= policy.horizon]
        # Past the horizon, the first real pause rather than a prettier one that may never come.
        best = (max(preferred, key=policy.score) if preferred
                else min(candidates, key=lambda c: c[1]))
        cut = origin + best[1]
        if total - cut < 1.0:
            break
        cuts.append(cut)
        used.append(best[2])
        origin = cut
    return cuts, used, total - (cuts[-1] if cuts else 0.0)


# ---------------------------------------------------------------- reporting

def load(limit, minimum_seconds):
    files = sorted(glob.glob(os.path.join(HISTORY, "**", "*.wav"), recursive=True))
    picked = []
    for path in files:
        try:
            with wave.open(path, "rb") as w:
                if (w.getframerate() != SR or w.getnchannels() != 1
                        or w.getsampwidth() != 2):
                    continue
                duration = w.getnframes() / SR
        except Exception:
            continue
        if duration >= minimum_seconds:
            picked.append((path, duration))
    return picked[:limit] if limit else picked


def report(label, rows):
    segments = [len(c) + 1 for c, _, _ in rows]
    tails = np.array([t for _, _, t in rows])
    used = np.array([u for _, us, _ in rows for u in us])
    print(f"\n  {label}")
    print(f"    segments/recording  mean {np.mean(segments):.1f}   "
          f"never split: {sum(1 for c, _, _ in rows if not c)}/{len(rows)}")
    print(f"    TAIL seconds        p50 {np.percentile(tails, 50):5.1f}  "
          f"p90 {np.percentile(tails, 90):5.1f}  max {tails.max():5.1f}")
    if len(used):
        print(f"    pause cut on (s)    p10 {np.percentile(used, 10):4.2f}  "
              f"p50 {np.percentile(used, 50):4.2f}  mean {used.mean():4.2f}  "
              f"share >= 1.0 s: {(used >= 1.0).mean() * 100:.0f}%")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--limit", type=int, default=0, help="Only the first N recordings.")
    parser.add_argument("--minimum", type=float, default=45.0,
                        help="Ignore recordings shorter than this (seconds).")
    parser.add_argument("--segment", type=float, default=30.0,
                        help="Segment length assumed by the cost model (seconds).")
    args = parser.parse_args()

    picked = load(args.limit, args.minimum)
    if not picked:
        sys.exit(f"No 16 kHz mono recordings of >= {args.minimum:.0f} s under {HISTORY}")
    print(f"analysing {len(picked)} recordings >= {args.minimum:.0f} s "
          f"({sum(d for _, d in picked) / 60:.0f} min)", flush=True)

    silero = Silero()
    energy_rows, silero_rows, offline_rows, strict_rows, agreement = [], [], [], [], []
    counts = {b: [0, 0] for b in (0.40, 0.80, 1.00, 2.00)}
    no_pause = {b: [] for b in (0.5, 0.8, 1.0, 2.0)}
    start = time.time()

    for index, (path, duration) in enumerate(picked):
        with wave.open(path, "rb") as w:
            raw = w.readframes(w.getnframes())
        x = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0

        ep, sp = energy_pauses(x), silero.pauses(x)
        energy_rows.append(simulate(ep, duration, LIVE))
        silero_rows.append(simulate(sp, duration, LIVE))
        offline_rows.append(simulate(ep, duration, OFFLINE))
        strict_rows.append(simulate(sp, duration, STRICT))

        for b in counts:
            counts[b][0] += sum(1 for q in ep if q[2] >= b)
            counts[b][1] += sum(1 for q in sp if q[2] >= b)
        for b in no_pause:
            marks = [0.0] + [q[1] for q in sp if q[2] >= b] + [duration]
            no_pause[b].append(max(marks[i + 1] - marks[i] for i in range(len(marks) - 1)))
        for cut in energy_rows[-1][0]:
            agreement.append(min([abs(cut - d) for d in silero_rows[-1][0]], default=99.0))

        if (index + 1) % 20 == 0:
            print(f"    {index + 1}/{len(picked)}  {time.time() - start:.0f}s", flush=True)

    print(f"\nanalysed in {time.time() - start:.0f}s "
          f"({sum(d for _, d in picked) / (time.time() - start):.0f}x real time)")

    print("\npauses found, by detector")
    print(f"  {'>= dur':>8} {'energy':>8} {'silero':>8}")
    for b in sorted(counts):
        print(f"  {b:>7.2f}s {counts[b][0]:>8} {counts[b][1]:>8}")

    print("\nlongest stretch containing no Silero pause of that length (p50 / p90 / max)")
    for b in sorted(no_pause):
        g = np.array(no_pause[b])
        print(f"  {b:>4.2f}s : {np.percentile(g, 50):6.1f} / "
              f"{np.percentile(g, 90):6.1f} / {g.max():6.1f}")

    print("\npolicy simulation")
    report("offline 45/60/75, engage 90, energy (today)", offline_rows)
    report("live 20/30/45, engage 45, energy", energy_rows)
    report("live 20/30/45, engage 45, SILERO (proposed)", silero_rows)
    report("REJECTED: silero, but demanding a 0.80/1.20 s pause", strict_rows)

    if agreement:
        a = np.array(agreement)
        print(f"\ncut agreement: median distance from an energy cut to the nearest silero cut "
              f"{np.median(a):.2f}s;  within 1 s {(a <= 1.0).mean() * 100:.0f}%")

    # Cost model: `incremental` sends each segment once; `whole` re-sends everything each time.
    total = sum(d for _, d in picked)
    S, W = args.segment, 90.0
    full = window = 0.0
    worst = (0.0, 0.0)
    for _, duration in picked:
        k = int(duration / S)
        tail = duration - k * S
        f = sum(i * S for i in range(1, k + 1)) + tail
        window += sum(min(i * S, W) for i in range(1, k + 1)) + tail
        full += f
        if duration and f / duration > worst[0]:
            worst = (f / duration, duration)
    print(f"\naudio sent, whole corpus ({total / 60:.0f} min of speech, {S:.0f} s segments)")
    print(f"  incremental          1.00x   {total / 60:6.0f} min")
    print(f"  whole, {W:.0f} s window   {window / total:.2f}x   {window / 60:6.0f} min")
    print(f"  whole, unbounded     {full / total:.2f}x   {full / 60:6.0f} min"
          f"   (worst single recording {worst[0]:.1f}x, a {worst[1]:.0f} s dictation)")


if __name__ == "__main__":
    main()
