# PROMPT.md

Design rationale and measured changelog for the [`../prompt/`](../prompt/) directory, which holds
the transcription contract — the exact text every platform sends to the model, one part per file.
This document records why each rule is worded the way it is, what was measured, and which
predictions about it measurement falsified. Nothing in this file is sent to a model.

That separation was not always in place. The live blocks used to sit here between
`<!-- BEGIN SYSTEM -->` markers and the loader sliced them out, which meant a parser had to tell
prose from payload by convention. It got that wrong for as long as the markers existed: the
marker quoted in this paragraph is itself an example — a first-match substring search picked the
quote over the real marker, so every request carried eight lines of this file's own documentation
ahead of rule 1. Parts are whole files now. There is no annotation to skip and nothing to
mis-match.

## The parts

| Part | File | Placeholder |
|---|---|---|
| Transcription contract | [`prompt/system.md`](../prompt/system.md) | `{{FIDELITY_RULE}}` |
| Rewrite stage | [`prompt/rewrite.md`](../prompt/rewrite.md) | `{{STYLE_RULE}}` |
| Summary stage | [`prompt/summary.md`](../prompt/summary.md) | `{{SUMMARY_RULE}}` |
| Fidelity clauses | [`prompt/fidelity/`](../prompt/fidelity/) — `raw`, `light`, `tidy` | — |
| Rewrite styles | [`prompt/style/`](../prompt/style/) — `formal`, `concise`, `casual` | — |
| Summary styles | [`prompt/summary-style/`](../prompt/summary-style/) — `brief`, `bullets`, `actions` | — |

Two rules govern the whole directory:

1. **A part file is sent in full.** No markers, no fences, no comments — if it is in the file it
   reaches the model, so anything that would not be said to the model does not belong there.
2. **A clause is one paragraph.** The three clause directories hold text that is substituted into a
   numbered list item, so hard wraps in them are joined with a single space on load. Nothing else
   is transformed.

Each part can be edited on its own, in the app's prompt editor or by hand, and restored on its own.
Editing one part does not freeze the others at the edited version — that is what the old
single-file override did, and it is why a prompt customised before summaries existed used to break
the summary stage outright.

Changes to any part require re-running `swift run dnt-eval suite eval/nearmiss` and recording the
new numbers in the changelog below.

## The rewrite stage

The rewrite stage is optional and off by default. The raw transcript is always produced first and
always stored, so whatever the rewrite does, what was actually said is recoverable. Typeless is
the cited counterexample: the failure is not that rewriting exists, but that it is mandatory and
discards the original.

**The one-request and two-request strategies remain an open choice.**

The prediction for two passes was that a model asked to polish prose normalises unfamiliar tokens
toward familiar ones, so combining "transcribe" with "make it formal" puts the objectives in
competition. Measurement falsified that prediction
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
from audio and is not its to fix — which is why the preservation rule in
[`prompt/rewrite.md`](../prompt/rewrite.md) exists, and why it is insufficient on its own.

Latency also went the other way. The single request was *slower* (15.7 s), because one call doing
both jobs emits far more output than two specialised ones.

Neither option is recommended yet. Both are implemented and both are measured; the numbers are
recorded here so the choice is made on evidence rather than the predicted mechanism, which was
falsified twice.

## The summary stage

The summary stage is also optional, also off by default, and deliberately **not** a rewrite style.

The first rule in [`prompt/rewrite.md`](../prompt/rewrite.md) — never remove a fact — is the rule
this project exists to enforce. A summary is defined by removing facts. Putting it in
`prompt/style/` alongside `formal` and `concise` would mean one file there is exempt from
the block's first rule, and the exemption would be invisible at the call site. It therefore gets
its own part, its own directory of styles, and its own type (`SummaryStyle`), and nothing that
asks for a rewrite can reach it.

The invariant that makes this safe is the same one that makes rewriting safe: **the verbatim
transcript is produced first and stored first**. A summary is a derived artifact sitting next to
the words that produced it, never instead of them.

Two consequences follow, and both are deliberate:

- **`dnt-eval rewrite` does not measure this stage.** That harness scores content preservation,
  and a summary scoring 0% loss would mean it had failed to summarise. The same check is not valid
  for this stage, so it is not run and no number is claimed.
- **Nothing in the changelog below applies to it.** The measured numbers describe transcription
  under screen context. Summarisation is a text-to-text pass with no audio and no screen, so it
  neither affects nor is described by them.

## Fidelity clauses

Exactly one of [`prompt/fidelity/`](../prompt/fidelity/) is substituted into `{{FIDELITY_RULE}}`
per request. `raw` keeps every audible word and filler. The default `light` removes empty fillers,
repetitions, stutters, abandoned starts, and superseded self-corrections; meaningful discourse
markers and the final correction stay. `tidy` adds standard casing and punctuation without
rephrasing.

## Chinese script

Spoken Mandarin does not identify a writing system. The shipped transcription contract therefore
uses Simplified Chinese by default and switches to Traditional only when the speaker asks for it.
This is a script choice, not translation: wording and language remain governed by the same
fidelity and language-preservation rules. A user-edited `system.md` remains authoritative, as
every other prompt override does.

## Changelog

Measured with `swift run dnt-eval suite eval/nearmiss --repeat-count 3`.

The headline number is **regressed**: cases where the no-context baseline was correct and adding
screen context broke it. That is the failure this contract exists to prevent, and it must be 0.

| Date | Change | Provider / model | runs | matched | improved | regressed |
|------|--------|------------------|------|---------|----------|-----------|
| 2026-08-19 | Casual rewrite style replaces bullets; default rewrite style | **gemini** · gemini-3.5-flash | 48 | 37 | 11 | **2** |
| 2026-08-19 | Light vocal fillers made unconditional | **gemini** · gemini-3.5-flash | 48 | 36 | 10 | **2** |
| 2026-08-17 | Light self-correction cleanup | **gemini** · gemini-3.5-flash | 48 | 35 | 7 | **2** |
| 2026-08-17 | Concise contracts and filler cleanup | **gemini** · gemini-3.5-flash | 48 | 38 | 12 | **2** |
| 2026-08-17 | Pre-change 972-word control | **gemini** · gemini-3.5-flash | 48 | 38 | 7 | **2** |
| 2026-08-09 | Initial contract | **gemini** · gemini-3.6-flash | 15 | 15 | 0 | **0** |
| 2026-08-09 | Initial contract | openrouter · google/gemini-3.6-flash | 15 | 12 | 0 | 1 |

### 2026-08-19 — casual rewrite style replaces bullets; the word-count caps are gone

Two changes, one measured, one decided.

**Casual replaces bullets.** `prompt/style/bullets.md` is retired and `prompt/style/casual.md`
added, on the owner's call that a bullet formatter is not a rewrite style worth a picker slot
pre-release. The distinction that dies with it is worth recording: `rewrite:bullets` kept every
fact and only changed shape; `summary:bullets` (untouched) is the one allowed to drop content. A
bare `rewrite` now means `rewrite:casual` on every platform, and the retired `bullets` spelling
degrades to the default in settings transfer instead of failing the import. The clause that
passed the fixtures is the constraint-first form ("Use relaxed, natural prose as if typed, not
spoken. Keep the speaker's voice and vocabulary; …"): the voice-first draft retained the spoken
opener "right so" in 2/48 samples; the constraint-first form retained nothing in 48. Final fixture
run: formal 0/24, concise 0/24, casual 0/24 lost, 0 retained.

**The 160/100/90 word-count tests are removed** from the Swift, .NET and Android suites, on the
owner's call. They were never a measurement — each number was a few words of headroom over the
then-current text — and in practice they priced examples out of the contract: "I mean" left the
light clause's example list this week for exactly 3 words of budget. The brevity evidence stands
(the 972-word control measured no better than 448, below), so concision stays as a changelog
norm, not as a hardcoded number.

The required near-miss run: 37 matched / 11 improved / 2 regressed. Style clauses never reach the
transcription request, so any movement from the 2026-08-19 baseline (36/9/1) and variant (36/10/2)
is the suite's noise floor by construction; the gate is satisfied and the zero-regression goal
remains failed as before.

### 2026-08-19 — light fidelity: vocal fillers split out of the dangling conditional

The retained-hotkey benchmark (497 real dictations × five models,
`eval/results/hotkey-model-benchmark-2026-08-18.json`) put numbers on the complaint that vocal
fillers survive light fidelity: 146 of 190 "um/uh/ah" hits belonged to gemini-3.5-flash, while
gemini-3-flash-preview had 2 (a quoted "um ah" used as content, correctly retained), 3.6 had 17,
3.7 had 25 alongside 65 safety-blocked requests, and grok-stt had none because its API flag strips
them server-side. Same prompt, same audio — filler compliance is mostly a model property.

The one prompt-side flaw was grammatical. `fidelity/light.md` was the only part whose condition
dangled: "Remove vocal fillers …, and discourse fillers such as … when they add no meaning" lets
the condition scope over the whole list, so a model may treat a hesitation as meaningful and keep
it. `tidy.md` and `rewrite.md` use the adjective form ("empty discourse fillers"), and the rewrite
stage measured 45/45 filler-free. The clause now gives vocal fillers an unconditional sentence of
their own and confines the conditional to a separate discourse-filler sentence. The assembled
light instruction was already at the 160-word test cap and stays there; "I mean" left the example
list to make room ("you know" out-occurs it 40:22 in the benchmark) and remains covered by the
category.

A/B on the benchmark's seven worst leaking clips — retained real audio, gemini-3.5-flash, eight
samples per clip per arm: vocal-filler hits **182 → 75**, leaky samples 21/56 → 17/56. The two
worst clips went 65→6 and 62→2, no clip got meaningfully worse, and a quoted-filler control kept
its quoted "um ah" in both arms. A third arm also rewording rule 2 of `system.md` ("Apart from
those removals, …") netted 67 hits against the clause-only arm's 73 on the shared four clips —
inside per-clip noise — so `system.md` is unchanged.

The required near-miss run, both arms same day, gemini-3.5-flash, 48 runs each: baseline matched
36 / improved 9 / regressed 1; the variant matched 36 / improved 10 / regressed 2. The per-pass
regression range is 0–1 in both arms, so 1 versus 2 is the suite's own noise floor: the variant's
second regression is the flaky `benefit-novel-repo` flipping on its unstable baseline draw, and
`real-acronym` regressed as it has in every recorded run. The zero-regression gate remains failed,
as it has since the real-speech cases were added.

### 2026-08-17 — concise contracts and measurable filler removal

The first round tightened all twelve prompt parts from **972 to 448 words**; the transcription
contract fell from **413 to 102 words** before its fidelity clause. Explicit self-correction rules
bring the current total to **477 words**. Tests cap assembled transcription, rewrite, and summary
instructions at 160, 100, and 90 words respectively; the current default instructions are 157 and
97 words for light transcription and formal rewrite.

The required near-miss run did not clear the zero-regression gate. Across 16 cases and three
passes, gemini-3.5-flash matched 38/48, improved a wrong baseline 12 times, left 8 wrong, and
regressed 2. A control run using the pre-change 972-word prompt also matched 38/48, left 8 wrong,
and produced the same 2 regressions in the unstable `real-acronym` case; it improved 7 wrong
baselines. The shorter contract therefore did not worsen the headline result in this comparison.
The improvement counts overlap the suite's per-pass range, so 12 versus 7 is not evidence of a
gain. Both prompts still fail the gate.

`dnt-eval rewrite --trials 3` now measures filler retention as well as fact preservation. A first
draft kept the empty word "basically" in 2/15 concise and 3/15 bullet rewrites. Naming it in the
shared cleanup rule closed those failures. The final run preserved every required fact and removed
every marked filler in **15/15 formal, 15/15 concise, and 15/15 bullet rewrites** (45/45 total),
with no request errors.

The follow-up adds the same correction behavior to light dictation: remove repetitions and the
superseded half of a self-correction, but keep the final wording. On a synthesized correction
clip, both light requests returned only Friday and Marcus and removed Thursday, Priya, two "um"
fillers, and the repeated "I will". Raw fidelity preserved the full correction trail in both
requests. This is a prompt smoke test on clear synthesized speech, not a general accuracy result.

The rewrite evaluator now includes day, name, and number corrections plus a contrast control where
both numbers must remain. Across all styles it removed every marked filler or superseded
correction in 72/72 outputs and preserved required content in 71/72; the one failure inserted
spaces inside hedge words. A formal-only rerun preserved content and removed marked speech in
24/24. The explicit self-correction cases passed 27/27 across formal, concise, and bullet styles.

Changing light fidelity required another near-miss run. It matched 35/48, improved 7 wrong
baselines, left 11 wrong, and regressed 2. Its per-pass effect ranges overlap the preceding
concise run, so the difference is not evidence that correction cleanup changed grounding. The
zero-regression gate remains failed.

Notes on the first measurement:

- **Rule 4 held under hostile cases.** `01-gemini-version` puts "Gemini 3 Flash" on screen five
  times against audio saying "three point five", and the transcript kept 3.5 in every run. Same
  for a port number one digit off a terminal buffer, a name against a thread naming only someone
  else, and a command whose scrollback showed extra flags.
- **The same model ID behaves differently through a gateway.** Native Gemini passed 15/15;
  OpenRouter passed 12/15 and produced the one regression, turning a correct `koffi` baseline into
  `Coffee`. Native is now the default. Both are kept in the changelog — a provider difference this
  size is worth noticing before it is attributed to a prompt change.
- **One run is an anecdote.** An early single-pass run of the same suite reported 0 regressions
  and a later one reported 2, purely from baseline instability on the ambiguous case.
  `--repeat-count` defaults to 3 for this reason.
- **The audio is still the weak point.** `say` enunciates far more clearly than a person, and the
  model's own knowledge covers well-known terms: a control using "cuber netties" was transcribed
  as "Kubernetes" with *no context at all*, so it measured nothing. Until the suite uses real
  speech and identifiers the model cannot already know, `regressed 0` is necessary but not
  sufficient.

### 2026-08-09 — rule 4 fails intermittently on real speech

The caveat above turned out to be the important part. Once the suite moved to real recorded
speech, the substitution this contract exists to prevent **reproduced**.

The clip (`eval/audio/real-talk-gemini15.wav`, extracted from a real talk) says "Gemini 1.5".
Given screen context repeating "Gemini 2.5" five times, an integration run produced **2.5** — a
version number the speaker never said.

It is intermittent, not systematic: the no-context baseline says 1.5 every time, and repeated runs
*with* the hostile context mostly also say 1.5. But "mostly" is the finding. On synthesized audio
this never happened at all, which is exactly why the TTS suite could not be trusted.

What this means:

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

Two prompt-adjacent findings, both from moving text between sections without changing a word of
it.

| where the correct spelling of a novel name sits | transcribed correctly |
|---|---|
| visible text | 0 / 12 |
| text before caret | 12 / 12 |

| where a contradicting value sits | substituted for what was spoken |
|---|---|
| visible text | 3 / 10 |
| text before caret | 7 / 10 |

The caret sections are a tenth of the visible-text budget and dominate it in both directions.

**A third prediction, falsified.** An earlier note recorded that a novel name losing to a name the
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

The first row matters most. With *no context at all*, the model still wrote 2.5 in 21% of runs.
This clip's audio is genuinely hard — the speaker is mid-sentence and the number is unstressed.
The accurate claim is therefore not "grounding causes a 58% failure"; it is that grounding roughly
**doubles an error rate that is already non-zero**, from ~21% to ~36%.

Two predictions measurement falsified:

- **Restating the rule closer to the audio was predicted to help.** It made things worse, 11/19 →
  15/18. The restatement used the decoy value as its example, which appears to prime it. Examples
  in a fidelity rule must never contain a concrete value that could be echoed.
- **Two passes were predicted to beat one.** Two passes was twice as bad, 75% versus 38%, and
  *slower* is not even the trade — the single request was slower (15.7 s), because one call doing
  two jobs emits far more output. The likely mechanism is the reverse of the predicted one: a
  rewriter handed "Gemini 1.5" applies world knowledge and "corrects" a version number it thinks
  is stale, and it never sees the screen context that would tell it the number came from audio.

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
substitution on this case at all, because they do not produce either the spoken or the decoy
value — they simply mis-hear it.

That result made `gemini-3.6-flash` the default at the time, and the substitution numbers above
remain specific to it. On 2026-08-17 the product default moved to `gemini-3.5-flash` after a newer
seven-clip technical-dictation sweep, which has no human goldens and therefore does not replace
this historical accuracy result. Re-run both workloads on any model bump: multimodal quality moves
between releases, and these are the measurements in the project that would notice.

### 2026-08-16 — the markers were sending the documentation

The contract is now split into `prompt/`, and the reason is a bug the markers made possible.

`PromptBuilder` searched for the *first* `<!-- BEGIN SYSTEM -->` in the file. Line 5 of the old
PROMPT.md quoted that marker inside backticks while explaining what the loader did, so that
sentence was the match. Every request since the contract was written carried this preamble ahead
of rule 1:

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
substitution worse, 11/19 → 15/18. The prompt had been doing an accidental version of exactly
that throughout every measurement in this changelog.

The three implementations shared the bug — Swift, C# and Kotlin all used first-match substring
search — and the unit tests missed it because they parsed a synthetic template that mentioned each
marker once. There is now a test that asserts the assembled instruction of every part matches the
file on disk, and it runs against the shipped `prompt/`, not a fixture.

**Every number above this entry was measured with the stray preamble present**, and none of them
has been re-measured without it.

## See also

- [`prompt/`](../prompt/) — the transcription contract this document argues for
- [CONTEXT_FORMAT.md](CONTEXT_FORMAT.md) — how the screen context the contract consumes is framed
- [EVALUATION.md](EVALUATION.md) — the evaluation harness behind the changelog numbers
