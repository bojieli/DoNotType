# PROMPT.md

The transcription contract. The text itself **is** the product — every platform sends the same
words — and it lives in [`prompt/`](prompt/), one part per file. This document is the argument for
that text: why each rule is worded the way it is, what was measured, and which of my predictions
about it turned out to be wrong.

Nothing in this file is sent to a model. It used to be: the live blocks sat here between
`<!-- BEGIN SYSTEM -->` markers and the loader sliced them out, which meant a parser had to tell
prose from payload by convention. It got that wrong for as long as the markers existed — the
sentence above quotes one, and a first-match substring search picked the quote over the real thing,
so every request carried eight lines of this file's own documentation ahead of rule 1. Parts are
whole files now. There is no annotation to skip and nothing to mis-match.

## The parts

| Part | File | Placeholder |
|---|---|---|
| Transcription contract | [`prompt/system.md`](prompt/system.md) | `{{FIDELITY_RULE}}` |
| Rewrite stage | [`prompt/rewrite.md`](prompt/rewrite.md) | `{{STYLE_RULE}}` |
| Summary stage | [`prompt/summary.md`](prompt/summary.md) | `{{SUMMARY_RULE}}` |
| Fidelity clauses | [`prompt/fidelity/`](prompt/fidelity/) — `raw`, `light`, `tidy` | — |
| Rewrite styles | [`prompt/style/`](prompt/style/) — `formal`, `concise`, `bullets` | — |
| Summary styles | [`prompt/summary-style/`](prompt/summary-style/) — `brief`, `bullets`, `actions` | — |

Two rules govern the whole directory:

1. **A part file is sent in full.** No markers, no fences, no comments — if it is in the file it
   reaches the model, so anything you would not say to the model does not belong there.
2. **A clause is one paragraph.** The three clause directories hold text that is substituted into a
   numbered list item, so hard wraps in them are joined with a single space on load. Nothing else
   is transformed.

Each part can be edited on its own, in the app's Prompt tab or by hand, and restored on its own.
Editing one does not freeze the others at the version you edited — which is what the old
single-file override did, and why a prompt customised before summaries existed used to break the
summary stage outright.

Changes to any part require re-running `swift run dnt-eval suite eval/nearmiss` and recording the
new numbers in the changelog at the bottom.

## The rewrite stage

Optional, and off by default. The raw transcript is always produced first and always stored, so
whatever the rewrite does, what you actually said is recoverable. That is the part Typeless got
wrong — not that rewriting exists, but that it is mandatory and discards the original.

**Whether to rewrite in one request or two is an open question, and the obvious answer is wrong.**

The argument for two passes is that a model asked to polish prose normalises unfamiliar tokens
toward familiar ones, so combining "transcribe" with "make it formal" puts the objectives in
competition. That argument is plausible and it does not survive measurement
(`swift run dnt-eval ablate`, 15 trials per condition, gemini-3.6-flash):

| condition | substituted | rate | mean latency |
|---|---|---|---|
| no context at all | 3/14 | 21% | 5.7 s |
| verbatim + context | 4/11 | 36% | 5.5 s |
| single request, transcribe + formalise | 5/13 | **38%** | 15.7 s |
| two requests, transcribe then formalise | 9/12 | **75%** | 7.5 s |

Two passes was **twice as bad**, not better. The likely mechanism is the opposite of the one
predicted: a rewriter handed "Gemini 1.5" applies its own world knowledge and "corrects" a version
number it believes is stale. It never sees the screen context, so nothing tells it the number came
from audio and is not its to fix — which is why rule 2 of [`prompt/rewrite.md`](prompt/rewrite.md)
exists, and why it is evidently not enough.

Latency also went the other way. The single request was *slower* (15.7 s), because one call doing
both jobs emits far more output than two specialised ones.

Neither option is recommended yet. Both are implemented and both are measured; the numbers are
here so the choice is made on evidence rather than on the mechanism story, which was wrong twice.

## The summary stage

Also optional, also off by default, and deliberately **not** a rewrite style.

Rule 1 of [`prompt/rewrite.md`](prompt/rewrite.md) — never remove a fact — is the rule this project
exists to enforce. A summary is defined by removing facts. Putting it in `prompt/style/` alongside
`formal` and `concise` would mean one file there is quietly exempt from the block's first rule, and
the exemption would be invisible at the call site. So it gets its own part, its own directory of
styles, and its own type (`SummaryStyle`), and nothing that asks for a rewrite can reach it.

The invariant that makes this safe is the same one that makes rewriting safe: **the verbatim
transcript is produced first and stored first**. A summary is a derived artifact sitting next to
the words that produced it, never instead of them.

Two things follow, and both are deliberate:

- **`dnt-eval rewrite` does not measure this stage.** That harness scores content preservation, and
  a summary scoring 0% loss would mean it had failed to summarise. There is no honest way to run
  the same check here, so it is not run and no number is claimed.
- **Nothing in the changelog below applies to it.** The measured numbers describe transcription
  under screen context. Summarisation is a text-to-text pass with no audio and no screen, so it
  neither affects nor is described by them.

## Fidelity clauses

Exactly one of [`prompt/fidelity/`](prompt/fidelity/) is substituted into `{{FIDELITY_RULE}}` per
request. This is the dial that separates DoNotType from a rewriting tool: even `tidy` may change
typography and never words. `light` is the default.

## Changelog

Measured with `swift run dnt-eval suite eval/nearmiss --repeat-count 3`.

The headline number is **regressed**: cases where the no-context baseline was correct and adding
screen context broke it. That is the failure this contract exists to prevent, and it must be 0.

| Date | Change | Provider / model | runs | matched | improved | regressed |
|------|--------|------------------|------|---------|----------|-----------|
| 2026-08-09 | Initial contract | **gemini** · gemini-3.6-flash | 15 | 15 | 0 | **0** |
| 2026-08-09 | Initial contract | openrouter · google/gemini-3.6-flash | 15 | 12 | 0 | 1 |

Notes on the first measurement:

- **Rule 4 held under hostile cases.** `01-gemini-version` puts "Gemini 3 Flash" on screen five
  times against audio saying "three point five", and the transcript kept 3.5 in every run. Same for
  a port number one digit off a terminal buffer, a name against a thread naming only someone else,
  and a command whose scrollback showed extra flags.
- **The same model ID behaves differently through a gateway.** Native Gemini passed 15/15;
  OpenRouter passed 12/15 and produced the one regression, turning a correct `koffi` baseline into
  `Coffee`. Native is now the default. Keep both in the changelog — a provider difference this size
  is worth noticing before it is attributed to a prompt change.
- **One run is an anecdote.** An early single-pass run of the same suite reported 0 regressions and
  a later one reported 2, purely from baseline instability on the ambiguous case. `--repeat-count`
  defaults to 3 for this reason.
- **The audio is still the weak point.** `say` enunciates far more clearly than a person, and the
  model's own knowledge covers well-known terms: a control using "cuber netties" was transcribed as
  "Kubernetes" with *no context at all*, so it measured nothing. Until the suite uses real speech
  and identifiers the model cannot already know, treat `regressed 0` as necessary but not
  sufficient.

### 2026-08-09 — rule 4 fails intermittently on real speech

The caveat above turned out to be the important part. Once the suite moved to real recorded
speech, the substitution this contract exists to prevent **reproduced**.

The clip (`eval/audio/real-talk-gemini15.wav`, extracted from a real talk) says "Gemini 1.5". Given
screen context repeating "Gemini 2.5" five times, an integration run produced **2.5** — a version
number the speaker never said.

It is intermittent, not systematic: the no-context baseline says 1.5 every time, and repeated runs
*with* the hostile context mostly also say 1.5. But "mostly" is the finding. On synthesized audio
this never happened at all, which is exactly why the TTS suite could not be trusted.

What this means, stated plainly:

- **`regressed 0` on the synthesized suite is not evidence the rule holds.** Only real, slightly
  ambiguous speech exercises the failure.
- **A single run proves nothing in either direction.** `--repeat-count` defaults to 3 and should
  probably be higher for cases like this one.
- **The prompt is not yet sufficient on its own.** Options not yet tried: stating rule 4 twice
  (once before the context block and once after), moving the numbers clause into the closing line
  that follows the context, or lowering the visible-text budget so a repeated wrong string carries
  less weight.

The failing case is kept in the integration suite deliberately. It is the only test in the project
that has ever caught the bug the project is about.

### 2026-08-10 — the caret window carries the weight

Two prompt-adjacent findings, both from moving text between sections without changing a word of it.

| where the correct spelling of a novel name sits | transcribed correctly |
|---|---|
| visible text | 0 / 12 |
| text before caret | 12 / 12 |

| where a contradicting value sits | substituted for what was spoken |
|---|---|
| visible text | 3 / 10 |
| text before caret | 7 / 10 |

The caret sections are a tenth of the visible-text budget and dominate it in both directions.

**A third prediction of mine, falsified.** I had recorded that a novel name losing to a name the
model already knows (`Kaelith` → `Keyleth`) showed the model's own vocabulary was immovable —
that *"no amount of screen text dislodges it"*. It dislodges completely when the same text is
placed near the caret. The correction had never been given a fair hearing; nothing about the
model's priors was demonstrated. Prompt work aimed at overpowering a "learned token" would have
been aimed at a phantom.

The practical warning this leaves: dictating a correction into a field that already contains the
wrong value is the worst case for substitution, and that is exactly when people dictate
corrections.

### 2026-08-09 — measured, and two predictions falsified

`swift run dnt-eval ablate`, 15 trials per condition, `gemini-3.6-flash`, on the real clip:

| condition | substituted | rate | mean latency |
|---|---|---|---|
| no context at all | 3/14 | 21% | 5.7 s |
| verbatim + context | 4/11 | 36% | 5.5 s |
| single request, transcribe + formalise | 5/13 | 38% | 15.7 s |
| two requests, transcribe then formalise | 9/12 | 75% | 7.5 s |

**Read the first row before anything else.** With *no context at all*, the model still wrote 2.5
in 21% of runs. This clip's audio is genuinely hard — the speaker is mid-sentence and the number
is unstressed. So the honest claim is not "grounding causes a 58% failure"; it is that grounding
roughly **doubles an error rate that is already non-zero**, from ~21% to ~36%.

Two things I predicted and got wrong:

- **Restating the rule closer to the audio would help.** It made things worse, 11/19 → 15/18. The
  restatement used the decoy value as its example, which appears to prime it. Examples in a
  fidelity rule must never contain a concrete value that could be echoed.
- **Two passes would beat one.** Two passes was twice as bad, 75% versus 38%, and *slower* is not
  even the trade — the single request was slower (15.7 s), because one call doing two jobs emits
  far more output. The likely mechanism is the reverse of the predicted one: a rewriter handed
  "Gemini 1.5" applies world knowledge and "corrects" a version number it thinks is stale, and it
  never sees the screen context that would tell it the number came from audio.

### 2026-08-09 — model comparison

`./eval/model-sweep.sh`. Same clip, same hostile context.

| model | no-context transcript of the version | audio tokens |
|---|---|---|
| `gemini-3.6-flash` | "Gemini **1.5**" — correct | 550 |
| `gemini-3.5-flash` | "Gemini **2.4**" — wrong | 550 |
| `gemini-3-flash-preview` | "**Gimma 2.0**" — wrong | 550 |
| `gemini-2.5-flash` | retired: "no longer available to new users" | — |

All three process the audio; none silently drops it. But only 3.6 transcribes the number correctly
**without any context at all**, and its general transcription is visibly better ("unified source"
versus "unified sauce" versus "verified source"). The older models cannot be scored for
substitution on this case at all, because they do not produce either the spoken or the decoy value
— they simply mis-hear it.

That result made `gemini-3.6-flash` the default at the time, and the substitution numbers above
remain specific to it. On 2026-08-17 the product default moved to `gemini-3.5-flash` after a newer
seven-clip technical-dictation sweep, which has no human goldens and therefore does not replace
this historical accuracy result. Re-run both workloads on any model bump: multimodal quality moves
between releases, and these are the measurements in the project that would notice.

### 2026-08-16 — the markers were sending the documentation

Split into `prompt/`, and the reason is a bug the markers made possible.

`PromptBuilder` searched for the *first* `<!-- BEGIN SYSTEM -->` in the file. Line 5 of the old
PROMPT.md quoted that marker inside backticks while explaining what the loader did, so that
sentence was the match. Every request since the contract was written carried this preamble ahead of
rule 1:

```
` marker, substitutes
`Fidelity is LIGHT. Drop filler sounds…` with the active fidelity clause, and sends the result as
`system_instruction`. Do not change the markers.

Changes here require re-running `swift run dnt-eval suite eval/nearmiss` and recording the new
numbers in the changelog at the bottom.

<!-- BEGIN SYSTEM -->
```

Two things were wrong with that, and the second is worse than the first. The stray text is noise,
but the sentence it came from also mentions `{{FIDELITY_RULE}}` — and the substitution replaced
*every* occurrence, so **the fidelity clause was being sent twice**, once in that preamble and
again at rule 5. The 2026-08-09 entry above records that restating the fidelity rule made
substitution worse, 11/19 → 15/18. The prompt had been doing an accidental version of exactly that
throughout every measurement in this changelog.

The three implementations shared the bug — Swift, C# and Kotlin all used first-match substring
search — and the unit tests missed it because they parsed a synthetic template that mentioned each
marker once. There is now a test that asserts the assembled instruction of every part matches the
file on disk, and it runs against the shipped `prompt/`, not a fixture.

**Every number above this entry was measured with the stray preamble present**, and none of them
has been re-measured without it.
