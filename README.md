# DoNotType

An open-source voice input method for macOS that **transcribes what you said** instead of
rewriting it, and uses **what is on your screen** to spell the hard words right.

Built on `gemini-3.6-flash`, with your own API key. Nothing is sent anywhere except the model
request.

## Why

Existing tools get two things wrong:

- **They rewrite.** Dictate casually and get back something formal. The refinement is the product,
  so there is no setting to turn it off and no raw transcript kept anywhere.
- **Their grounding overrules you.** A stored vocabulary of "correct" terms becomes a prior that
  beats clear audio: say "Gemini 3.5 Flash" and get "Gemini 3 Flash", because that string is the
  one the system already knows.

DoNotType inverts both. The prompt is a versioned file you can read and change
([`PROMPT.md`](PROMPT.md)). Screen context is sent **raw** — no term extraction, no dictionary, no
prior transcripts — and its authority is scoped to spelling only.

## Platforms

| | Dictation | Screen grounding | Build |
|---|---|---|---|
| **macOS** | menu-bar app, hold Right ⌘ | ✅ accessibility tree + screenshot fallback | `make app` |
| **Android** | keyboard, records in-process | ✅ `AccessibilityService`, pull-based | `cd android && gradle assembleDebug` |
| **iOS** | containing app | ❌ not possible in the sandbox | `cd ios && xcodegen generate` |

All three send the **same** `PROMPT.md`, copied into each bundle at build time rather than
duplicated, so no platform can quietly drift from what the eval measures.

iOS is the odd one out for a reason: a keyboard extension cannot open a microphone, so the app
records and the keyboard inserts through an App Group. See [`ios/README.md`](ios/README.md).

## Measurement

The riskiest assumption in the design is whether a model will use screen context for spelling
without letting it overwrite content. That is testable with a CLI in an afternoon, so it was built
before any platform code.

```
swift test                                     # 41 unit tests
swift run dnt-eval probe --audio some.wav      # verify a provider forwards audio
swift run dnt-eval once   --audio some.wav --visible-text "..."
swift run dnt-eval suite  eval/nearmiss        # the number that matters
```

Every case runs **twice — with context and without** — and both are judged against ground truth.
Scoring on the diff alone would be wrong, because the no-context baseline is itself unstable: a
large diff from a *wrong* baseline is grounding doing its job. So each run is classified by effect:

| Effect | Meaning | Bar |
|---|---|---|
| `improved` | baseline wrong, context fixed it | the feature working |
| `neutral-correct` | both right | fine |
| `neutral-wrong` | context did not help | tolerable |
| **`regressed`** | **baseline right, context broke it** | **must be 0** |

Transcription is non-deterministic, so `--repeat-count` defaults to 3. One run is an anecdote —
an early single-pass run of this suite reported 0 regressions, and the next reported 2.

Latest: **15 runs, 15 matched, 0 regressed** on native Gemini. See the changelog in
[`PROMPT.md`](PROMPT.md), including why that number is necessary but not yet sufficient.

## Providers

| Provider | Env var | Audio | Suite (15 runs) |
|---|---|---|---|
| `gemini` | `GEMINI_API_KEY` | ✅ verified | **15 matched, 0 regressed** — default |
| `openrouter` | `OPENROUTER_API_KEY` | ✅ verified | 12 matched, 1 regressed |

The same model ID scored differently through a gateway than first-party, so the provider is
recorded alongside every measurement.

Providers are **not** interchangeable. A gateway that *accepts* an audio block without forwarding
it is worse than one that rejects it: the model then invents a fluent, confident transcript of
nothing. One OpenAI-compatible gateway was tested and did exactly that — HTTP 200, 14 prompt
tokens for a 6-second clip, and a transcript of the *screen context* rather than the speech. It
was dropped from this list.

Because any provider can behave that way, the protection is a runtime check rather than an
allowlist: if audio was sent and the provider bills zero audio tokens, the request throws instead
of returning fabricated text. Verify a new backend before trusting it:

```
swift run dnt-eval probe --provider <name> --audio eval/audio/gemini-version.wav
```

## Design

- [`PROMPT.md`](PROMPT.md) — the transcription contract, and the fidelity clauses
- [`CONTEXT_FORMAT.md`](CONTEXT_FORMAT.md) — part order, delimiters, caps, truncation direction
- [`PLAN.html`](PLAN.html) — the full survey and rationale

## How grounding stays cheap

Copied from Typeless, which got this part right. Two phases:

| Phase | When | Reads | Blocking |
|---|---|---|---|
| 1 | hotkey-down | app identity, cursor state | yes, ~20 ms |
| 2 | immediately after, not awaited | visible text (500 ms cap), caret window, screenshot | no |

Phase 1 has to be synchronous because it is the last moment the focused element is guaranteed to
be the one being dictated into. Phase 2 runs while you are still speaking, so grounding costs no
perceived latency.

The privacy gate runs **before** capture, never after — filtering a context you already collected
still means the text was in the process's memory. It ships non-empty (password managers, banking,
health) and re-checks once a browser URL is known.

## Roadmap

| | |
|---|---|
| **M0** | Prompt harness — *done* |
| **M1–M3** | macOS: hotkey, capture, inject, accessibility grounding, screenshot fallback — *done* |
| **M4** | Android keyboard + accessibility grounding — *done* |
| **M5** | iOS app + keyboard extension — *done* |
| M6 | Real recorded eval suite, context inspector UI, notarized release |
| M7 | Windows (UI Automation) and Linux (AT-SPI) |

## License

TBD.
