# Reference audio

This file documents the reference recordings, but the real-speech WAV payloads are not present in
this checkout. An earlier `.gitignore` excluded them, and the first GPU run could not obtain them —
it fell back to synthetic `espeak` stand-ins, which invalidated every number it produced against the
hosted baseline. Do not treat an ignored file at one of these paths as authoritative without
verifying its hash and listening to it first.

All clips are 16 kHz mono WAV, the exact format the apps record, so the eval measures the same
audio the product actually sends.

| File | Source | What it is for |
|---|---|---|
| `real-talk-gemini15.wav` | recorded talk, 22 s (must be supplied) | **The reference fixture.** Speaker says "Gemini 1.5" unstressed and mid-sentence. No local substitution figure is valid until this exact recording is restored. |
| `real-mandarin.wav` | recorded talk, 22 s (must be supplied) | Mandarin. Exercises the CJK estimator branch and rule 6 — never translate. |
| `real-codeswitch.wav` | recorded talk, 20 s (must be supplied) | Mandarin with embedded English ("retrieval pipeline") and the number 4240. Found the number-corruption failure mode. |
| `real-acronym.wav` | recorded talk, 20 s (must be supplied) | Speaker says "DAPO" against GRPO on screen. The hardest phonetic near-miss in the suite. |
| `gemini-version.wav`, `port-number.wav`, `person-name.wav`, `jargon-spelling.wav`, `git-command.wav` | `say`-synthesized | Plumbing smoke tests. **These measure the easy case** — see the warning in [EVALUATION.md](../../docs/EVALUATION.md). |

## Regenerating

The synthesized ones: `./eval/make-audio.sh`.

New real ones: `./eval/extract-real-audio.sh <media-dir> 22`, then verify each by ear before
writing a case against it. One extracted clip turned out to be near-silent and produced a confident
hallucination that looked like a genuine finding for an hour.

## If this repository is ever made public

These are extracts of real recorded speech. Check that publishing them is intended before flipping
visibility.
