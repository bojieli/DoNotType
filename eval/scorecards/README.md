# Scorecards

A scorecard is every transcript one paid suite run produced, plus the verdict it reached, with the
audio left out. `dnt-eval rescore` grades them again and fails if any count moved. It needs no key,
no network, no clips and no money, so it is the one eval check CI can actually run.

## Why this exists when cassettes already do

A [cassette](../cassettes/README.md) records the same run more completely: it keys each answer by a
hash of the whole request and can re-run the harness end to end. But the audio is part of that hash,
and `eval/audio/*.wav` is gitignored — seven of the sixteen near-miss clips are cut from the
maintainer's own recordings. So no runner and no contributor has ever been able to replay one, and
the CI job that claimed to was checking nothing.

It failed quietly, in two layers. It looked for `eval/cassettes/nearmiss.json`, a filename never
committed, and skipped itself when it was absent — and a skipped step is the same colour as a
passing one. Pointed at a cassette that does exist, it found no take for any of the 48 requests,
printed five of the errors, truncated each to 120 characters, and exited 0.

A scorecard drops the request and keeps the answers. That is enough to rebuild every outcome and
re-run the part of this project that is ours: the assertions in `eval/nearmiss/`, the diff
classification, the pass rule, the effect table. Anyone can check it, in seconds.

## Re-scoring

```bash
swift run dnt-eval rescore
```

Every scorecard in this directory, or name one. There is no "if a scorecard exists" branch: the
corpus is committed, and a check that decides for itself whether to check anything is how the last
one stayed green.

## Recording one

A scorecard is a by-product of a suite run — see [recording a
cassette](../cassettes/README.md#recording-a-cassette), which writes both at once.

## What re-scoring is and is not

**It is** a check that this project still grades the same transcripts the same way. A change to
`TranscriptDiff`, to a case's assertions, to the pass rule or to the effect table shows up as a
changed count, named.

**It is not** evidence about a model — neither is a cassette replay. The transcripts are stored.
The counts in a scorecard are the counts from the paid run that produced them, quotable only as
that run, and never as a fresh measurement in [`PROMPT.md`](../../docs/PROMPT.md)'s changelog.

**It is not the suite's gate.** `rescore` answers "is the scoring unchanged", which is a different
question from "did the run pass". `google-gemini-3.6-flash.json` reproduces exactly and records
three regressed runs; the suite requires zero. `rescore` says so rather than letting a tick imply
otherwise.

**A renamed case is refused, not skipped.** Stored answers were graded against assertions that no
longer exist, so they cannot be re-graded — and scoring them against a different case would produce
a number with nothing behind it. Re-record instead.

## See also

- [`eval/cassettes/`](../cassettes/README.md) — the same runs with the request keys, replayable by
  anyone holding the clips
- [docs/EVALUATION.md](../../docs/EVALUATION.md) — what the numbers mean
