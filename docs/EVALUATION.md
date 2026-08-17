# Evaluation

Why this project has a measurement layer at all, how to run it, and what the numbers currently say.

## The failure that needs measuring

There are two ways screen context can corrupt a transcript, and they are not equally visible.

**Insertion** — the model writes a word that is on screen but was never spoken. This reads as a
glitch. You catch it.

**Substitution** — you say something, the model finds a near-match in the context, and quietly
replaces yours with it. You say "Gemini 3.5 Flash"; the screen says "Gemini 3 Flash"; that is what
you get. **This reads as a correctly transcribed technical term and ships.**

Substitution is the reason this project exists, and it cannot be caught by ordinary assertions or
by reading your own output. It has to be measured against ground truth, repeatedly, because
transcription is non-deterministic.

## Running it

```bash
swift test                                     # 73 unit tests, no network
DNT_INTEGRATION=1 swift test                   # live API, real speech, costs money

swift run dnt-eval probe --audio some.wav      # does this provider actually forward audio?
swift run dnt-eval once   --audio some.wav --visible-text "..."
swift run dnt-eval suite  eval/nearmiss        # the near-miss suite
swift run dnt-eval ablate                      # compare designs on fidelity and latency
./eval/model-sweep.sh                          # compare model versions
./eval/extract-real-audio.sh ~/Movies          # build a corpus from real recordings
```

`dnt-eval` reads `prompt/`, so `--prompt path/to/custom-prompt-dir` measures an edited prompt. If
you change any part in the app, the numbers below stop applying to you — re-measure.

## How the suite scores

Each case runs twice, with context and without, and **both are judged against ground truth**.
Scoring the diff alone would be wrong: the no-context baseline is itself unstable, so a large diff
from a *wrong* baseline is grounding doing its job.

| Effect | Meaning | Bar |
|---|---|---|
| `improved` | baseline wrong, context fixed it | the feature working |
| `neutral-correct` | both right | fine |
| `neutral-wrong` | context did not help | tolerable |
| **`regressed`** | **baseline right, context broke it** | **must be 0** |

`--repeat-count` defaults to 3. One run is an anecdote — an early single-pass run of this suite
reported 0 regressions and the next reported 2.

## Where grounding goes wrong, and what fixes it

Two results from 2026-08-10, measured on this machine against `gemini-3.6-flash`. **They are not
reproducible from this checkout** — see *Current numbers* below — so they are recorded as
observations, not as the project's published figures.

**The failure is numeric, not phonetic.** Across the 12-case near-miss suite (36 runs), every word
-level case passed: names, an acronym chain (VAD/ASR against TTS/NLU on screen), Scrum against
Kanban, brands, code-switched Mandarin. Both regressions were numbers, and one of them —
`4240` → `1024` — is a value that appears in neither the audio nor the screen. A wrong name is
recoverable by reading it. A wrong version number is not: nothing in the sentence marks it as wrong.

**Ablation on the reference clip** (speaker says "Gemini 1.5", screen says "2.5"), 12–15 trials:

| condition | substituted | correct | rate | mean latency |
|---|---|---|---|---|
| grounded | 7/12 | 5 | 58% | 8.6 s |
| no context at all | 1/13 | 12 | 8% | 8.4 s |
| grounded + digit guard | 1/12 | 11 | 8% | 17.2 s |

The digit guard runs a second transcription that never sees the screen and takes the digit
sequences from it, aligning positionally and declining entirely when the two runs disagree on how
many numbers there are. On this clip it never had to decline (0 of 12), corrected 6 and found the
runs already agreed on 6.

**A prediction of mine that measurement falsified.** I claimed issuing the two requests
concurrently would make the guard cost tokens rather than latency. It does not: the legs genuinely
overlap (grounded 7.0 s, audio-only 16.6 s, wall 17.2 s — wall tracks the slower leg, not their
sum) but they contend for the same upload, so the pair still costs roughly double. The guard
therefore ships **off by default**, with the trade stated in Settings.

## Does grounding earn its cost?

For a while the answer looked like no. An earlier run scored `improved` **0** against 2
regressions — context corrected nothing the no-context baseline got wrong. That turned out to be an
artefact of the corpus, and finding out why was the most useful thing in this section.

Probing every real clip with **no context at all**, `gemini-3.6-flash` already produces `VAD model,
which means voice activity detection`, `ASR model`, `Scrum dashboard`, `retrieval pipeline`,
`gradient`, `minimize`, `next token prediction` — every technical term the suite was built around,
spelled correctly, unaided. The screen had nothing to offer. Grounding was not failing; it was never
being asked a question it could answer.

Grounding can only help with a token the model **cannot** know. Cases 13–15 supply three: `Kaelith`,
`Brindlewood`, `quillmark-sync`, each invented, each with an obvious phonetic fallback, each spelled
correctly on the simulated screen. With them in place, the same suite:

```
runs             45  (40 matched ground truth)
improved          5   ← context fixed a wrong baseline
neutral-correct  35
neutral-wrong     4
REGRESSED         1
```

So grounding does earn its place — but only where the model is genuinely ignorant, which is a much
narrower claim than "context improves transcription".

**The one that fails is the most informative — but not for the reason first recorded here.**
`Brindlewood` and `quillmark-sync` transfer 3/3. `Kaelith` does not: it comes back as **`Keyleth`**,
a name the model already knows, even with the correct spelling in the visible text three times.

The first conclusion written here was that this is the model's own vocabulary overriding the screen,
and that *"no amount of screen text dislodges it"*. **That was wrong, and measuring it was the most
useful thing in this document.** The correct spelling was never given a fair hearing — it was in the
wrong channel.

## Channel weight: the caret window dominates

The same word, the same audio, moved only between the sections the encoder already emits:

| where the correct spelling sits | `Kaelith` transcribed correctly |
|---|---|
| visible text (10,000-char section) | **0 / 12** |
| text before caret (1,000-char section) | **12 / 12** |
| both | 12 / 12 |

And the same asymmetry in the harm direction, with the reference clip's `2.5` decoy:

| where the decoy sits | `2.5` substituted for the spoken `1.5` |
|---|---|
| visible text | 3 / 10 |
| text before caret | **7 / 10** |

So the caret window is far stronger in **both** directions. It is the high-signal *and* high-risk
channel, and the sprawling visible-text section — ten times the budget — is comparatively inert.
Every near-miss case in this suite puts its decoy in visible text, which means **the substitution
rates recorded here understate the failure**: the same contradiction sitting in the user's own field
is roughly twice as likely to overwrite what they said.

Two consequences worth keeping in view:

- The model's vocabulary is not immovable. It just needs the correction somewhere it is actually
  reading. `Keyleth` is not a floor.
- You cannot exploit this directly. The caret window is whatever the user's field already contains —
  the app's screen text cannot be relocated into it. The finding is therefore mostly a warning:
  dictating a correction into a document that already contains the wrong value is the worst case,
  and it is exactly when people dictate corrections.

Case 13 is kept as a failing case, since the default encoding does fail it. What changed is the
explanation attached to it. Case 16 is its twin with the spelling moved to the caret window and
passes 3/3 — the pair is what protects the finding, because case 13 already fails and so could not
notice an encoder change that dropped the caret sections entirely.

**Read single suite runs with care — the suite now says so itself.** Two consecutive runs of the
same 16 cases gave `improved 5, regressed 1` and `improved 7, regressed 3`. The direction is stable
— every regression in both was numeric — but the counts are not.

Because every case runs `--repeat-count` times, pass 0 across all cases is a complete independent
suite result, as are passes 1 and 2. The summary reports the range those passes took:

```
improved         7  (2–3 per pass)
REGRESSED        4  (1–2 per pass)

3 case(s) gave different answers across passes: real-version-number, real-codeswitch, benefit-novel-name
```

That range is the noise floor, measured from the same data at no extra cost. A prompt or model
change that moves a count by less than it has not been shown to do anything. This project's
changelog is largely a record of confident predictions that measurement destroyed; an instrument
that reported bare totals was an invitation to add more of them.

### Does compressing the upload cost fidelity?

Opus was adopted for latency, and the check that the transcript was unaffected was done on
synthesized clips — where the number is pronounced cleanly, which is the easy case. The reference
recording is the opposite: an unstressed "one point five" mid-sentence, exactly the cue a lossy
codec might discard. Re-measured against it, no context, 10 trials each:

| upload | transcribed the number correctly |
|---|---|
| uncompressed WAV | 7 / 10 |
| Opus 16 kbps | 8 / 10 |

No cost. The one-point difference is well inside the noise at this sample size, and the compressed
run was nominally the better of the two. `DNT_NO_COMPRESSION=1` re-runs this comparison, and it is
worth re-running whenever the bitrate or the model changes — the answer is not obviously stable
across either.

Note also what the two rows say about the clip: the model gets this right roughly 7–8 times in 10
**with no screen context at all**. Every substitution figure here should be read against that, not
against an assumption of a perfect baseline.

### Acting on it: the guard is aimed at the caret window

Every earlier digit-guard measurement put the decoy in visible text — the weak channel. Re-run with
the decoy in the caret window, where substitution actually bites:

| decoy in | without guard | with guard | guard latency |
|---|---|---|---|
| visible text | 30% | 8% | — |
| **caret window** | **75%** | **20%** | 9.4 s vs 7.9 s |

The guard worked where it was needed most, so `NumberCheckPolicy.whenCaretHasNumbers` was made the
default: it spent the second request only when the text around the caret contained digits, and
never for ordinary dictation into an empty field. Digits in the visible text alone did not trigger
it — a sidebar, a timestamp or a row count would have made the cost constant while the benefit
stayed occasional. That reasoning was right about where the benefit is and wrong about how often
the trigger fires; see below.

**A latency claim of mine that needs correcting.** I recorded that the guard "roughly doubles the
wait" from 8.6 s to 17.2 s. The run above shows 9.4 s against 7.9 s — about 1.5 s of overhead. Both
were real measurements of the same code; the difference is network variance, which is precisely the
trap the suite's new noise-floor reporting exists to prevent, and I walked into it. **The honest
statement is that the overhead is one extra concurrent request, somewhere between negligible and a
doubling depending on the connection**, and a single measurement of it should not be quoted as a
constant.

**What this does not settle.** The benefit cases are synthesized, so they measure spelling transfer
rather than transfer under ambiguous human speech.

### Withdrawn: the guard was removed on 2026-08-16

The measurements above stand. The feature built on them does not, and the reason is the sentence
I bolded and then failed to act on: *the overhead is somewhere between negligible and a doubling
depending on the connection*. That is not a cost you can accept on a user's behalf, because the
quantity it depends on is the one that was already hurting them.

Profiled against `gemini-3.6-flash` over 38 requests carrying the same 22.8 s clip, single-request
latency was 8.9 s at the median, 21 s at p90 and 43 s at the maximum, with one connection dropped
outright at 62 s. The guard makes a dictation wait on the **slower of two draws** from that
distribution: p90 moves 21 s → 37 s, and the share of dictations over 20 s goes 14% → 26%. The
1.5 s figure above was a median talking, on a day when the tail behaved.

The trigger made it worse. `whenCaretHasNumbers` was meant to fire occasionally; it fires on any
digit in a 1,000-character caret window, which in a terminal or an editor is always. Sampled
against real stored contexts from one session, it fired on 6 of 6.

A number the model got wrong is a grounding and prompt failure. Buying a second opinion and
splicing digits out of it treats the symptom, and charges the tail of the latency distribution
for it. `NumericGuard`, `NumberCheckPolicy`, `--verify-numbers` and the `digit-guard` ablation
condition are all gone; the substitution rates are left here because they are still the argument
against grounding numbers in the first place.

## Hallucination on silence

The failure that needs no context to be terrible: a recording with nothing in it, transcribed as a
sentence. A model asked for words tends to produce words, and the documented case is a stock phrase
— "Thank you.", a subtitle credit — typed into somebody's document as if they had said it.

Two things made this worth attacking rather than assuming:

1. **`prompt/system.md` rule 7 was never tested.** It says silent, empty or unintelligible audio returns
   an empty transcript. Nothing measured whether any model obeys it.
2. **Recognisers never receive the rule.** Deepgram, xAI and Mistral Voxtral have no system
   instruction, so rule 7 is not sent to them at all — and Whisper-family recognisers are the ones
   most documented for this behaviour. The gap was exactly the wrong way round.

### The defence does not rely on the model

`SpeechActivity` checks the audio before the request, on every client, and a backend cannot
hallucinate audio it never received. It keys on modulation rather than loudness — speech has
syllables and pauses, a fan does not — because gating on volume would discard somebody dictating
quietly, which is a worse failure than the one being prevented.

Measured against `eval/audio/silence/`:

| audio | detected as speech |
|---|---|
| digital silence, room tone, steady noise, 50 Hz hum | 0 ms |
| one keyboard click | 20 ms |
| real speech | 1160 ms |
| real speech at −46 dB | 800 ms |

The threshold is 200 ms — ten times the loudest non-speech, a quarter of barely-audible speech.

### Measuring what the gate protects against

The gate means these recordings never reach a model in normal use, which is the point, and also
means the underlying question goes unanswered unless it is asked deliberately:

```bash
dnt-eval silence --provider gemini
dnt-eval silence --provider deepgram --repeat-count 5    # the interesting one
```

A pass is an empty transcript. Anything else is printed verbatim, because recognising the *shape*
of the invention — a stock phrase, a credit line — matters more than the count. Errors are reported
separately and never counted as passes: a backend that failed has not demonstrated the behaviour
either way. The command exits non-zero if anything was invented, so it can gate a release.

**No numbers are published here yet.** The harness exists and has not been run against a paid
backend; publishing a table from a single unverified run would be worse than an empty section.

## Latency

Measured end to end on this machine, median of repeated runs, `gemini-3.6-flash`. For comparison,
Typeless is roughly 2 s at 10 s of speech and 5 s at 30 s.

| clip | PCM upload | Opus upload |
|---|---|---|
| 10 s | 6.9 s | **4.9 s** |
| 30 s | 13.1 s | **9.9 s** |

Opus at 16 kbps is 16× smaller than 16 kHz PCM — 60 kB against 960 kB for 30 seconds — and the
transcript does not change: the same fixtures come back identical as WAV, FLAC and Opus, billed the
same audio-token count. That is the whole of the win; the remaining gap to Typeless is not upload.

### The remaining gap is the model, and it is buying something

Sweeping the same clip across model IDs with everything else held constant:

| model | 10 s clip | 30 s clip |
|---|---|---|
| `gemini-3.6-flash` (default at measurement time) | 5.9 s | 9.3 s |
| `gemini-3.5-flash` | **2.6 s** | **3.2 s** |
| `gemini-3-flash-preview` | 2.5 s | 3.5 s |
| `gemini-2.5-flash` | errors on every request | — |

So the gap to Typeless is entirely the model — and `gemini-3.5-flash` does not merely close it, it
beats those figures. Which makes the obvious move look very attractive, right up until you measure
what it costs. On the reference clip, 12 trials:

| model | grounded | no context at all |
|---|---|---|
| `gemini-3.6-flash` | 58% substituted | **8%** |
| `gemini-3.5-flash` | 75% substituted | **83%** |

Read the no-context column. `gemini-3.5-flash` writes the wrong number 83% of the time **with no
screen context at all** — it simply cannot hear "one point five" on this audio. That is not a
grounding failure that better prompting could fix; it is the transcription being wrong, which is
the one thing this project exists to prevent.

**So the latency is a purchase, not a defect.** DoNotType is roughly 2× slower than Typeless
because it runs a model that gets the number right 92% of the time unaided, instead of one that
gets it wrong 83% of the time three times faster. Anyone tempted to close the gap by switching
models should run `dnt-eval ablate --model <id>` first and look at the no-context column before
looking at the clock.

This also reframes the comparison. A tool being faster is not evidence that it is better engineered
if it is fast for this reason, and nothing here establishes which model Typeless runs — only that
whatever produces 2 s at 10 s of speech is in the performance class where this failure lives.

**A prediction of mine that measurement reversed.** I expected the structured-output JSON schema to
cost latency, and suggested dropping it as the next optimisation. It is the opposite:

| clip | with schema | without |
|---|---|---|
| 10 s | **5.3 s** | 12.0 s |
| 30 s | **9.8 s** | 10.2 s |

Unconstrained, the model writes prose around the transcript, and the extra output tokens cost far
more than the constraint saves. The schema is a latency *feature*, most visibly on short clips
where the wrapper text is a large fraction of the output. `DNT_NO_SCHEMA=1` exists only to re-run
this measurement; it is not a supported configuration, since unconstrained output occasionally
arrives wrapped in "Here is the transcript:", and a dictation tool that sometimes types that is
broken.

Note the `35.42` outlier in that run's no-schema column, against a 10 s median — a reminder that
single latency measurements on a live API are worth very little, which is a lesson this document
has now learned twice.

## Current numbers

The authoritative real-speech WAV payloads are not present in this checkout. That includes
`real-talk-gemini15.wav`, `real-mandarin.wav`, `real-codeswitch.wav`, `real-acronym.wav`, and the
later acronym/jargon/brand fixtures. The ignored file at `real-talk-gemini15.wav` has the known
synthetic TTS hash and is rejected by the benchmark guard. Therefore there is currently **no valid
full-suite count, Gemini 1.5-versus-2.5 substitution rate, code-switch number result, or claim that
only numeric values regress** that can be reproduced from this repository.

Earlier revisions of this document listed results for those recordings, but the payloads were
never actually committed despite a commit message saying they were. Those figures are not retained
as current evidence: without the exact audio, neither the ground truth nor the trial population can
be audited. The synthetic `say`/`espeak` clips remain useful for transport plumbing only and must not
be used to fill the missing cells.

Current local-GPU evidence uses downloaded, revision-pinned model checkpoints and separately
labeled public real recordings. It is recorded in [MODELS.md](MODELS.md) and
[`eval/results/local-real-audio-2026-08-10.json`](../eval/results/local-real-audio-2026-08-10.json).
Those Obama, Barcelona, AISHELL, and SEAME observations (including the acronym-chain and
decimal-number controls) exercise audio transport, language fidelity, and hostile-context behavior,
but none substitutes for a named DoNotType fixture.

When the exact WAVs are restored, real-speech cases should continue to assert **fragments** rather
than an exact transcript (`mustContain`, `mustNotContain`). A stochastic 22-second transcription
varies on wording unrelated to the near-miss under test, so the scorer should name the few tokens a
case turns on and ignore the rest.

## Ablation

`swift run dnt-eval ablate`, 15 trials per condition:

The table below is retained as historical handoff context only. It cannot be reproduced or cited as
a current benchmark until the exact `real-talk-gemini15.wav` recording is restored and verified.
The README used to quote its 36%/21% row as the project's headline figure; it no longer does, and
neither should anything else.

**This is the single most valuable outstanding contribution to the project.** Restoring a real
recording of a speaker saying a version number that contradicts the screen — and committing it —
turns every number in this section from an anecdote back into evidence. The case format is in
`eval/nearmiss/`, and a cassette recorded from it (`dnt-eval suite --record`) would let anyone
re-score it afterwards for free.

| condition | substituted | rate | mean latency |
|---|---|---|---|
| no context at all | 3/14 | 21% | 5.7 s |
| verbatim + context | 4/11 | 36% | 5.5 s |
| single request, transcribe + formalise | 5/13 | 38% | 15.7 s |
| two requests, transcribe then formalise | 9/12 | 75% | 7.5 s |

Two predictions were falsified here. Both are recorded in `PROMPT.md`'s changelog because the
reasoning was plausible and someone will otherwise re-derive it.

## Models

`./eval/model-sweep.sh`. Same clip, same hostile context.

This sweep is also historical and currently unverifiable because that clip is missing. Re-run it
from the downloaded/hosted models only after the exact reference WAV has been restored; do not infer
these cells from synthetic audio or the public smoke-test clips.

| model | version transcribed with **no** context | verdict |
|---|---|---|
| `gemini-3.6-flash` | "Gemini 1.5" | correct — the default at measurement time |
| `gemini-3.5-flash` | "Gemini 2.4" | mis-hears it |
| `gemini-3-flash-preview` | "Gimma 2.0" | mis-hears it |
| `gemini-2.5-flash` | — | retired: "no longer available to new users" |

All three available models process the audio (550 tokens each); none silently drops it. Only 3.6
transcribes the number correctly without any context, and its general transcription is visibly
better ("unified source" versus "unified sauce" versus "verified source"). The older models cannot
be scored for substitution at all, because they produce neither the spoken nor the decoy value.

**Re-run the sweep on any model bump.** Multimodal quality moves between releases, and this is the
only measurement here that would notice.

Cross-vendor results, including OpenAI's audio models and the provider-versus-model comparison, are
in [MODELS.md](MODELS.md).

## Building a corpus

```bash
./eval/extract-real-audio.sh ~/Movies 22
```

Extracts 16 kHz mono clips — the same format the apps record — from any media with an audio track.
Two warnings from experience:

1. **Verify the clip before trusting a failure against it.** One extracted clip was near-silent,
   and two runs over it disagreed — one hallucinated "hello testing", the other returned empty.
   That looked like a routing bug and was silence.
2. **Ground truth needs a human.** Transcribe each clip, check it by ear, and write the verified
   text into a case file before treating any number as real.

## Adding a case

```json
{
  "id": "port-number",
  "note": "Why this case is adversarial.",
  "audio": "../audio/port-number.wav",
  "expectTranscript": "Run the dev server on port 8081.",
  "context": {
    "appName": "Terminal",
    "visibleText": "Port 8080 is already in use..."
  }
}
```

Good cases are near-misses: a version one digit off what is on screen, a name that rhymes with a
heading, a command one character off from the scrollback. A case the model gets right without
context measures nothing.

**Do not delete a failing case to make the suite green.** `04-jargon-spelling` is kept precisely
because it exposed a provider difference, and the real-speech substitution case is kept because it
is the only test in the project that has ever caught the bug the project is about.

## Speech recognition backends — 2026-08-12

Deepgram and xAI are not language models, which changes what the suite is measuring. A recogniser
cannot substitute a version number it read on screen, because it never saw the screen. So the
question is not "does grounding corrupt this" but **what does giving up grounding cost, and what
does it buy** — and, once keyterm biasing exists, whether a word list reintroduces the failure a
prompt was managing.

Reproduce with `eval/benchmark-speech.sh`. Full numbers in
[`eval/results/speech-recognition-2026-08-12.json`](../eval/results/speech-recognition-2026-08-12.json).

**The baseline here is OpenRouter, not native Gemini.** The `GEMINI_API_KEY` in this environment
was rejected as invalid, so the model-provider column could not be measured natively. This
repository has previously measured OpenRouter as the *worse* of the two on this suite (12/15
against 15/15 on 2026-08-09), so read that column as a floor for a model provider rather than as
Gemini's figure.

| backend | matched | improved | **regressed** | mean latency |
|---|---|---|---|---|
| openrouter · `google/gemini-3.6-flash` | 38–43 / 48 | 4–7 | **2–5** | 6.50 s |
| **xai · `grok-stt` · keyterms** | **29–30 / 48** | 13–14 | **0** | **1.19 s** |
| deepgram · nova-3 · `multi` · keyterms | 27 / 42 | 9 | **0** | 1.1–2.3 s |
| mistral · `voxtral-mini-latest` | 21 / 48 | 0 | **0** | 1.5–1.9 s |
| deepgram · nova-3 · `multi` | 18 / 42 | 0 | **0** | 1.33 s |
| xai · `grok-stt` · no keyterms | 16 / 48 | 1 | **0** | 1.19 s |
| deepgram · nova-3 · `detect_language` | 12 / 42 | 0 | **0** | 1.26 s |

Deepgram's denominator is 42 rather than 48 because two cases — both Mandarin — error outright
rather than returning a wrong transcript. Counted against all 48 runs, its best configuration is
27/48 (56%) against the model provider's 40/48 (83%).

**`improved` and `regressed` mean nothing for an ungrounded backend.** With no grounding the two
suite arms send byte-identical requests, so both counts are trivially 0. Only the Deepgram
keyterms row's `9 / 0` is a real result; the rest of that column is an artefact of the harness
being pointed at something it was not designed for. The comparable column is `matched`.

### What grounding is worth to the model, replicated

The model column was originally a single run, which is the mistake this document keeps warning
about. Three independent runs of the identical suite:

| run | ungrounded | grounded | improved | **regressed** |
|---|---|---|---|---|
| 1 | 39 / 48 | 40 / 48 | 4 | **3** |
| 2 | 39 / 48 | 43 / 48 | 6 | **2** |
| 3 | 36 / 48 | 38 / 48 | 7 | **5** |

Two things hold across all three, and they point in opposite directions.

**Grounding always helps a little.** Net +1, +4, +2 matched runs. It is never negative.

**It never stops causing regressions.** 3, 2 and 5 — the number this suite exists to report, and
the one the contract says must be zero. Every run buys its improvements by breaking cases the
ungrounded baseline had right.

The ungrounded model is the more interesting figure: **36–39/48 with no screen context at all**,
against the best recogniser's 29–30 *with* hints. `gemini-3.6-flash` already spells `koffi`,
`VAD`, `Kanban` and `retrieval pipeline` unaided, which is the finding recorded further up this
document — grounding is not failing, it is rarely being asked a question it cannot already answer.

**These are OpenRouter numbers, not native Gemini.** This repository has measured the same model ID
as worse through a gateway (12/15 against 15/15 on 2026-08-09, with the gateway regressing the
`koffi` case). Native could not be measured — the `GEMINI_API_KEY` available was rejected — so read
this column as a floor.

### Voxtral is the one to pick if you switch languages

Mistral completes all 16 cases where Deepgram errors on two, and the difference is entirely
Chinese. It transcribes Mandarin correctly *and* keeps the English inside it — `retrieval
pipeline`, `Google`, `storyline` — without being told which language to expect, from the same
request as everything else.

On the 14 cases Deepgram can attempt at all, Deepgram with biasing is the stronger of the two
(27/42 against Voxtral's 18/42). So the choice between them is not about quality in general:

- **English only** → Deepgram with keyterm biasing.
- **Anything bilingual** → Voxtral, or Deepgram pinned with `DNT_DEEPGRAM_LANGUAGE=zh` and no
  English.

Voxtral also has no biasing channel at all, which is measured rather than read off the docs:
`context=` and `prompt=` form fields are both accepted with HTTP 200 and both leave the transcript
byte-identical, token counts included. It is the only recognition backend here that reports audio
tokens, so it is the only one where the silent-drop guard can actually fire.

**Its weakness is numbers, and the harness initially mislabelled it.** On the reference clip the
ablation reports `substituted 100%` — but Voxtral never sees the screen, so it cannot substitute.
The no-context arm scores the same 100%, which is what proves the point: it is *mis-hearing*, not
overwriting. It writes `Gimli 2.5` where the speaker said `Gemini 1.5`, getting both the brand and
the number wrong. For an ungrounded backend that metric measures mishearing, and reading it as
substitution would be a mistake.

### xAI is the one to beat, and it was nearly not measured at all

`grok-stt` with keyterm biasing is the strongest recognition backend here by a wide margin:
**29–30/48 against Deepgram's 27/42 and Voxtral's 21/48**, with no errored cases, at **1.19 s** —
the fastest of everything tested, model providers included.

Biasing is what does it: 16/48 without, 29–30/48 with, and still **0 regressed** across every run.
That is the same shape as the Deepgram result and the same mechanism — `Keyterms` cannot emit a
digit, so the decoy that drives every substitution in this suite has no channel to arrive through.

**The range is not rounding, and it is a finding about this backend.** Three independent runs of
the identical suite gave 30, 30 and 29. An earlier session, before `Keyterms` was repaired, gave
35 — and that number is not reproducible. It is tempting to read the drop as damage from the
repair, and the per-case evidence says otherwise: the two cases that flipped are `git-command` and
`benefit-novel-name`, and

- `git-command` passed *before* with a term list that did **not** contain `--amend`, and fails
  *now* with a list that does. A term that was absent cannot explain the earlier pass.
- `benefit-novel-name` has `Kaelith` in the list in both configurations.

In both failing cases the transcript now equals the ungrounded baseline exactly, meaning the hints
did nothing at all this session, on cases where they demonstrably landed in the last one. So
**xAI's keyterm biasing is not reliable between sessions**: same audio, same terms, different
outcome. The suite's per-pass range cannot see that, because all three passes of one run share a
session. Treat any single-session recogniser number here as ±5 runs.

**This provider spent a day in the tree unverified, and verification immediately found two bugs.**
Both keys available when it was written were rejected, so it was implemented blind to the
specification and shipped with a warning. When a working key arrived, the first live request
failed — and so would every `light` and `tidy` dictation any user made:

- `format=true` is rejected with *"Field 'language' is required when 'format' is true"*. The
  default language was absent, so the default configuration 400'd.
- **Form fields written after the file part are silently ignored** — HTTP 200, no error, options
  simply not applied. Fields-then-file returns `3.5` three runs out of three; file-then-fields
  returns `three point five` three out of three, same request otherwise.

Neither is in the published documentation. `ProviderRegistry` requires new backends be verified
with `dnt-eval probe --audio` before being trusted, and this is what that rule is for. The second
behaviour is now pinned by `testEveryFieldIsWrittenBeforeTheFilePart`, because a reordering that
disabled formatting and biasing would otherwise be invisible in a diff and silent at runtime.

**Its one trade is language against numbers, and the higher-scoring side of it fails this
project's own bar.** An explicit `language` enables inverse text normalisation, so `auto` writes
"three point five" where `en` writes "3.5" — which is why `gemini-version` fails under the default.
Pinning English scores dramatically better:

| xai · keyterms | matched | improved | **regressed** |
|---|---|---|---|
| `language=auto` (default) | 29–30 / 48 | 13–14 | **0** |
| `DNT_XAI_LANGUAGE=en` | **39 / 48** | 18 | **3** |

39/48 is within one run of the model provider's 40/48, at a fifth of the latency. It is still not
the default, because `regressed` is the number this suite exists to report and the bar for it is
zero. The regression is stable — one every pass, never noise — and it is `benefit-novel-repo`:

```
got       Clone quillmark-dash-sync and run the setup script.
baseline  Clone quillmark-sync and run the setup script.
```

The ungrounded run got it right. `quillmark-sync` was supplied as a keyterm, and the bias made the
model spell the hyphen out as the word "dash". **A correct hint produced a wrong transcript.**

### That falsifies something this document claimed two sections ago

The Deepgram result was written up as evidence that keyterm biasing is *structurally* safer than
prompt grounding, because `Keyterms` cannot emit a digit and every substitution in this suite is
driven by a number on screen. The reasoning was right and the conclusion was too broad. The digit
rule makes numeric substitution impossible; it says nothing about a **name** being mangled, and
`quillmark-dash-sync` is a name being mangled by a hint that was itself correct.

The caveat attached to that earlier claim — "it says nothing about names being biased wrongly,
which this corpus does not probe" — turns out to have been the important sentence. The corpus does
probe it, just not in the way expected: the damage did not need a *wrong* spelling on screen, only
a correct one the recogniser rendered differently.

So the honest version is narrower. Keyterm biasing reliably buys a lot (+19 runs on xAI, +9 on
Deepgram) and cannot cause the numeric failure this project is named for. It can still corrupt an
identifier, and does, at roughly 1 run in 16. It stays **off by default** on all backends, and
`auto` stays the xAI default, for the same reason: this project reports `regressed` as the headline
number and does not ship a configuration that raises it.

### What the recogniser buys: about five times the speed

1.33 s against 6.50 s on the same 22-second clip. For dictation that difference is felt directly,
because it is entirely post-release latency — the user has stopped talking and is waiting.

### What it costs: the hard words, which are the ones that matter

Every Deepgram failure is a word a model provider gets right, and they are exactly the words this
project exists to get right:

| said | deepgram wrote |
|---|---|
| `koffi` | `coffee` |
| `git commit --amend` | `git commit dash dash amend` |
| `quillmark-sync` | `Quillmark dash sync` |
| `Kaelith` | `Keyleth` |

`Keyleth` is the same substitution `gemini-3.6-flash` makes, from the same cause: a name the model
already knows displacing one it does not.

### Keyterm biasing: 9 improved, 0 regressed

The result that surprised me. Biasing was expected to reintroduce substitution — it is the
vocabulary prior the README argues against, and it arrives with no way to say "reference only".
Across three passes it fixed nine runs and broke none, stably (3 improved every pass, never a
regression). It resolves all four `benefit-*` cases: `Kaelith`, `Brindlewood`, `quillmark-sync`
and the caret-channel twin.

**The mechanism is the digit rule, and it is structural rather than lucky.** `Keyterms` refuses to
emit any token containing a digit, so the decoy that drives every substitution in this suite — a
version number sitting on screen — cannot reach the biasing channel at all. A prompt cannot make
that guarantee, because a prompt carries the screen text verbatim and has to *ask* the model to
treat numbers as untrustworthy. On this suite the guarantee holds where the request does not:
0 regressions against the model provider's 3.

That is a narrow claim. It says nothing about names being biased wrongly, which the rule does not
prevent and this corpus does not probe — every `benefit-*` case supplies a spelling that is
*correct*. A case where the screen shows the wrong name for what was said would be the honest test,
and it does not exist yet.

**Biasing is free, and the first version of this section said otherwise.** It claimed a ~2 s cost
"because up to 100 terms are sent as repeated query parameters" — a mechanism that was never
measured, only assumed from one pair of `ablate` runs (1.33 s against 3.47 s). Both halves were
wrong:

| test | result |
|---|---|
| term count 0 → 10 → 25 → 50 → 100, fixed upload, 5 runs each | 2.40 / 2.59 / 2.82 / 2.80 / 2.63 s — no trend |
| `ablate` with and without `--keyterms`, 15 trials, run twice | pass 1: 1.63 → 2.34 s · **pass 2: 1.14 → 1.09 s** |

The effect does not reproduce: on the second pass biasing was marginally *faster*. The original
gap was network drift between two sequential runs, and the query-parameter explanation was a
plausible story invented to fit it. **Keyterm biasing has no measurable latency cost.**

It stays **off by default** anyway, and the reason is now purely a principled one rather than a
performance one: it is a vocabulary prior of the kind this project argues against, and the
measurement above cannot see its worst case. Every `benefit-*` case supplies a spelling that is
*correct*; there is no case where the screen shows the wrong name for what was spoken, which is
precisely where a prior would do damage. Until that case exists, 9-improved/0-regressed is
evidence that biasing helps when the screen is right, and no evidence at all about when it is
wrong.

This is the second time in this document a confident mechanism has been recorded before it was
measured, and the second time measurement destroyed it.

### `detect_language` fails by returning success

The largest single improvement here was not the backend, it was one parameter. nova-3's `multi`
scored 18/42 against detection's 12/42, and 27 against 17 with keyterms.

Detection does not merely score worse — it fails in the worst available way. It is a per-request
classification, and a wrong guess produces **HTTP 200 with an empty transcript**:

| clip | `detect_language` | `multi` | `zh` |
|---|---|---|---|
| `real-mandarin` | detected `fr`, empty | empty | full correct transcript |
| `real-brand` | detected `en`, empty — then correct on an identical later call | empty | full correct transcript |
| `real-codeswitch` | `"Okay."` for 20 s of speech | `"Okay."` | full correct transcript |
| `gemini-version` (English) | leading "We" dropped | correct | — |

nova-3 therefore now defaults to `multi`. **No autodetecting setting transcribes Mandarin at all**;
`language=zh` transcribes all three Mandarin fixtures perfectly, so a Chinese-speaking user must
set `DNT_DEEPGRAM_LANGUAGE=zh`. That is a real limitation, not a tuning detail.

The one mercy is that an empty transcript surfaces as `emptyOutput` — a visible failure with a
retry button — rather than as silently missing words.

### Reproducing any of this

```bash
export DEEPGRAM_API_KEY=... XAI_API_KEY=... MISTRAL_API_KEY=...
./eval/benchmark-speech.sh
swift run dnt-eval probe --provider xai --audio eval/audio/gemini-version.wav
```

## The ordinary-dictation corpus — 2026-08-12

Everything above this point is measured on the near-miss suite, which is adversarial by
construction: every case puts a decoy on screen that is almost what was said. That is the right
instrument for measuring substitution and the wrong one for **choosing a default**, which is what
it had quietly become. This corpus exists to answer the other question.

**100 clips, 38.3 minutes, cut from 22 distinct real recordings**, at the lengths people actually
dictate — 30 clips of 3–5 s, 25 of 10 s, 18 of 20 s, 12 of 30 s, 10 of 60 s, 5 of 120 s. The long
tail is kept because it is the only thing that exercises `AudioChunker`'s split-and-stitch path on
real speech. Rebuild it with `eval/build-dictation-corpus.py` (fixed seed, clip for clip); the
audio and manifest stay local, since they are extracts of the maintainer's own recordings.

There is **no ground truth here and none is invented**. Machine-generating one would make every
number circular. What is measurable without it turns out to be what decides a default:

```
                    median (p95) latency          ×realtime   failed
  xai               0.89 s (2.36)                 0.050×      1 / 100
  mistral           1.31 s (3.63)                 0.073×      3 / 100
  deepgram          1.97 s (5.15)                 0.116×     48 / 100
  openrouter        5.66 s (16.93)                0.324×      0 / 100
```

| clip length | xai | mistral | deepgram | openrouter |
|---|---|---|---|---|
| 3 s | 0.52 | 0.79 | 2.61 | 3.56 |
| 10 s | 0.77 | 1.10 | 1.61 | 4.94 |
| 30 s | 1.35 | 1.68 | 2.46 | 9.47 |
| 120 s | 2.83 | 3.42 | 5.15 | **16.93** |

### The finding that decides it

**This corpus is 71% Chinese** — 63% `zh`, 8% `cmn`, 29% `en`, as reported by the backends
themselves. That is not a quirk of sampling; it is what the maintainer's recordings are, which
makes it the real dictation distribution for this user.

**Deepgram failed 48 of 100 clips — 44 of the 68 Chinese ones.** Not "transcribed badly": returned
nothing. Whatever it scores when it works, a backend that silently drops two thirds of one language
cannot be a default for anyone who speaks it. That single number disqualifies the option that the
near-miss suite ranked second.

`xai` is the fastest backend here by a wide margin: fastest at every clip length, `0.050×` realtime,
and 1 failure in 100. The model is 5.5× slower for a grounding benefit measured at **+4 improved
against 3 regressed** on this axis, and at two minutes of speech the gap is 2.8 s against 16.9 s.

**This corpus chose the default for a while, and no longer does.** On latency alone `xai` wins and
it shipped as the default on that basis. What the argument left out is that a recogniser cannot see
the screen at all, so a fresh install had the feature this project exists for switched off in a way
no setting revealed. The near-miss suite measures that axis directly — 43/48 grounded against
15/48 — and it is the one this repository is about. The default is now `google`; the numbers above
are unchanged and are the honest statement of what it costs. `xai` is one dropdown away for anyone
who wants latency back, which is a real preference and why it is still here.

### Agreement, and a metric bug it caught

Where independent backends produce the same words they are probably right; where they diverge, one
is wrong. That does not say *which*, so it is reported as a **review queue** — the ten clips a human
should actually listen to — rather than as a score.

Mean pairwise word overlap is **68.1%** across 99 clips.

The first version of that number was 29.3%, and it was wrong for the language this corpus is mostly
in. The similarity function split on non-alphanumerics, so an entire Mandarin sentence — written
without spaces — became a single token, and two backends differing by one character scored 0%. The
review queue was therefore ranking clips by *language* rather than by disagreement, and had put 71%
of the corpus at the top of it. Tokenizing CJK per character took the mean from 29.3% to 68.1% and
made the queue mean what it claims.

(`TranscriptDiff.tokenize` splits on whitespace too, and was checked for the same fault. It is
coarse on Han text, but `improved`/`regressed`/`matched` are all computed from `satisfies()` rather
than from the aligner, so no number reported anywhere in this document depends on it. Only the
printed diff detail for a failing case is affected.)

### What this corpus still cannot tell you

Accuracy. Every number here is latency, failure rate or inter-backend agreement — none of it says
whose transcript is *better*, and agreement can be high because two backends share a mistake. The
review queue is the path to that answer, ten clips at a time, and it needs a human with the audio.

## The keyterm extractor was broken, and inspecting it is how that surfaced

`dnt-eval keyterms` prints the spelling hints a screen context would send, for the same reason the
app has a Context Inspector: the biasing list was the one part of a request nobody could read.
Adding it immediately showed that the list being sent was not the list being described.

On the near-miss corpus it was emitting `I'll` (three cases), `koffi.load('libContextHelper.dylib`
and `--author="Li`. On real code-switched Chinese it emitted **one** term — `刚才说的RAG方案`, a
mixed-script blob — and lost `Kubernetes`, `quillmark-sync` and `retrieval` completely.

Five defects, all now fixed and pinned by matching tests in Swift, Kotlin and C#:

| defect | cause | fix |
|---|---|---|
| Latin terms lost inside Chinese | whitespace split; Chinese has no spaces | split on script boundaries |
| `koffi.load('libContextHelper.dylib` | quotes and brackets treated as word characters | they end a term |
| `Compare`, `See` admitted as names | `.` made word-internal for `README.md`, which silently destroyed sentence detection | look-ahead decides |
| `I'll`, `we're` admitted as names | capital mid-sentence | rejected by suffix shape; `O'Brien` survives |
| `--no-edit` qualified, `--author` did not | one is a joined identifier, the other is not | flags qualify explicitly |

**The third one was self-inflicted, introduced while fixing the first.** Moving `.` into the
word-character set to keep `README.md` intact meant a sentence-ending full stop no longer ended a
sentence, so every clause opener became a candidate proper noun. It was caught by re-reading the
output rather than by a test, which is an argument for the inspector rather than against the fix.

**A limitation that remains, stated rather than papered over:** pure Chinese still yields no terms
at all. Identifying a Chinese term needs word segmentation, and emitting an unsegmented clause as
a keyterm would bias the recogniser toward a string nobody said. For a Mandarin-only dictation,
keyterm biasing does nothing — which for this corpus is most of it. It is `screenshotPNG`'s
situation again: the hint channel is narrower than the grounding it stands in for.

## Re-scored under the corrected assertions — 2026-08-13

Everything above was measured through a gate that let one case pass on an empty transcript, and
`real-acronym` asserted nothing about the acronym it was named for. With both fixed, and native
Gemini finally reachable, the picture changes in two places that matter.

| backend | matched | improved | **regressed** | latency (22 s clip) |
|---|---|---|---|---|
| **gemini · native · grounded** | **44 / 48** ×2 | 3–4 | **1** | 5–60 s, bimodal |
| gemini · native · ungrounded | 41–42 / 48 | — | — | — |
| openrouter · same model † | 38–43 / 48 | 4–7 | 2–5 | 6.50 s |
| xai · keyterms | 25–26 / 48 | 13 | **3** | 1.19 s |
| xai · no keyterms | 15 / 48 | 0 | **0** | 1.19 s |

† not re-scored under the corrected gate, so its figures are optimistic relative to native's.
The comparison survives that: native scores higher under a *stricter* gate.

### Native beats the gateway, and it is not close on the number that counts

44/48 twice with **1 regression each**, against 38–43/48 with 2–5. Matched counts are near enough
to argue about; regressions are the number the contract says must be zero, and the gateway triples
them. Both routes stay supported — OpenRouter reaches models Google does not serve — but the
picker now says which is which.

**Native's cost is latency, and it is bimodal rather than slow.** Six sequential requests for the
same three-second clip: 4.9, 61.6, 50.5, 5.8, 5.9, 30.2 s. Thinking is not the cause — thought
tokens are 0 at `thinking_level: minimal`, and `low` returns identical token counts in 35 s. This
looks like account-side queueing rather than model work, so it may not reproduce on a paid key. As
measured here it is unusable for hold-to-talk: a dictation tool that answers in 5 s most of the
time and 60 s sometimes is worse than one that always takes 6.5.

### Keyterm biasing regresses, and the mechanism is the one this project is named for

The earlier "9 improved, 0 regressed" and "20 improved, 0 regressed" results were **artefacts of
the weak gate**. Under the corrected assertions, xAI with biasing regresses **3 runs per suite,
1 every pass, in both independent sessions**. The case is `real-acronym`, and the cause is exact:

```
keyterms sent:  GRPO, PPO          ← both are the on-screen decoys
the speaker said: DAPO

without hints:  ...类似 DAP-DAPo 的方法...     ← passes
with hints:     ...类似 D A D A P O 的方法...  ← fails
```

`Keyterms` faithfully extracted what was on screen, and what was on screen was the wrong acronym
four times over. The digit rule cannot help: `GRPO` contains no digits. **The biasing channel
carried the decoy straight to the recogniser** — insertion and substitution, arriving through the
one mechanism that has no way to say "reference only".

This is the case the earlier write-up said the corpus did not contain. It did; the assertion was
too weak to show it.

**Keyterm biasing should not be used.** It stays in the codebase because it is measurable and off
by default, but the evidence against it is now threefold: it yields nothing for 60% of realistic
screen contexts (73% in Chinese), it cannot see a screenshot, and when it does fire it can hand
the recogniser the very string the user did not say.

### What grounding is worth on native Gemini

41–42/48 ungrounded, 44/48 grounded: **+2 to +3, for 1 regression**. That is a far better trade
than the gateway's +4 for 3, and unlike keyterms it is a genuine net positive. Grounding through
the first-party API earns its place; grounding through a gateway is marginal; keyterm biasing is
negative.

## Verifying by ear — the step only a human can do

Every accuracy figure in this document rests on ground truth, and the ordinary-dictation corpus
has none. `dnt-eval dictation` measures latency, failure rate and cross-backend agreement without
it; none of those say whether a transcript is *right*, and agreement is not correctness, because
two backends can agree on the same mistake.

```bash
./eval/make-review-sheet.py            # → eval/dictation/review.html
open eval/dictation/review.html        # listen, type what you hear, Export
./eval/score-review.py                 # word error rate per backend, per language
```

The sheet orders clips by **worst backend disagreement first**, which is where an ear buys the
most: where independent backends already produced the same words they are probably right, so
listening to those first would spend the scarce resource on the easy cases. Verified text is kept
in `localStorage` as you go and exported as JSON; clips left blank are simply not counted.

**What the agreement numbers already suggest, and cannot establish.** Across 99 clips, only 12%
have backends agreeing to within 95%, and 28% disagree by more than half their words. Split by
language it is 85% mean agreement on English against 60.5% on Chinese, with 3 of 68 Chinese clips
reaching the ≥95% band.

Two caveats keep that from being an error rate. The tokeniser splits CJK per character, so
legitimate variation — particles, homophones, punctuation — is penalised harder in Chinese than
in English, by an unknown amount. And Deepgram drags the pooled figures down: it returns under 40%
of its peers' median length on 25% of clips, and manages 0.12 of the character density on Chinese
that it manages on English.

So the honest position is that ordinary-dictation accuracy is **unmeasured**, the agreement data
is consistent with it being poor on Chinese, and roughly twenty verified clips would settle it.

## Gemini 3.7 Flash — 2026-08-14

Tested through the first-party API as soon as it appeared. It is **worse than 3.6 Flash for this
job**, on both numbers that matter, and it broke the client before it could be measured at all.

### It rejects the thinking level every client here hardcoded

```
'minimal' is not a supported thinking level for this model.
Allowed values are: medium, low, high.
```

Every request failed the moment the model field was changed to it — a total outage produced by a
constant that had been correct since the project started, duplicated across Swift, Kotlin and C#.
The level is now chosen per model family: the cheapest each one accepts, prefix-matched so a point
release inherits its family's floor rather than silently costing thinking tokens on every
dictation. Transcription wants as little thinking as allowed — 3.7 spends 376 thought tokens at
`medium` to produce thirteen tokens of transcript, and thought tokens bill as output.

### Near-miss suite, native, three passes per run

| model | matched | improved | **regressed** | ungrounded |
|---|---|---|---|---|
| `gemini-3.6-flash` | **44 / 48** ×2 | 3–4 | **1** | 41–42 |
| `gemini-3.7-flash` | 40, 41 / 48 | 5–6 | **1–2** | 36–37 |

A third 3.7 run was discarded: a local network outage killed 22 of its 48 requests
(*"The Internet connection appears to be offline"*), which is a fault in the measurement rather
than the model.

The gap is about four matched runs, outside the per-pass range, and it is wider on the ungrounded
column — 36–37 against 41–42. That is the more diagnostic number, because it is the model's own
hearing with nothing on screen to blame.

### It cannot hear the reference version number

On `real-talk-gemini15.wav`, where the speaker says "Gemini 1.5" and the screen insists on 2.5:

| model | grounded | **no context at all** |
|---|---|---|
| `gemini-3.6-flash` | 8% substituted | 30% |
| `gemini-3.7-flash` | **100%** (10/10) | **82%** (9/11) |

The second column is the damning one. With no screen context there is no decoy to copy, so 82%
is not substitution — it is **mishearing**. 3.7 writes 2.5 for a spoken 1.5 most of the time on
its own, and grounding then adds the rest. 3.6 hears the same clip correctly 70% of the time
unaided.

This is the same distinction that had to be drawn for Voxtral: for a backend that never saw the
screen, the "substituted" column measures hearing, not overwriting. Reading it as substitution
would blame grounding for a problem that precedes it.

**It is not the thinking level.** The obvious suspicion is that `low` — forced, since 3.7 rejects
`minimal` — starves it. Raising the level makes it worse, not better: at `high` the clip comes back
wrong in **every** trial, 6/6 grounded and 7/7 ungrounded, at 27 s a request. Whatever 3.7 is doing
with the extra tokens, it is not listening harder.

(`dnt-eval ablate --thinking high` exists for exactly this question. The flag was added here
because the comment claiming the constraint was measurable had never been true.)

### Verdict

At this point `gemini-3.6-flash` stayed the recommended model. 3.7 is available — the model field is free text on
every platform — but on this corpus it is less accurate, regresses more, and gets the one number
this project is named for wrong four times out of five with no context at all.

### The rest of the Flash family, for context — 2026-08-14

3.7 being worse than 3.6 raised the obvious question: is 3.6 the outlier, or is 3.7 a regression?
Both neighbours measured, same suite, two runs each.

| model | matched | improved | **regressed** | ungrounded | ref-clip: grounded / **no context** | latency |
|---|---|---|---|---|---|---|
| **`gemini-3.6-flash`** | **44, 44** | 3–4 | **1, 1** | **42, 41** | 8% / **30%** | 5–60 s, bimodal |
| `gemini-3.7-flash` | 40, 41 | 5–6 | 2, 1 | 37, 36 | 100% / **82%** | 10.5 s |
| `gemini-3-flash-preview` | 37, 36 | 5, 3 | **5, 4** | 32, 33 | 14% / **18%** | **2.2 s** |
| `gemini-3.5-flash` | 31, 35 | 5, 7 | 1, 1 | 27, 28 | 75% / **83%** | 3–6 s |

**3.6 is genuinely the best of the four, not an artefact of one clip.** It leads on matched by
3–4 runs over the next model and by 9–13 over the worst, and it leads on the ungrounded column by
more. 3.7 is a regression from it rather than 3.6 being a fluke — but 3.5 is worse still, so the
family did not simply peak and decline.

**`gemini-3-flash-preview` is a trap worth naming.** It has the lowest substitution rate on the
reference clip (14%/18%) and is by far the fastest at 2.2 s, which reads like the obvious choice
until you look at why. Five of its twelve grounded trials were *unjudgeable*: the transcript
contained neither the spoken number nor the decoy, because it had garbled the sentence into
"unified sauce" and "G-5 sauce". A low substitution rate is cheap when the model never produces
the contested token. Its regressions — 4 and 5 per run, the worst here — say the same thing from
the other side.

That is the same reading error the Voxtral and 3.7 rows required, in a third disguise: the
substitution column is only meaningful once you know the model can hear the sentence at all.

### How the fixtures were made, and how to check them

Five of the sixteen cases are **macOS `say` speaking a script** (`eval/make-audio.sh`, voice
Samantha), and their goldens are exact by construction — the text was written first, then
synthesised. That includes the deliberate traps: `jargon-spelling` is synthesised saying
*"koffee"* while the golden demands `koffi`, and `git-command` is synthesised saying *"dash dash
amend"* while the golden demands `--amend`. The script says plainly that these are smoke tests,
because `say` enunciates far more cleanly than a person and substitution needs ambiguity.

The `benefit-*` cases are synthesised too, on purpose: they contain invented tokens (`Kaelith`,
`Brindlewood`, `quillmark-sync`) that appear in no corpus, and an unknown name is equally unknown
however clearly it is spoken.

The seven `real-*` cases are extracts of real recorded speech, and their goldens were written down
by a human listening. Those are the ones worth an ear, and they can be checked:

```bash
./eval/make-review-sheet.py --fixtures     # → eval/dictation/fixtures.html
```

which plays each fixture beside the ground truth it asserts, marked by origin.

## Two corrections to the native-Gemini figures — 2026-08-14

Re-measuring before recommending anything found that both numbers published for
`gemini-3.6-flash` came from an unrepresentative window.

**Latency is not 5–60 s bimodal, and it is not throttling.** Spacing requests 25 s apart does not
help — back-to-back gives a 9.56 s median against 8.30 s spaced, and the API returns no quota or
retry headers at all. On the 22-second reference clip it now measures **13.9 s grounded and 17.4 s
ungrounded**, against the 35.75 s published earlier. The 61 s and 50 s outliers recorded on
2026-08-13 were server-side load at that moment, not a property of the account or the API.

The practical consequence is smaller than it sounds: ~14 s is still an order of magnitude worse
than a recogniser's 0.9 s, so the fallback still earns its place. But "sometimes 60 seconds" was
alarmism built on one bad afternoon, and the default hedge delay was chosen against it.

**The reference-clip substitution rate does not replicate between sessions.**

| session | grounded | no context |
|---|---|---|
| 2026-08-13 | 1/12 (8%) | 3/10 (30%) |
| 2026-08-14 | 2/11 (18%) | **0/11 (0%)** |

The two sessions disagree about the *direction*: one has grounding halving the error, the other has
it introducing the only errors there are. With n≈11 and that spread, **this clip cannot support a
claim either way for 3.6**, and the earlier statement that it "hears the clip correctly 70% of the
time unaided" should have been 70–100%.

What survives is the cross-model comparison, because 3.7's 82–100% sits far outside 3.6's 0–30%
range in every session. Comparisons between models measured in the same session hold; absolute
rates from a single session do not.

**The general lesson, which this document keeps relearning:** a 10–12 trial ablation is a
screening tool, not a measurement. It is sharp enough to separate models that differ by 60 points
and useless for anything that differs by 10.

## Keyterm biasing is no longer offered — 2026-08-14

The toggle is gone from macOS, Windows and Android. The setting and the code remain, so `dnt-eval`
can keep measuring it and the finding stays reproducible, but nothing in the product invites
someone to turn it on.

The evidence had accumulated to the point where shipping a switch for it was indefensible:

- It **regresses 3 runs per suite**, stably, in both sessions measured. On `real-acronym` the terms
  it extracts are `GRPO, PPO` — both decoys on screen — while the speaker said `DAPO`.
- It yields **nothing for 60% of realistic screen contexts**, and 73% in Chinese.
- It yields **nothing at all** from a screenshot, which is exactly the surface where the
  accessibility tree came back thin.

A feature that helps on a synthetic suite, does nothing most of the time in practice, and actively
feeds the on-screen decoy to the recogniser is not a feature. Keeping the toggle while the help
text read "not recommended" was having it both ways.

## Replicated in a third session, and recorded — 2026-08-14

The two configurations that actually ship were re-run from scratch on a different day, and both
recorded so the numbers can be re-checked without a key or a bill.

| configuration | this session | previously | verdict |
|---|---|---|---|
| **xai · grok-stt** | **15 / 48**, 0 regressed | 15 / 48 | replicates exactly |
| **google · native · 3.6-flash · grounded** (default at measurement time) | **43 / 48**, 2 regressed | 44 / 48 ×2, 1 regressed | within the noise floor |

```bash
swift run dnt-eval suite eval/nearmiss --provider xai --model grok-stt \
  --replay eval/cassettes/xai-grok-stt.json
```

Both replay offline with the API key unset and reproduce the counts above. That is the standard
[RELEASING.md](RELEASING.md) now holds any number to before it is quoted publicly: two independent
sessions, not two passes of one run.

**What the cassette is and is not.** A take is keyed by a hash of the request — audio included —
so replay needs the clips, and `eval/audio/*.wav` is gitignored because the `real-*` cases are cut
from the maintainer's own recordings. Someone who clones this repository cannot re-run these files.
What they get is every answer the provider gave, in readable form, next to the score derived from
it: enough to check the arithmetic and disagree with the grading, not enough to reproduce the
request. For anyone holding the audio the cassette is a full offline re-run, and it pins the
scoring against silent drift — a change in how a pass is counted now shows up without re-billing
48 requests.

Gemini's two regressions are the same pair the suite already flags as non-deterministic across
passes — `real-version-number` and `real-acronym`, both long-form real speech where the model
re-segments Mandarin differently each time. Neither is a context failure; the ungrounded arm gets
them wrong too.

### A number in the README was wrong, and this is how it got there

The README described xAI as scoring **29–30/48**. Both halves of that had expired:

- The figure was measured **with keyterm biasing**, which [was withdrawn from the
  product](#keyterm-biasing-is-no-longer-offered--2026-08-14) the same week. No shipping
  configuration can reach it.
- It predates the [corrected assertions](#re-scored-under-the-corrected-assertions--2026-08-13),
  which re-scored the same biased configuration down to 25–26/48 anyway.

The honest number for what a new install actually runs is **15/48**, and the README now says so —
alongside why that backend is still the default, which is a decision made on the ordinary-dictation
corpus for latency and Chinese coverage, not on this suite.

**The corrections in this document were each made against a number nobody had yet relied on. This
one had been sitting in the front page of the repository.** Retracting a figure inside an
evaluation write-up is cheap; the summary that quotes it is where the cost lands, and nothing in
the process was checking that the two still agreed. The release checklist now does.

## Technical-dictation sweep changes the default — 2026-08-17

Seven retained DoNotType recordings, 5m48s total, were transcribed through the current provider
paths without screen context. They include the terms Grok 4, Grok STT, DoNotType, VS Code
Remote-SSH, JetBrains Gateway, DeepSeek Harness, TUN, HTTP proxy, Clash Verge, a Git command,
RTX-PRO, middleware, throughput, and Mandarin/English code-switching.

There are **no human transcripts for these clips**. Existing history text was treated as another
hypothesis, never as a reference. The comparison can therefore report obvious canonical spellings,
truncation, hallucination and latency, but not WER or an accuracy winner.

| model | median per clip | qualitative result |
|---|---:|---|
| `gemini-3.5-flash` | **2.54 s** | retained the broadest set of current names and commands; still wrote `Groq 4` and likely `preview binary` |
| `gemini-3.6-flash` | 10.54 s | no consistent gain; the request clip produced `Grok-1`, `Grok-STD`, and “current pipe application” |
| `grok-stt` | **1.46 s** | fastest hosted baseline; likely misses included `GraphR-4`, `JetBrains Gate`, `RTX Dash Pro`, and `middle wear` |
| `voxtral-mini-latest` | 1.97 s | strong on several names, mixed on Clash Verge, the Git command, and middleware |

The product default is now `gemini-3.5-flash` through Google, with
`google/gemini-3.5-flash` as OpenRouter's default model. This prioritises the current
jargon-heavy workload and lower observed latency. It does not overwrite the older golden finding:
3.6 remains the measured leader on the adversarial near-miss suite. A human-corrected corpus is
required before the newer result can be described as an accuracy improvement.
