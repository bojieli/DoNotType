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

`dnt-eval` reads `PROMPT.md`, so `--prompt path/to/custom.md` measures an edited prompt. If you
change the prompt in the app, the numbers below stop applying to you — re-measure.

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

**The one that fails is the most informative.** `Brindlewood` and `quillmark-sync` transfer 3/3.
`Kaelith` does not: it comes back as **`Keyleth`** — a name the model already knows — even with the
correct spelling on screen three times. The no-context baseline says `Kileth`, so context moved the
answer, just to the wrong place: toward a token in its own vocabulary rather than the one on screen.

That is the project's founding complaint one level down. The original objection to Typeless was a
*user dictionary* overriding the speaker; this is the *model's* dictionary doing the same thing, and
no amount of screen text dislodges it. Case 13 is kept as a failing case rather than deleted,
because it marks the honest boundary of what grounding currently does.

**What this does not settle.** The benefit cases are synthesized, so they measure spelling transfer
rather than transfer under ambiguous human speech. The one remaining regression is still numeric
(`1.5` → `2.5`), which is what the optional digit guard exists for.

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
| `gemini-3.6-flash` | "Gemini 1.5" | correct — the default |
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
   and on silence the inline path hallucinated "hello testing" while the pre-upload path returned
   empty. That looked like a route difference and was not.
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
