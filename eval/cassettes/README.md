# Cassettes

A cassette is one paid run of the evaluation suite, written down, so that the run can be re-scored
for free. This document explains the rationale for cassettes, how to record and replay them, what a
replayed run does and does not establish, and the on-disk format.

A cassette needs the audio to replay, and this repository does not ship it — see [It still needs
the audio](#what-a-replayed-run-is-and-is-not). The half of the job that works without the clips
lives in [`eval/scorecards/`](../scorecards/README.md), and that is what CI runs.

## Rationale

Every number this project publishes comes from a paid run on one machine in one voice. That makes
the central claims unreproducible for anybody else: a contributor cannot check them, CI cannot
regress-test them, and a reviewer asked for numbers has to spend money to produce any. For a
project whose rule is "measure it", unreproducible numbers are not usable evidence.

## Recording a cassette

Recording costs an ordinary suite run — the same requests, the same money — and then never again:

```bash
swift run dnt-eval suite eval/nearmiss --provider google --model gemini-3.6-flash \
  --fidelity light --repeat-count 3 \
  --record eval/cassettes/gemini-3.6-flash.json \
  --scorecard eval/scorecards/google-gemini-3.6-flash.json
git add eval/cassettes/gemini-3.6-flash.json eval/scorecards/google-gemini-3.6-flash.json
```

Record both in the same run. They are the two halves of it: the cassette can re-run the whole
harness for anyone holding the clips, and the scorecard can re-grade the answers for everyone
else. One paid run, and no reason to choose.

Record with at least as many passes as anyone will replay with. Each pass is a separate take, and
replaying more passes than were recorded reuses the last one — which narrows the per-pass spread.
The harness reports take reuse when it happens; otherwise the apparent spread would shrink without
being visible in the results.

## Replaying a cassette

```bash
swift run dnt-eval suite eval/nearmiss --provider google --model gemini-3.6-flash \
  --fidelity light --replay eval/cassettes/gemini-3.6-flash.json
```

Replay needs no key, no network, and no cost — but it does need the clips, so it is a maintainer's
tool rather than CI's. Name the same provider, model and fidelity the cassette was recorded with;
all three are part of every request key, and a mismatch is refused up front rather than reported as
one missing take per request.

## What a replayed run is and is not

**It is** a check that the scoring, the diff classification, the pass/fail thresholds and the
prompt still turn the same answers into the same verdicts. That catches a real class of regression:
a change to `TranscriptDiff`, to the fidelity clauses, or to the way a case is judged.

**It is not** new evidence about a model, and must never be written into
[`PROMPT.md`](../../docs/PROMPT.md)'s changelog as a fresh measurement. Replaying a recording
twice cannot discover anything; it can only tell you the harness is consistent.

**It still needs the audio.** A take is keyed by a hash of the whole request, the clip included,
and `eval/audio/*.wav` is gitignored — the `real-*` cases are cut from the maintainer's own
recordings. So a fresh clone cannot replay these files, and the opening claim above is only half
kept: a contributor gets every answer the provider gave, in readable form, next to the verdict
drawn from it. That is enough to audit the grading, but not enough to re-run the request. Closing
the other half means shipping clips that are somebody's actual speech, which is a trade this
project has so far declined.

**It cannot answer for a prompt that did not produce it.** The system instruction is part of the
request key, so editing any part in `prompt/` misses every take. That is the one way a cache like
this could actively mislead, and it is closed — but it took two goes to close properly. The
mismatch used to surface one "nothing recorded" error per request, 48 of them for a single fact,
and the suite printed them and exited 0. Both halves are fixed: the provenance is compared when the
file opens, so a stale cassette is one message before any case runs, and a suite that could not
complete every run now fails.

## Cassette file format

Sorted keys, pretty printed, one entry per request with every take in the order it was recorded.
The `provenance` block carries the backend, the model, the fidelity, when it was recorded and a
digest of the prompt, so a stale cassette is visible in a diff rather than only at replay time.

## See also

- [`eval/scorecards/`](../scorecards/README.md) — the same run's answers without the audio, which
  is what CI re-grades

- [PROMPT.md](../../docs/PROMPT.md) — the prompt design rationale and its changelog of measurements
