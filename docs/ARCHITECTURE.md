# Architecture

Read this before changing anything in `Sources/DoNotTypeCore` or its ports. Most of what looks
arbitrary here is the residue of something that was measured and came out the other way.

## The shape

```
                    PROMPT.md          CONTEXT_FORMAT.md
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

There are four implementations of the same contract. They are ports, not shared code — Swift,
Kotlin and C# cannot share a library across these platforms without dragging in a runtime nobody
wants inside a keyboard extension. What *is* shared is the pair of markdown files, copied into each
bundle by that platform's build system so no platform can quietly drift.

## The pipeline

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
hotkey up  ────┬─ finish recording, encode already done
               ├─ upload finished file, or fall back to inline
               ├─ transcribe (context parts first, audio last)
               └─ paste, confirm, store
```

Both "not awaited" steps exist for the same reason: everything expensive should happen while the
user is still talking, because that time is free. What they feel is only what happens after they
let go.

## Decisions that were measured

Each of these was a guess first. The guess is recorded because the reasoning was plausible and
still wrong, and that is worth knowing before someone re-derives it.

**Chunked upload during recording is impossible.** A WAV declares its length in the header. One
written with the streaming convention (`0xFFFFFFFF`) uploads fine and is then rejected with
`invalid argument`. So the file is uploaded once, complete, and the only thing overlapped with
recording is the session handshake. See `AudioUploader`.

**`uri`, not `file_uri`.** The Files API reference form uses `uri`; `file_uri` is rejected as an
unknown parameter.

**Restating the fidelity rule nearer the audio made things worse.** 11/19 substitutions became
15/18. The restatement used the decoy value as its example, which appears to prime it. Examples in
a fidelity rule must never contain a concrete value that could be echoed.

**Two-pass rewriting is worse than single-pass, and slower is not the trade.** 75% versus 38%
substitution; the single request was the slower one (15.7 s versus 7.5 s) because one call doing
two jobs emits far more output. A rewriter handed "Gemini 1.5" applies world knowledge and
"corrects" a version it believes is stale, having never seen the screen context that would tell it
the number came from audio.

**A provider can accept audio and silently discard it.** One gateway returned HTTP 200, billed 14
prompt tokens for a 6-second clip, and transcribed the *screen context* as though it were speech.
The guard lives on the provider protocol, not in an allowlist, because any backend can do this.

## Component map

| Type | Responsibility | Why it is the way it is |
|---|---|---|
| `ContextEncoder` | `ScreenContext` → request parts | Does no analysis. No term extraction, no ranking, no summarising — a distilled list throws away exactly what a multimodal model was chosen for. |
| `TokenBudget` | estimate + truncate | Truncation keeps the **tail**: the end of a buffer is the part nearest the caret. |
| `TranscriptionProvider` | one backend | `SupportsPreUpload` and audio-token reporting are on the interface because omitting them would let it lie. |
| `AudioUploader` | route the recording | Degrades to inline on any failure. A flaky network should cost latency, never words. |
| `OggOpusWriter` | container for compressed upload | CoreAudio encodes Opus but only into CAF; the API decodes Ogg. 16× smaller uploads, ~25% lower latency, identical transcripts. |
| `TranscriptionService` | first attempt and retries | Same code path both times, so a retry is not a lesser attempt. |
| `HistoryStore` | persistence | A failed entry keeps its audio until it succeeds, whatever retention says — otherwise Retry is a button that cannot work. |
| `HistoryQuery` | search and filter | In the core so the rules are testable without a UI. |
| `Reachability` | online/offline | Decides *before* a request is spent, so offline queues instead of timing out. |
| `FailureAdvice` | error → guidance | Every message answers "what do I do now?". |
| `PromptStore` | user's prompt override | Validated before writing; every fidelity must resolve. |
| `TranscriptDiff` | classify what grounding changed | Digits compare exactly; vowels fold rather than drop, so a false "spelling-fixed" cannot hide a substitution. |
| `AudioChunker` | split long recordings on silence | Cuts land in the middle of the quietest span, and every chunk carries identical context so a name is spelled the same on both sides of a seam. |
| `PerformanceStats` | what the app actually cost | Median and p95, never a mean; absence stays absent, because 0/0 is not a 0% success rate. |

## Long dictations

Past 90 seconds a recording is split on silence and the pieces are transcribed concurrently, three
at a time. A nine-minute dictation is roughly 17,000 audio tokens in one request, and by the time it
returns the user has been waiting since they stopped talking.

Three details carry the design. Cuts land at the **middle of the quietest 100 ms** near the target
rather than at its start, so both neighbours keep a little silence — audio that begins on the first
sample of a word tends to lose that word's opening consonant. *Quietest* rather than a threshold,
because an absolute threshold tuned for a quiet room finds no silence at all on a train and would
then cut mid-word. And every chunk is sent with the **same screen context**, which is what stops
chunk three spelling a name differently from chunk two — the requests are independent and none of
them knows what the others produced.

Stitching joins with a single space and nothing else. Chunks are cut in silence, so there is no
punctuation to infer, and inferring it would be inventing content — which the fidelity rules forbid
at a seam as firmly as anywhere else.

## Measuring the wait

Latency is recorded from **key release**, not from the request. Everything in between — the
accessibility walk, a pre-upload that failed and fell back, a retry — is time the user spends
looking at the overlay, and a figure that excluded it would be flattering and useless.

Failures contribute no timings at all. How long an error took to arrive is a different quantity, and
folding it in would make a fast app with a bad API key look slow.

## Grounding, in two phases

Phase 1 is synchronous at hotkey-down and reads only what is cheap — app identity and cursor state.
It has to happen there because that is the last moment the focused element is guaranteed to be the
one being dictated into.

Phase 2 is the expensive walk plus, when the tree comes back thin, a screenshot. It carries a hard
500 ms deadline and returns partial results rather than failing.

The privacy gate runs **before** capture, never after: filtering a context you already collected
still means the text was in the process's memory. It re-checks once a browser URL is known, because
a password page inside an allowed browser must still be excluded.

## Platform differences that are not incidental

| | Grounding | Recording | Why |
|---|---|---|---|
| macOS | accessibility tree + screenshot | in-process | `AXEnhancedUserInterface` is what makes Electron apps legible |
| Windows | UI Automation + screenshot | in-process | no permission needed at all, which puts more weight on the blocklist |
| Android | `AccessibilityService`, pull-based | in the keyboard process | an IME may hold `RECORD_AUDIO` |
| iOS | **none possible** | containing app only | a keyboard extension cannot open a microphone, and nothing in the sandbox lets one app read another's content |

iOS is not an unfinished port. It is a different product shaped by one restriction, which is why the
platform order was macOS → Android → iOS.

## The harness runs the product

`EvalRunner` does not build its own requests. It constructs a `TranscriptionService` — the same
object the app dictates through — and calls it.

This is load-bearing rather than tidy. Twice in one day the harness measured something the product
does not do: it uploaded raw PCM after the app had moved to Opus, and separately it bypassed
compression entirely by assembling its own parts. Both times every measured number improved and no
user would have seen any of it. A measurement harness on a different code path measures the
harness.

The one deliberate divergence is chunking: the eval calls `transcribeWithRetry` rather than
`transcribeLong`, because a suite that measured stitched output could not attribute a difference to
grounding. Every eval clip is far below the chunking threshold, so nothing is skipped in practice.

## Testing layers

- **Unit** (`swift test`, `dotnet test`, `gradle test`) — pure logic, no network. 182 + 53 + 24
  tests. Where a type exists on several platforms, the ports assert the same invariants: a stats
  screen that reports different numbers on different platforms is worse than no stats screen.
- **Integration** (`DNT_INTEGRATION=1 swift test`) — live API on real recorded speech. Opt-in
  because it costs money and fails when the network does.
- **Evaluation** (`dnt-eval suite`, `ablate`, `model-sweep.sh`) — measures behaviour that unit
  tests cannot see. See [EVALUATION.md](EVALUATION.md).

The third layer is the unusual one and the reason it exists is in [EVALUATION.md](EVALUATION.md):
the failure this project is about is invisible to assertions, because a substituted version number
reads as a correctly transcribed technical term.
