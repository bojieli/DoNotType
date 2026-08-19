<img src="Resources/Icon/rendered/appicon.png" alt="" width="92" align="right">

# DoNotType

An open-source voice input method that **transcribes what you said** instead of rewriting it —
and reads your screen so it spells the hard words right.

[![CI](https://github.com/bojieli/DoNotType/actions/workflows/ci.yml/badge.svg)](https://github.com/bojieli/DoNotType/actions/workflows/ci.yml)
[![Release](https://github.com/bojieli/DoNotType/actions/workflows/release.yml/badge.svg)](https://github.com/bojieli/DoNotType/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

macOS · Windows · Android · iOS. Your own API key, no server in the middle.

<img src="Resources/Demo/hero.svg" alt="You say 'switch to Gemini three point five Flash' while the screen shows 'Gemini 3 Flash' five times. An opaque vocabulary prior types 'Gemini 3 Flash'. DoNotType types 'Gemini 3.5 Flash'." width="880">

## Why DoNotType

Voice input comes in two kinds today, and both fail technical work.

**Built-in dictation uses small models with no context.** The voice input shipped with macOS,
iOS, Android and Windows transcribes with relatively small, general-purpose models. They cannot
see what you are working on, so technical terms, project names and jargon come out wrong —
the exact words you dictated most carefully.

**Commercial AI dictation rewrites you.** Tools like Typeless add a large language model and
context grounding, which fixes the spelling — but the product is the rewrite, not the
transcription. Casual speech comes back formal and reads as AI-written rather than naturally
spoken. What you actually said is not kept: the stored field is the refined text. And the
software is closed-source and commercial, with your audio and screen context flowing through
servers you do not control.

DoNotType is the third option: a fully open-source, configurable voice input method that uses
large language models **while keeping your original utterances**. Verbatim first, grounded in
your screen, with every part inspectable.

| | Built-in dictation | Commercial AI dictation | **DoNotType** |
|---|---|---|---|
| Model | small on-device ASR | large language model | large model, provider is your choice |
| Technical terms | often wrong | right, via context | right, via screen grounding |
| What you get | your words, with errors | a rewrite of your words | your words, verbatim |
| Original utterance | kept, but wrong | discarded | always stored and recoverable |
| Source | closed | closed, subscription | MIT, your API key, no middle server |

## Principles

1. **Dictation, not authorship.** The verbatim transcript is always produced first, stored
   first, and recoverable. Rewrite and summary are optional second stages that sit *beside* the
   original, never instead of it — so undo is one keystroke (`⌘⌥Z` / `Ctrl+Alt+Z`).
2. **Grounding spells, it never decides.** Screen context is sent raw — no term extraction, no
   prior transcripts — and its authority is scoped to spelling, never content. When the screen
   and the audio disagree, the audio wins.
3. **No server in the middle.** No account, no sign-in, no subscription, no telemetry, no
   analytics. Requests go straight from your machine to the provider you configured, with
   `store: false` set. Keys live in the Keychain / DPAPI / Android Keystore.
4. **Everything is inspectable.** The transcription prompt is a directory of versioned files you
   can read, edit and restore ([`prompt/`](prompt/)). Every dictation keeps the context it was
   sent with, and the Context Inspector renders exactly what went over the wire.
5. **Claims carry numbers.** Changes to the prompt, the context format or the default backend
   require before/after measurements, not arguments. Known limitations are stated below, not
   hidden.

## Quick start

Download a prebuilt macOS, Windows or Android package from
[Releases](https://github.com/bojieli/DoNotType/releases) (`.sha256` beside every artifact), or
build from source on macOS:

```bash
git clone https://github.com/bojieli/DoNotType && cd DoNotType
export GEMINI_API_KEY=...       # or add it in Settings
make app && make install        # builds, signs, installs to /Applications
```

Then: **hold Right ⌘, speak, release** — your words appear where your cursor was. On first
launch the app walks you through Accessibility and Microphone permissions.

Existing recordings go through the same pipeline, in every app and from the CLI:

```bash
dnt transcribe interview.m4a                          # verbatim, to stdout
dnt transcribe standup.wav --mode summary:actions     # decisions and next steps
dnt doctor --probe                                    # keys, prompt, history, one live request
```

Full CLI reference: [docs/CLI.md](docs/CLI.md).

## Features

- **Four platforms, one contract.** macOS (menu bar), Windows (tray), Android (keyboard), iOS
  (voice keyboard). The same [`prompt/`](prompt/) is copied into every bundle at build time, so
  no platform can drift from what the evaluation measures.
- **Three modes, everywhere.** `verbatim` (one request), `rewrite` (formal, concise, casual),
  `summary` (brief, bullets, actions). The verbatim transcript is always kept; a summary is the
  only stage allowed to discard content, and it is a separate mechanism from rewrite by design.
- **Screen grounding.** Accessibility tree (macOS), UI Automation (Windows), or
  `AccessibilityService` (Android), with a screenshot fallback — captured with a 500 ms budget
  while you are still speaking, so it costs no wait.
- **Provider choice.** Google Gemini (default), OpenRouter, self-hosted (vLLM, llama.cpp), or
  speech-recognition services (xAI, Deepgram, Mistral Voxtral). Keys and models are stored per
  provider, so switching is one dropdown. An optional fallback backend bounds the latency tail.
- **Personal dictionary.** Local, visible, optional. Add entries directly or import a one-column
  CSV; correction learning is opt-in and learned entries are labelled and removable.
- **File transcription.** WAV, MP3, M4A and Opus recordings through the same pipeline on all
  four platforms, with per-item history and retry.
- **Offline-tolerant.** Offline is detected before a request is spent; dictations queue and send
  on reconnect. Failed dictations keep their audio until they succeed.
- **Honest logging and stats.** Structured logs on every platform with transcripts withheld by
  default; median/p95 wait and per-model success rates measured on your microphone and network.

## Platforms

| | Dictation | Screen grounding | Personal dictionary | File transcription | CLI | Build |
|---|---|---|---|---|---|---|
| **macOS** | menu-bar app, hold Right ⌘ | ✅ accessibility tree + screenshot | ✅ manual, CSV, optional learning | ✅ | `dnt` | `make app` |
| **Windows** | tray app, hold Right Ctrl | ✅ UI Automation | ✅ manual, CSV, optional learning | ✅ | `dnt.exe` | `cd windows && dotnet build` |
| **Android** | keyboard, records in-process | ✅ `AccessibilityService` | ✅ manual, CSV, optional learning | ✅ | — | `cd android && ./gradlew assembleDebug` |
| **iOS** | voice keyboard; containing app records | ❌ not possible in the sandbox | ✅ manual, CSV, best-effort learning | ✅ | — | `cd ios && xcodegen generate` |

Feature by feature, with the reason for every gap: [docs/PARITY.md](docs/PARITY.md).

## Status and known limitations

DoNotType is a working, tested tool with one central unsolved problem. It is stated here because
a tool that reads your screen must be trusted, and trust starts with the bad news.

- **Digit substitution is mitigated, not solved.** When the text beside your caret contains a
  number that contradicts the one you said, the model took the screen's value 75% of the time.
  The shipped mitigation — a second, screen-blind transcription that supplies the digits —
  brings that to 20%, on by default, at the cost of a second request and about 1.5 s. Word-level
  grounding (names, acronyms, brands, code-switching) passes the entire adversarial suite.
- **Accuracy on ordinary dictation is unmeasured.** Everything above describes deliberately
  adversarial cases; a verified corpus for everyday speech is in progress.
- **iOS cannot read the screen.** Nothing in the sandbox allows it, and there is no
  user-grantable escape hatch. This is a platform restriction, not a roadmap item.
- **Microphone capture and text injection are not covered by CI** (they need hardware); they are
  a manual checklist run once per release.

Method, per-channel numbers and falsified mitigations: [docs/EVALUATION.md](docs/EVALUATION.md).

## Documentation

| | |
|---|---|
| [`prompt/`](prompt/) | the transcription contract itself — what is sent, one part per file |
| [docs/PROMPT.md](docs/PROMPT.md) | why the contract is worded that way, and its measured changelog |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | how the pieces fit, and which decisions were measured |
| [docs/CLI.md](docs/CLI.md) | `dnt`: file transcription, history, diagnostics, logging |
| [docs/PARITY.md](docs/PARITY.md) | what each of the four clients can do, and why anything missing is missing |
| [docs/EVALUATION.md](docs/EVALUATION.md) | how quality is measured and what the numbers say |
| [docs/MODELS.md](docs/MODELS.md) | which models and providers can actually do this job |

Full index, including maintainer docs: [docs/README.md](docs/README.md).

## Contributing

Contributions are welcome, with one unusual rule: changes to `prompt/` or the context format
need **a measurement, not an argument**. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

DoNotType reads your screen — that is the feature, and it deserves a plain description of what
the app can see, where keys live, and the honest threat model (including prompt injection).
See [SECURITY.md](SECURITY.md). Please do not open a public issue for vulnerabilities.

## License

[MIT](LICENSE).
