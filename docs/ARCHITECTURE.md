# Architecture

This document describes how DoNotType is built: the shared contract and its four platform ports,
the dictation pipeline, the design decisions that were settled by measurement, the component map,
the two-stage transcript model, long-dictation chunking, latency measurement, context grounding,
platform differences, the evaluation harness, and the testing layers. Read it before changing
anything in `Sources/DoNotTypeCore` or its ports. Design choices that look arbitrary here are
generally the residue of something that was measured; the measured basis is recorded in this
document.

## Repository shape

```
                     prompt/           docs/CONTEXT_FORMAT.md
                (the contract)        (how context is framed)
                        │                      │
                        └──────────┬───────────┘
                                   │  copied into every bundle at build time
        ┌──────────────┬───────────┼───────────┬──────────────┐
        │              │           │           │              │
   DoNotTypeCore   DoNotTypeCore  Kotlin   DoNotType.Core   dnt-eval
     (macOS)         (iOS)      (Android)    (Windows)     (harness)
        │              │           │           │              │
   menu-bar app   app+keyboard  IME+a11y    tray app      measurement
```

There are four implementations of the same contract. They are ports, not shared code: Swift,
Kotlin and C# cannot share a library across these platforms without dragging in a runtime nobody
wants inside a keyboard extension. What is shared is the pair of markdown files — the contract
under `prompt/` and the context-format specification — copied into each bundle by that platform's
build system so that no platform can drift from the contract.

## Dictation pipeline

```
hotkey down ──┬─ start recording
              ├─ phase 1 capture (cheap, synchronous, ~20 ms)
              └─ open upload session (not awaited)
                        │
                  user speaking
                        │
              ├─ phase 2 capture (accessibility walk, 500 ms cap)
              └─ screenshot if the tree came back thin
                        │
finish input ──┬─ trigger release/tap, or recording-only Return when opted in
               ├─ finish recording, encode already done
               ├─ upload finished file, or fall back to inline
               ├─ transcribe (context parts first, audio last)
               ├─ paste, confirm, store
               └─ if Return latched the intent, verify exact field and submit
```

Both steps marked "not awaited" exist for the same reason: everything expensive happens while the
user is still talking, because that time is free. Only what happens after the user lets go is
perceived as latency.

### Finish-and-send

Finish-and-send carries an extra identity beside the ordinary process-level paste guard: process
ID plus the focused accessibility/UI Automation element token. Return/Enter is consumed only while
recording and latches the configured output action before recognition begins. It always finishes
capture and inserts; the default output action stops there. After paste settles, only an exact
field match may receive the optional Return/Enter, `⌘ Return`, or `Ctrl+Enter`. Cancellation,
failure, manual-paste fallback, or an identity that could not be read has no submit path. For both
configured Escape and recording-time Return/Enter, the physical key-down, every repeat, and the
matching key-up are consumed; none reaches the target app.

## Measured design decisions

Each decision began as a prediction. The record preserves both the plausible mechanism and the
measurement that falsified it so the same prediction is not repeated.

**Pre-uploading was rejected because of tail latency.** A resumable Files API session was
opened at hotkey-down, so the handshake was free, and the finished file was referenced by URI
instead of carried as base64. Measured, this cost about a second of serial time after key release
to save about a second of body transfer — and when the upload stalled it had sixty seconds of
timeout to spend before falling back to a path that then worked first time. One dictation in six
paid 54 s for it. The recording now always rides in the request.

**Restating the fidelity rule nearer the audio increased substitutions.** Measured, substitutions went
from 11/19 to 15/18. The restatement used the decoy value as its example, which appears to prime
the model. Examples in a fidelity rule must never contain a concrete value that could be echoed.

**Two-pass rewriting increased substitution.** Substitution was
75% versus 38%; the single request was the slower one (15.7 s versus 7.5 s) because one call doing
two jobs emits far more output. A rewriter handed "Gemini 1.5" applies world knowledge and
"corrects" a version it believes is stale, having never seen the screen context that would tell it
the number came from audio.

**A provider can accept audio and silently discard it.** One gateway returned HTTP 200, billed 14
prompt tokens for a 6-second clip, and transcribed the screen context as though it were speech.
The guard lives on the provider protocol, not in an allowlist, because any backend can do this.

## Component map

| Type | Responsibility | Why it is the way it is |
|---|---|---|
| `ContextEncoder` | `ScreenContext` → request parts | Does no analysis. No term extraction, no ranking, no summarising — a distilled list throws away exactly what a multimodal model was chosen for. |
| `TokenBudget` | estimate + truncate | Truncation keeps the **tail**: the end of a buffer is the part nearest the caret. |
| `TranscriptionProvider` | one backend | Audio-token reporting is on the interface because omitting it would let it lie: the guard against a backend that accepts audio and discards it needs a number. |
| `OggOpusWriter` | container for compressed upload | CoreAudio encodes Opus but only into CAF; the API decodes Ogg. 16× smaller uploads, ~25% lower latency, identical transcripts. |
| `TranscriptionService` | first attempt and retries | Same code path both times, so a retry is not a lesser attempt. |
| `HistoryStore` | persistence | A failed entry keeps its audio until it succeeds, whatever retention says — otherwise Retry is a button that cannot work. |
| `HistoryQuery` | search and filter | In the core so the rules are testable without a UI. |
| `Reachability` | online/offline | Decides *before* a request is spent, so offline queues instead of timing out. |
| `FailureAdvice` | error → guidance | Every message answers "what do I do now?". |
| `PromptSource` | which file is in force per part | An edited part shadows the shipped one; everything else still comes from `prompt/`. |
| `PromptStore` | user's per-part overrides | Validated before writing. Per part, so editing the contract cannot freeze the clauses with it. |
| `TranscriptDiff` | classify what grounding changed | Digits compare exactly; vowels fold rather than drop, so a false "spelling-fixed" cannot hide a substitution. |
| `AudioChunker` | split long recordings on silence | Cuts land in the middle of the quietest span, and every chunk carries identical context so a name is spelled the same on both sides of a seam. |
| `PerformanceStats` | what the app actually cost | Median and p95, never a mean; absence stays absent, because 0/0 is not a 0% success rate. |
| `Typography` | space at a Chinese/Latin boundary | The only transform applied to a finished transcript, and it may only add or remove horizontal space. A rule that could insert a comma would be inventing a pause the speaker did not take; that half of the same complaint is asked of the model instead, in `prompt/typography.md`. |
| `AudioDecoder` | any recording → 16 kHz mono WAV | The live path never needed it; a file does. Without it the chunker cannot split a compressed recording, the duration reads as zero, and the upload is not compressed. |
| `FileTranscriber` | decode → transcribe → second stage | Shared by the GUI window and `dnt transcribe`, so the two cannot drift on what a mode means or on which backend runs the second stage. |
| `StyledRequest` | what the `styled` field is for | A case rather than two optional parameters. A rewrite and a translation are different jobs asked for through the same field, and two optionals would make "both at once" a state somebody has to remember not to construct. |
| `TranscriptMode` | verbatim, rewrite, summary, translate | Ordering is the point: the verbatim transcript is stored before any styled text is delivered, whether the style came back in the same request or from a second one. |
| `LogRouter` / `Log` | levels, sinks, redaction | A lock rather than an actor, because logging has to be callable from an audio callback without an `await` — a logger you cannot call from the hot path is one nobody calls. |

## Typography

The transcript a user reads is the model's words in the model's layout, and the layout was not
stable: the same sentence came back with a space between Chinese and Latin on one dictation and
without it on the next, and sometimes with a stray space after a full-width full stop. Every
individual output was defensible; the set of them was not.

`Typography` fixes the half of that which is arithmetic. It runs in `TranscriptionService`, after
both audio guards and before the result leaves — the same choke point and the same argument as
`HallucinationGuard`: dictation, file transcription, retry, redo and both CLIs come through it, and
a transform that some callers applied would be missing from the one that mattered. It is
idempotent, because a split recording is normalised per chunk and again over the stitch.

Three constraints keep it safe to run on everything:

- **It only ever adds or removes horizontal space.** The suites assert that the input and the
  output are identical once whitespace is dropped. A rule that inserted a comma would be inventing
  a pause; that request is made of the model in `prompt/typography.md` instead.
- **Newlines are not horizontal space,** so it cannot join two lines, and leading or trailing space
  is left alone — an indent belongs to the speaker and the stitch's own space belongs to the
  chunker.
- **Hangul is not in the CJK class.** Korean separates its own words, so a "no space" setting would
  take out a space the language requires. Kana is in, so Japanese is treated consistently within
  itself rather than spacing `Web開発` and not `Webかいはつ`.

The measurement harness turns it off explicitly, which is the second deliberate divergence in this
document. A suite scores a transcript against ground truth transcribed from what the backend
produced; leaving typography on would score this app's own transform.

## Rewrite and summary

Both produce text beside the transcript rather than instead of it, but only one of them still costs
a second request. This section used to be called *Two-stage transcription*, and the rename is the
change: a rewrite is no longer a second stage.

**A rewrite is asked for in the request that transcribes.** `Transcript` carries an optional
`styled` field, `Transcript.styledJSONSchema` requires it, and `TranscriptionService.transcribeStyled`
folds the style clause into the system instruction so one round trip returns both the verbatim words
and the polished version. It is not configurable, because there is no version of "spend an extra
request" a user would choose: measured on `gemini-3.5-flash`, one request is 0.6–1.4 s faster, and
the fidelity argument for two passes was falsified before that (see [PROMPT.md](PROMPT.md)).

Three paths cannot fold it and fall back to the second request. `transcribeStyled` checks
`provider.grounding(forModel:)` and leaves a speech recogniser — `deepgram`, `xai`, `mistral` —
alone, because it can be handed neither a JSON schema nor a style rule. `transcribeLong` folds
nothing once it splits a recording, since a style applied per chunk yields five openings and five
closings for one utterance. The live pipeline declines for the same reason per segment. And a model
that accepts the schema then answers without the field gets the second pass anyway.

A summary always costs the second request: it is text-to-text by definition, and folding "remove
facts" into the request that is supposed to preserve them is the one combination this project will
not make.

They are also deliberately not the same mechanism at the prompt level. The rewrite instruction's
first rule is *never remove a fact*; a summary is defined by removing facts. Sharing a block would leave one style in that list
exempt from the block's first rule, and the exemption would be invisible at the call site.

The contract therefore carries two separate parts — `prompt/rewrite.md` and `prompt/summary.md`,
with their styles in separate directories. `PromptBuilder` exposes two methods with one router
(`secondStageInstruction(for:)`) so nothing can reach the wrong one by accident, and
`SummaryStyle` is a separate type from `RewriteStyle`. `DictationRecord.style` still records only
a `RewriteStyle`, which is why `mode` exists beside it: a history row must not claim a summary was
a rewrite, because that column drives "revert to what you said" and the two mean different things.

The invariant underneath both stages is the same one the app has always had: **the verbatim
transcript is produced first and stored first.** Folding the rewrite into one request does not
weaken it — `DictationController` writes `record.text` from the `transcript` field before it assigns
`record.styledText`, so `⌘⌥Z` behaves identically whether one request ran or two. What the styled
field removes is a round trip, not a copy of what was said.

## Translation

Speak one language, get another at the cursor. It is the one setting in the product that makes the
main control deliver something other than what was said, and it is off by default.

What it does *not* change is the promise underneath. A translation is a second stage over a
transcript that already exists, so the verbatim words are produced first, stored first, and
recoverable — the same invariant, the same `⌘⌥Z`, the same History row. A translation you cannot
expand back into what produced it is the failure this project was built against; one you can is a
convenience sitting beside the words.

Three decisions are worth recording:

- **It replaces the rewrite stage rather than joining it.** "Formal French" is one request doing
  two jobs, which is the combination measured as twice as bad for substitution (see
  [PROMPT.md](PROMPT.md)) — and it is a feature request rather than a fix for what was asked for.
  Each client says so where the rewrite control is, through `RewriteAvailability.translating`,
  rather than leaving a picker that silently does nothing.
- **It folds into the transcribing request.** Same reason as the rewrite: that request is the only
  one that has the audio, and a translator working from text alone "corrects" a version number it
  believes is stale. Recognisers, split recordings and the live pipeline keep the second pass.
- **The language is free text.** Languages are not ours to enumerate any more than model IDs are —
  "Traditional Chinese", "Brazilian Portuguese" and "plain English" are all things a model can do.
  `TranslationTarget` checks shape and never existence; the model is the authority.

## Long dictations

Past 90 seconds a recording is split on silence and the pieces are transcribed concurrently, three
at a time. A nine-minute dictation is roughly 17,000 audio tokens in one request, and by the time
it returns the user has been waiting since they stopped talking.

Three details carry the design:

- Cuts land at the **middle of the quietest 100 ms** near the target rather than at its start, so
  both neighbours keep a little silence. Audio that begins on the first sample of a word tends to
  lose that word's opening consonant.
- *Quietest* is used rather than an absolute threshold, because a threshold tuned for a quiet
  room finds no silence at all on a train and would then cut mid-word.
- Every chunk is sent with the **same screen context**, which is what stops chunk three spelling a
  name differently from chunk two. The requests are independent, and none of them knows what the
  others produced.

Stitching joins with a single space and nothing else. Chunks are cut in silence, so there is no
punctuation to infer, and inferring it would be inventing content — which the fidelity rules
forbid at a seam as firmly as anywhere else.

## Latency measurement

Latency is recorded from **key release**, not from the request. Everything in between — the
accessibility walk, a retry — is time the user spends looking at the overlay, and a figure that
excluded it would understate the wait the user actually experiences.

Failures contribute no timings at all. How long an error took to arrive is a different quantity,
and folding it in would make a fast app with a bad API key look slow.

## Grounding phases

Phase 1 is synchronous at hotkey-down and reads only what is cheap: app identity and cursor state.
It has to happen there because that is the last moment the focused element is guaranteed to be the
one being dictated into.

Phase 2 is the expensive walk plus, when the tree comes back thin, a screenshot. It carries a hard
500 ms deadline and returns partial results rather than failing.

The privacy gate runs **before** capture, never after: filtering a context that was already
collected still means the text was in the process's memory. The gate re-checks once a browser URL
is known, because a password page inside an allowed browser must still be excluded.

## Platform differences

These differences are structural, not incidental.

| | Grounding | Recording | Why |
|---|---|---|---|
| macOS | accessibility tree + screenshot | in-process | `AXEnhancedUserInterface` is what makes Electron apps legible |
| Windows | UI Automation + screenshot | in-process | no permission needed at all, which puts more weight on the blocklist |
| Android | `AccessibilityService`, pull-based | in the keyboard process | an IME may hold `RECORD_AUDIO` |
| iOS | **none possible** | containing app, controlled by keyboard | cold dictation deep-links to the app; a five-minute warm audio session accepts later keyboard start/stop commands |

iOS is not an unfinished port. Its keyboard owns the mic gesture and text insertion, while its
containing app owns capture because the extension cannot. The two processes coordinate through the
App Group and Darwin notifications; a persisted URL handoff recovers the first cold activation.

## Evaluation harness

`EvalRunner` does not build its own requests. It constructs a `TranscriptionService` — the same
object the app dictates through — and calls it.

This sharing of the code path is load-bearing rather than tidy. Twice in one day the harness
measured something the product does not do: it uploaded raw PCM after the app had moved to Opus,
and separately it bypassed compression entirely by assembling its own parts. Both times every
measured number improved, and no user would have seen any of it. A measurement harness on a
different code path measures the harness.

The one deliberate divergence is chunking: the eval calls `transcribeWithRetry` rather than
`transcribeLong`, because a suite that measured stitched output could not attribute a difference
to grounding. Every eval clip is far below the chunking threshold, so nothing is skipped in
practice.

## Testing layers

- **Unit** (`swift test`, `dotnet test`, `./gradlew test`) — pure logic, no network. Counts are
  reported by each runner rather than copied here and allowed to go stale. Where a type exists on
  several platforms, the ports assert the same invariants: a stats screen that reports different
  numbers on different platforms is worse than no stats screen.
- **Integration** (`DNT_INTEGRATION=1 swift test`) — live API on real recorded speech. Opt-in
  because it costs money and fails when the network does.
- **Evaluation** (`dnt-eval suite`, `ablate`, `model-sweep.sh`) — measures behaviour that unit
  tests cannot see. See [EVALUATION.md](EVALUATION.md).

The third layer is the unusual one, and the reason it exists is in [EVALUATION.md](EVALUATION.md):
the failure this project is about is invisible to assertions, because a substituted version number
reads as a correctly transcribed technical term.

## See also

- [EVALUATION.md](EVALUATION.md) — evaluation harness, suites, and methodology
- [CONTEXT_FORMAT.md](CONTEXT_FORMAT.md) — how screen context is framed for the model
