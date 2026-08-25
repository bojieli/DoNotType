# Incremental transcription

An investigation into transcribing a long dictation while it is still being spoken. **The feature
was not built.** What the measurements found instead was a silent data-loss bug, and the fix for
that turned out to be one line.

This document is kept because the reasoning is reusable and most of it was wrong in instructive
ways. If you are here to change the chunker or the model, read *What survived* and *Rejected
alternatives*; the rest is the trail.

## What was proposed

A long monologue produces one large request at the moment the user stops talking. The premise was
that a very long paragraph transcribes *less accurately* than the same speech in pieces, and that
segments cut while the user is still speaking have a latency budget nobody is watching — so they
could be given a slower, more accurate model and the transcripts that came before them, with only
the final piece on the critical path.

Three things had to be true for that to be worth building. None of them survived.

| claim | verdict |
|---|---|
| Segmenting improves accuracy | **No.** Neutral on 10 English recordings, worse on 6 Mandarin ones, and the maintainer's review of 258 disagreements preferred the whole-file transcript. |
| More thinking on hidden-latency segments buys accuracy | **No.** Worse on both models, 1.6–2.3× slower, and it quintupled screen-context regressions on 3.6. |
| The accurate model is too slow to use directly | **No longer.** `gemini-3.6-flash` costs +0.5 s, not the 3.3× the old benchmark recorded. |

## What survived

1. **`gemini-3.6-flash` as the default.** It fixes a real bug (below) and now costs half a second.
2. **A truncation guard.** `TruncationGuard` catches a transcript too short for the speech in the
   recording — the failure the whole investigation accidentally uncovered.
3. **A fix to the boundary scorer**, which was preferring a breath near the target over a clean
   sentence break slightly earlier.
4. **Silero as a better boundary source**, measured but not yet shipped: it needs incremental
   streaming state to be viable in the live path.

Nothing about segmentation policy changed. The live path still engages at 90 seconds, and the
offline splitter still targets 60.

## The bug this actually found

`gemini-3.5-flash` **silently truncates long recordings.** On a 90-second Mandarin recording it
returned roughly 100 characters of a 310-character transcript, stopping mid-sentence at the
identical point each time, on 6 runs in 10. `gemini-3.6-flash` did it 0 times in 20. It is not the
output-token cap.

Nothing noticed. `HallucinationGuard`'s rate ceiling is a *maximum*, so 1.1 characters a second
passes it by being below the floor of suspicion rather than above the ceiling. The `[NO_SPEECH]`
marker was not written, because the model did transcribe — just not all of it. The user is handed
fluent, plausible text with the middle of their dictation deleted.

**The near-miss suite is structurally blind to this.** Its cases are short clips, and truncation
only happens on long audio. That blind spot is why the default had moved to 3.5 in the first place,
and it is the most reusable lesson here: a suite that measures one failure mode well will report
confidently on a recording where a different failure mode is the only thing that matters.

It is rare and recording-specific — 0 truncations in 30 whole-file runs across six other long
recordings — but on an affected recording it fires 40–60% of the time.

## The corpus these numbers come from

Every measurement below is computed over the maintainer's retained history on one machine,
snapshotted 2026-08-25: **743 recordings, 6.7 hours, mean 32.6 s, longest 311.8 s.** The corpus
grows with use, so re-running the script will not reproduce these counts exactly.

| length | recordings |
|---|---|
| < 30 s | 504 |
| 30–45 s | 92 |
| 45–90 s | 89 |
| 90–180 s | 43 |
| 180–300 s | 14 |
| > 300 s | 1 |

This distribution is the reason the feature is scoped the way it is. Two thirds of dictations are
under 30 seconds and must not be touched — for them, one request is correct and a seam is pure
loss. The design targets the **147 recordings of 45 s or more**, 237 minutes of audio.

It is also why the engagement threshold moved. At the old 90 s gate only **58 of 743 dictations
(8%)** could ever use the live path. At 45 s it is **147 of 743 (20%)**.

One caveat that should be re-checked before these numbers are treated as general: this is one
speaker, in one language mix, on one machine. The pause structure of a different speaker may not
look like this at all.

Reproduce with [`eval/segmentation-policy.py`](../eval/segmentation-policy.py). It makes no network
calls and costs nothing.

## Boundary placement

### Cuts have never landed at VAD boundaries

This is the first thing to get straight, because it is easy to assume otherwise and the assumption
changes what you think the seams are worth.

`AudioChunker.bestBoundary` finds pauses using **frame energy against a 2nd-percentile floor** — a
20 ms frame is "silent" when it sits more than 8 dB below the recording's own quiet level. Silero
VAD is loaded and run on every chunk, but only through `SpeechActivity.measure` as a yes/no gate on
whether a chunk contains speech at all. It was never consulted about *where* to cut.

What the energy finder does guarantee is that **a cut is never mid-word**: it requires a run of
quiet frames flanked by at least 100 ms of speech on each side, and it cuts at the run's midpoint
so both neighbours keep some silence. What it does *not* guarantee is that the cut is at a sentence
boundary.

### Silero is the better boundary source, measured

Running Silero's own hysteresis (0.5 / 0.35, 100 ms end silence, 250 ms minimum speech) and taking
the **gaps between finalised speech segments** as cut candidates, over the same 147 recordings:

| pause ≥ | energy | Silero |
|---|---|---|
| 0.40 s | 2656 | 2033 |
| 0.80 s | 949 | 1043 |
| 1.00 s | 686 | 847 |
| **2.00 s** | 226 | **451** |

Silero finds fewer short pauses and **twice as many long ones**. The mechanism is worth naming
because it explains the whole result: **the energy finder fragments a long pause.** A breath, a
keyboard tap or a chair creak inside a three-second silence rises above `floor + 8 dB` and splits
one real pause into two short ones. Silero holds the gap open, because a breath is not speech.

Swapping only the pause source, with the policy and scorer held identical:

| | energy | Silero |
|---|---|---|
| segments / recording | 3.7 | 3.6 |
| never split | 1 / 147 | 1 / 147 |
| tail p50 / p90 / max | 11.6 / 24.6 / 59.3 s | 11.8 / 27.3 / **50.3 s** |
| **median pause cut on** | 1.21 s | **2.14 s** |
| cuts on a ≥ 1 s pause | 59% | **78%** |

Same cadence, same latency, a better worst-case tail, and seams that sit in pauses nearly twice as
long. The two detectors genuinely disagree — only 50% of energy cuts land within one second of a
Silero cut (median distance 1.07 s) — so this is a real change in behaviour, not a cosmetic one.

It is cheap: 237 minutes of audio analysed in 45 seconds, about **318× real time**, or roughly 0.3%
of one core when run streaming. And it adds no dependency anywhere — Silero already ships and is
already loaded on all four clients.

**Measured, not yet shipped.** Re-measured on the shipping offline policy the trade is real but
mixed: median cut pause 0.76 s → 2.14 s and cuts on a pause of a second or more 40% → 77%, at the
cost of a longer final chunk (p50 17.9 s → 27.7 s, max 59.3 s → 76.9 s). On the offline path that
costs almost nothing, since latency barely tracks chunk length. In the **live** path it needs
incremental streaming state: `bestBoundary` runs on every ~200 ms of new audio, and re-running
Silero over the whole pending buffer each time would burn most of a core. Silero is designed to
stream — state and a 64-sample context carry window to window — so this is work, not a blocker.

**The energy finder stays regardless** as the fallback for when the model fails to load.
`DetectorError.unavailable` is a real state and boundary placement must survive it.

### Silero still does not detect sentences

A 2.14 s median pause is a much better proxy for a clause or sentence ending than a 1.20 s one. It
is still a proxy. Silero classifies speech against non-speech; it has no idea what a sentence is,
and someone pausing to think mid-clause produces exactly the same signal as someone finishing a
thought. Real sentence boundaries need text, and there is no text until after transcription.

Design accordingly: seams are *usually* clean, and the rolling context exists partly to cover the
times they are not.

### Long pauses cannot be required

The tempting rule — "cut only on a pause of a second or more, that's where sentences end" — was
measured and is wrong. Longest stretch of speech containing no *Silero* pause of a given length:

| pause length | p50 | p90 | max |
|---|---|---|---|
| ≥ 0.5 s | 21.4 s | 44.1 s | 69.5 s |
| ≥ 1.0 s | 31.8 s | 65.6 s | **144.0 s** |
| ≥ 2.0 s | 45.0 s | 84.8 s | 201.4 s |

A policy demanding 0.8 s minimum / 1.2 s preferred does buy cleaner seams — 90% of its cuts land
on a pause of a second or more, against 78% — and pays for them where it hurts most: **6 of 147
recordings are never split at all**, the p90 tail goes from 27 s to 44 s, and the worst case from
50 s to **98 s** of audio arriving on the critical path. That is the outcome the feature exists to
prevent, traded for a seam quality improvement nobody waiting for their text can see.

So the horizon fallback is load-bearing: past the decision horizon, take the first real pause
rather than waiting for a prettier one. Cut quality is a preference. Cutting at all is a
requirement. Neither is ever allowed to manufacture a mid-word cut.

### The scoring function had a bug, now fixed

`boundaryScore` ranked candidates as:

```
preferredBonus + min(2, duration) * 4 + min(20, depth) / 10 - abs(seconds - target)
```

That last term is linear and unbounded, so at a 30 s target it dominates everything else. A clean
1.2 s sentence break at t=22 scored ≈ 0.8; a shallow 0.45 s breath at t=30 scored ≈ 2.8. **The
scorer preferred the breath.** This was invisible at the old 60 s target because the acceptable
window was wide relative to the penalty.

Normalising the distance penalty by the width of the `minimum…horizon` window fixes it, and the fix
is free. Re-measured on the policy that actually ships, over the 60 retained recordings past the
splitting threshold: the median pause a cut lands in goes from **0.76 s to 1.32 s**, cuts landing
in a pause of a second or more from **40% to 60%**, with the same chunk count and a slightly
*shorter* final chunk. No trade at all — the old form was wrong rather than differently weighted.

### The policy did not change

One policy ships, and it is the one that always shipped: engage past 90 seconds of recording,
`minimum` 45 s, `target` 60 s, `horizon` 75 s, `minimumPause` 0.32 s, `preferredPause` 0.50 s.

A second, more aggressive live policy was designed — engage at 45 s, target 30 s — to put more
dictations through the incremental path. It is recorded here only so nobody re-derives it: the
reason it was not shipped is in *Why segmentation was not expanded* below, and it is a quality
reason rather than a cost one.

What *did* change is where a cut lands inside that unchanged policy — see the scorer fix above.

## Why segmentation was not expanded

The plan was to engage the live segmenter at 45 seconds instead of 90 and cut every 30 seconds
instead of 60, which would have taken it from 8% to 20% of dictations. Two measurements stopped it.

**Segmenting does not recover content.** Ten recordings from 136 s to 312 s, each transcribed whole
and in Silero-policy segments, with no screen context so length was the only variable:

| | whole 3.5 | segmented 3.5 | whole 3.6 |
|---|---|---|---|
| content, chars/s of audio | 7.79 | 7.64 | 7.77 |
| divergence from the 3.6 reference | 0.120 | 0.129 | — |
| closer to the reference | 7 / 10 | 3 / 10 | — |

Segmenting recovered more than 15% more text on **0 of 10** recordings. On six Mandarin recordings
it was consistently worse. Note the metric's own weakness, which is why it is not the argument: the
reference is itself a whole-file request, so it structurally favours the whole-file candidate.

**The maintainer reviewed the actual disagreements and preferred whole-file.** 258 aligned
differences across the ten recordings, judged by ear against the audio. That is the only ground
truth in this investigation, and it says segmenting costs quality in the ordinary case.

So blanket segmentation would trade a *frequent* small quality loss for protection against a *rare*
large one — and the rare one now has a direct fix in the model. Bad trade.

**What segmentation is still for** is unchanged and unaffected: past 90 seconds a single request is
slow enough that splitting on silence and transcribing concurrently is worth the seam. That is a
latency argument, it was always a latency argument, and it is the only one it can carry.

## Rejected alternatives

The point of this section is that each of these looked right first.

### A model-decided `rewrite` / `append` tag

The proposal: hand the model the full audio plus the transcript so far and let it emit a tag —
`rewrite` if it finds errors in the earlier transcript, `append` if it only needs to add the new
part.

Rejected. It asks the model to overrule audio it already transcribed correctly, using a text prior,
which is the exact mechanism [MODELS.md](MODELS.md) rejects keyterm biasing for — the extracted
terms were `GRPO, PPO` while the speaker said `DAPO`.

This is not hypothetical. During the model sweep run for this design, on `real-acronym`, screen
context alone turned a correctly transcribed **DAPO** into **DPO** with no invitation to fix
anything. A protocol that explicitly asks the model to look for "factual errors or mishearings"
makes that failure a feature.

`whole` gets the same benefit without the invitation: re-transcribing from audio with more
surrounding audio available is a fresh perception, not a text-driven edit. If the model's opinion
about earlier text is ever wanted, the safe shape is **report, don't act** — corrections come back
as data, are logged, and are never applied to text already delivered.

### A text-only pass to fix earlier mishearings

Cheap, and wrong. Without the audio a second pass can only guess at what was said, which is
inventing. The verbatim transcript is produced and stored first; nothing that cannot hear the
recording may alter it.

### Retro-correcting text already delivered

Only defensible where the app owns the text buffer. Text injected into another application is gone,
and reaching back into it is not a transcription feature.

### Raising the thinking level on body segments

The idea the whole investigation started from: since a body segment's latency is hidden, spend it
on `thinking_level: medium` and get a more careful transcript for free.

Measured and rejected — see [Thinking levels](#thinking-levels-measured--2026-08-25). Medium costs
accuracy on both models, costs 1.6–2.3× the latency, and on `gemini-3.6-flash` it **quintupled the
regression count**, which is the one number this project cannot trade.

The warning sign was there beforehand and was read too weakly: MODELS.md's per-request study found
**output tokens pinned at exactly 30 across every trial of every model**, so at their default levels
the slow requests were never thinking more — they were queued. "Thinking buys accuracy" was an
assumption imported from other tasks, not an observation about this one. Transcription is a
perception task; there is nothing to reason about, and reasoning capacity spent on it goes into
second-guessing the audio against the screen.

## Mistakes already made against this code

Recorded because each cost time and each is easy to repeat.

**"The live path uploads raw WAV."** It does not. `TranscriptionService.transcribe` calls
`AudioFile.compressedForUpload()`, and every path funnels through it — live segments, offline
chunks and single requests alike. A `mimeType: "audio/wav"` at a call site such as
`LiveTranscriptionSession.submit` is the *input* to that funnel, not the wire format. Any new
request path must route through the same funnel rather than building its own `InputPart.audio`.

The one real gap: `compressedForUpload()` deliberately returns the WAV unchanged when
`OpusEncoder.isAvailable` is false, on the principle that a compression optimisation must never
cost someone their words. `dnt doctor` reports that state.

**"Cuts already land at VAD pauses."** They land at energy-qualified pauses. See above.

**Treating a small move in the near-miss suite as evidence.** The suite prints its own per-pass
spread for a reason. Two runs of the same condition during this work scored 37/48 and 39/47. A
change smaller than that spread has not been shown to do anything.

**Trusting a suite outside what it measures.** Worse than the above, and the mistake that cost the
most here: the near-miss suite was read as a verdict on which model to ship, when its cases are
short clips and the failure that decides the question only happens on long audio. It reported 3.6
ahead by 4 points, inside its own noise. The real margin was 0 truncations against 6 in 10. Ask
what a suite *cannot* see before citing it.

**Scoring a Mandarin transcript with a Latin-only tokenizer.** A word-error rate computed with
`[a-z0-9']+` on a 71%-CJK transcript scores the handful of English words and silently ignores
everything else. `eval/make-review-sheet.py` and `eval/score-review.py` both split Latin words and
CJK per character, and any new measurement must do the same.

**A synthetic fixture with less pause than real speech.** The energy floor is the 2nd percentile of
frame energy, so a test clip whose only quiet is the pause under test estimates its floor from
speech and then finds no speech at all. Real dictation is 39% to 86% pause.

**Assuming a C# record struct honours its primary constructor's defaults.** `new()` on a record
*struct* zero-initialises. `AudioChunker.DefaultPolicy` was every field zero on that client, and
every chunker test passed anyway.

## Thinking levels, measured — 2026-08-25

Nothing in this repository had ever varied `thinking_level` as an independent variable. Every table
in [MODELS.md](MODELS.md) was produced with "thinking level as the provider picks it per family".
The body/tail split has two independent dials — *which model* and *how much thinking* — so the
second one needed a number before it could be designed around.

Near-miss suite, 16 cases × 3 passes × 2 requests (with and without context) = 96 requests per
condition, run sequentially so wall clock is comparable:

| model | thinking | matched | rate | **regressed** | s / request |
|---|---|---|---|---|---|
| `gemini-3.5-flash` | minimal | 39 / 47 | 83.0% | 1 | 2.53 |
| `gemini-3.5-flash` | low | 39 / 48 | 81.2% | 2 | **1.79** |
| `gemini-3.5-flash` | medium | 37 / 48 | 77.1% | 2 | 4.04 |
| **`gemini-3.6-flash`** | **minimal** | **41 / 47** | **87.2%** | 1 | 3.21 |
| `gemini-3.6-flash` | low | 40 / 48 | 83.3% | 2 | 2.40 |
| `gemini-3.6-flash` | medium | 36 / 48 | 75.0% | **5** | 5.82 |

Two conditions lost one run each to a request timeout; rates are reported over completed runs.

**More thinking is worse, on every axis measured.** It costs accuracy on both models (83.0 → 77.1%
and 87.2 → 75.0%), and it costs 1.6–2.3× the latency. There is no configuration in which the body
segments should ask for more thinking than the model's floor. The idea that started this
investigation — hide a longer think behind the user's own speech — is dead, and it was worth 576
requests to find out.

**The most important number in the table is the regression column.** `gemini-3.6-flash` at `medium`
broke a correct baseline **5 times**, against 1 at `minimal`, where the suite's own per-pass range
is 0–2. Screen context overwriting spoken content is the failure this project exists to prevent,
and raising the thinking level made it *more* frequent. The mechanism is plausible on its face:
more thinking is more opportunity to reason that the text on screen is what the speaker must have
meant. Anyone tempted to raise this dial for some other purpose should treat it as a grounding-safety
change, not a quality one.

**The model gap is real but much smaller than MODELS.md records.** At `minimal`, 3.6 beats 3.5 by
41/47 against 39/47 — about 4 points. The historical near-miss result of 43–44 / 48 for 3.6 against
31–35 / 48 for 3.5 **did not reproduce**; 3.5 scored far better here than that table predicts. The
corpus and the prompt have both been re-recorded since those numbers were taken, so they are
measuring a different contract. Do not cite the old gap as the justification for the body model.

Latency has moved too: 3.6 cost 1.3× 3.5 per request here, not the 3.3× implied by the medians in
MODELS.md's latency table.

**What this means for the design.** The thinking dial is settled — always the model's floor, for
body and tail alike. The model dial is *not* settled: a 4-point difference on a 47-run suite whose
own noise floor is 2 runs is suggestive, not conclusive. Since body-segment latency is hidden, the
cost of being wrong is small and the change is worth making, but the confirmation run is a
higher-pass comparison of `3.5 @ minimal` against `3.6 @ minimal` and nothing else — the other four
conditions are eliminated.

Reproduce one cell with:

```bash
dnt-eval suite eval/nearmiss --provider google \
    --model gemini-3.6-flash --thinking minimal \
    --repeat-count 3 --scorecard out.json
```

## Reproducing the segmentation measurements

```bash
python3 eval/segmentation-policy.py            # energy vs Silero, policy simulation, costs
python3 eval/segmentation-policy.py --limit 10 # a quick subset
```

It reads `~/Library/Application Support/DoNotType/audio` and the checked-in
`Sources/DoNotTypeCore/Resources/silero_vad.onnx`, makes no network calls, and costs nothing.
