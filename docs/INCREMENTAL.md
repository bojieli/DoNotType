# Incremental transcription

How a long dictation is transcribed while it is still being spoken, why the boundaries land where
they do, and which alternatives were measured and rejected.

The one-sentence version: **accuracy work belongs on time the user is already spending, and never
on the critical path.** Everything below follows from that.

## The problem this solves

A long monologue produces one large request at the moment the user stops talking. That request is
slow because it is large, and the user is waiting for all of it. Worse, the maintainer's report —
and the premise this design was built on — is that a very long paragraph transcribes *less
accurately* than the same speech in pieces, because a single request gives the model one pass over
several minutes of audio.

`AudioChunker` already splits finished recordings on silence, and `LiveTranscriptionSession`
already transcribes pause-finalised parts while capture runs. What was missing was the reason to
do it: those segments were transcribed with the same model and the same settings as the final one,
so segmenting bought parallelism and nothing else.

Incremental transcription changes what the segments are *for*. A segment cut while the user is
still speaking has a latency budget nobody is watching. It can be given a slower, more accurate
model, and it can be given the transcripts that came before it. Only the last piece — from the
final pause to the key release — is ever on the critical path, and that piece is deliberately kept
short and cheap.

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

**The energy finder stays** as the fallback for when the model fails to load. `DetectorError
.unavailable` is a real state and boundary placement must survive it.

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

### The scoring function had a bug

`boundaryScore` ranked candidates as:

```
preferredBonus + min(2, duration) * 4 + min(20, depth) / 10 - abs(seconds - target)
```

That last term is linear and unbounded, so at a 30 s target it dominates everything else. A clean
1.2 s sentence break at t=22 scored ≈ 0.8; a shallow 0.45 s breath at t=30 scored ≈ 2.8. **The
scorer preferred the breath.** This was invisible at the old 60 s target because the acceptable
window was wide relative to the penalty.

Normalising the distance penalty by the width of the `minimum…horizon` window fixes it, and the fix
is free: median cut pause 1.00 s → 1.20 s and clean cuts 50% → 59%, with **identical** segment
count and identical tail. No trade at all.

### The policy

| | offline (`AudioChunker.defaultPolicy`) | live |
|---|---|---|
| engage after | 90 s of recording | 45 s of recording |
| `minimum` | 45 s | 20 s |
| `target` | 60 s | 30 s |
| `horizon` | 75 s | 45 s |
| `minimumPause` | 0.32 s | 0.40 s |
| `preferredPause` | 0.50 s | 0.80 s |

**These are two policies, not one constant that moved.** The offline splitter exists to
parallelise a recording that has already finished, where the only cost of a boundary is a seam.
The live segmenter's boundaries have a second job: a boundary is the last moment before which work
can still be free. That is a different objective and it wants earlier, more frequent cuts.

`AudioChunker.threshold` (90 s) governs whether a *finished* recording is worth splitting at all
and should stay where it is. Lowering it to serve the live path would make short offline
transcriptions pay for coordination they do not need.

Keeping a separate 45 s engagement gate for live matters for the same reason: a 35-second dictation
that gets split pays a seam to save latency nobody was going to notice. Once the gate opens the
segmenter still holds all the audio, so it places its first cut by looking *backward* at the best
pause from 20 s onward. Early boundary, no gamble on short recordings.

## The two policies

Both segment identically. They differ in what each request contains.

| | `incremental` | `whole` |
|---|---|---|
| each boundary sends | the new segment only | everything from the start |
| seams in the delivered text | one per boundary | **exactly one**, before the tail |
| audio sent, this corpus | 1.00× | **2.25×** |
| worst single recording | 1.00× | 5.3× (the 312 s one) |

`whole` is the more accurate shape and the reason is structural rather than statistical: because
each boundary re-transcribes from the beginning, the delivered transcript is *the last full
re-transcription plus the tail*. There are no cross-segment seams to stitch, nothing to
de-duplicate, and audio that was ambiguous early can be re-heard with everything that followed it.

The cost was expected to be prohibitive and is not. It grows quadratically in principle, but on a
real distribution dominated by 45–90 s recordings there are only one or two boundaries, so the
measured cost is 2.25× the audio tokens. A 90-second re-transcription window caps the tail of the
distribution at 1.83× but barely helps otherwise, so it belongs as a guard for very long
recordings, not as the default shape.

Upload size is not a constraint. Every request already goes out as 16 kbps Opus, so a 300-second
re-transcription is roughly 600 KB.

Names are deliberately plain: `incremental` sends each new part once, `whole` sends the whole
recording each time. `rewrite` was rejected as a name because `TranscriptMode.rewrite` already
means a text-only styling pass, and the distinction between "re-perceive the audio" and "edit the
text" is the one thing this document most needs to keep straight.

## The body/tail split

A segment cut mid-speech is a **body** segment; the audio from the last boundary to key release is
the **tail**.

| | body | tail |
|---|---|---|
| latency budget | hidden — the user is still talking | the entire user-visible wait |
| model | the accurate one | the fast one |
| thinking level | the model's floor | the model's floor |
| stall hedge | off, or 30 s | 8 s, as today |

Three details carry this:

**The tail is never made slower for accuracy.** It is the only audio the user waits on. Segmenting
earlier also *shortens* it — median critical-path audio drops from 52 s to about 12 s — so the
segmentation change is a latency improvement before any model choice is made.

**The release race is real and needs a hedge.** The user can stop talking three seconds after a
body segment was dispatched, at which point `finish()` awaits it and the "free" work is on the
critical path after all. The fix is the shape `FallbackTranscriber` already uses: on release, any
body segment still in flight gets a shadow request on the fast model, first answer wins. What makes
this work rather than merely doubling the wait is the finding in
[MODELS.md](MODELS.md#per-request-tail-latency) that slow draws are **independent per request and
uncorrelated across models** (|r| ≤ 0.28) — a fast-model shadow is unaffected by whatever queue the
accurate model is stuck in.

**Turn the stall hedge off for body segments.** It defaults on at 8 s, and 16% of `gemini-3.6-flash`
requests exceed 8 s. Left on, roughly a third of a long dictation's segments would fire a duplicate
request to buy latency nobody is waiting for.

## Rolling context

Later segments are given the transcripts of earlier ones, tail-truncated, as a reference part ahead
of the audio.

It must be labelled as reference and not as text to continue. This is the highest-risk part of the
design: a model handed "the transcript so far" plus new audio has an easy path to *continuing* the
text rather than transcribing the sound, and `HallucinationGuard` exists because this model family
will write fluent invention when handed nothing. The instruction belongs in `prompt/` like the rest
of the contract, and it must say: for spelling, names, casing and terminology; do not repeat it, do
not continue it, transcribe only this audio.

It must never block. Take whatever prefix is complete at dispatch, wait at most ~1.5 s for the
immediate predecessor, then go without it.

**It also introduces a new failure mode that must be stated out loud.** Today segments are
independent, so a mishearing is isolated. With carried context, an early wrong spelling of a name
becomes a *consistent* wrong spelling for the rest of the dictation. Consistency is not accuracy.
Keeping the window to the recent tail rather than the whole session limits how far a bad spelling
rides, but it does not eliminate this.

Under `incremental`, rolling context is also what launders the accurate model's work into the fast
model's tail: a term the body model already spelled correctly is available to the tail model as
prior text.

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
