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

## Current numbers

**The suite is red, and that is correct.** With real-speech cases added it reports what the
synthesized-only version could not:

```
runs             14  (11 matched ground truth)
improved          0
neutral-correct  11
REGRESSED         3   ← must be 0
```

Two of the three regressions are the same clip on consecutive runs:

```
real-version-number:
  baseline  … the smaller models including Gemini 1.5     ← correct
  context   … the smaller models, including Gemini 2.5    ← the screen's value
```

The third is `jargon-spelling`, and it failed in an instructive direction. It was written as a
*positive* control — the audio sounds like "coffee", the screen spells it `koffi`, and context
should fix the spelling. Instead the baseline got `Koffi` right on its own and context turned it
into `Coffee`. A case intended to demonstrate the feature working demonstrated the bug instead.

**The synthesized-only suite reported 0 regressions**, and that number was not evidence: `say`
enunciates far more clearly than a person, and the model's own knowledge covers well-known terms —
a control saying "cuber netties" came back as "Kubernetes" with *no context at all*, measuring
nothing. Real cases changed the result immediately.

**Real speech** (`eval/audio/real-talk-gemini15.wav`, extracted from a recorded talk; the speaker
says "Gemini 1.5", the screen says "2.5"; 20 trials):

| | count |
|---|---|
| correct (1.5) | 8 |
| **substituted (2.5)** | **11** |
| no version mentioned | 1 |

**58% substitution.** The bug reproduces on real audio and never reproduced on synthesized audio.

Real-speech cases assert **fragments** rather than an exact transcript (`mustContain`,
`mustNotContain`). A 22-second clip transcribed by a stochastic model differs run to run on wording
the suite is not measuring — "observed" versus "observe", "unified source" versus "unified
thoughts" — so an exact-match assertion would fail for reasons unrelated to grounding. Name the few
tokens the case turns on and ignore the rest.

**The control matters more than the headline.** With *no context at all*, the model still writes
2.5 in 21% of runs — this clip is genuinely hard, the number is unstressed and mid-sentence. So the
honest claim is that grounding roughly **doubles an already non-zero error rate**, from ~21% to
~36%, not that it creates it.

## Ablation

`swift run dnt-eval ablate`, 15 trials per condition:

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
