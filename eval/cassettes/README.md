# Cassettes

One paid run of the suite, written down, so it can be re-scored for free.

Every number this project publishes comes from a paid run on one machine in one voice. That makes
the central claims unreproducible for anybody else: a contributor cannot check them, CI cannot
regress-test them, and a reviewer asked for numbers has to spend money to produce any. For a project
whose argument is "measure it", that is the wrong shape.

## Recording one

Costs an ordinary suite run — the same requests, the same money — and then never again:

```bash
swift run dnt-eval suite --record eval/cassettes/nearmiss.json --repeat-count 3
git add eval/cassettes/nearmiss.json
```

Record with at least as many passes as anyone will replay with. Each pass is a separate take, and
replaying more passes than were recorded reuses the last one — which narrows the per-pass spread.
The harness says so when it happens rather than letting the spread quietly shrink.

## Replaying

```bash
swift run dnt-eval suite --replay eval/cassettes/nearmiss.json
```

No key, no network, no cost. CI does this on every push once a cassette exists.

## What a replayed run is and is not

**It is** a check that the scoring, the diff classification, the pass/fail thresholds and the prompt
still turn the same answers into the same verdicts. That catches a real class of regression: a
change to `TranscriptDiff`, to the fidelity clauses, or to the way a case is judged.

**It is not** new evidence about a model, and must never be written into `PROMPT.md`'s changelog as
a fresh measurement. Replaying a recording twice cannot discover anything; it can only tell you the
harness is consistent.

**It cannot answer for a prompt that did not produce it.** The system instruction is part of the
request key, so editing `PROMPT.md` misses every take and the run fails with a message saying to
re-record. That is the one way a cache like this could actively mislead, and it is closed.

## Reading the file

Sorted keys, pretty printed, one entry per request with every take in the order it was recorded. The
`provenance` block carries the backend, the model, the fidelity, when it was recorded and a digest
of the prompt, so a stale cassette is visible in a diff rather than only at replay time.
