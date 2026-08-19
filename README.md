<img src="Resources/Icon/rendered/appicon.png" alt="" width="92" align="right">

# DoNotType

An open-source voice input method that **transcribes what you said** instead of rewriting it —
and reads your screen so it spells the hard words right.

[![CI](https://github.com/bojieli/DoNotType/actions/workflows/ci.yml/badge.svg)](https://github.com/bojieli/DoNotType/actions/workflows/ci.yml)
[![Release](https://github.com/bojieli/DoNotType/actions/workflows/release.yml/badge.svg)](https://github.com/bojieli/DoNotType/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

macOS · Windows · Android · iOS. Your own API key, no server in the middle.

## Why DoNotType

Most voice tools make you choose between keeping your words and spelling uncommon terms correctly.

- **Built-in dictation:** keeps your phrasing, but without screen context it often misses project
  names, jargon, and other technical terms.
- **Commercial AI dictation:** uses larger models and context, but returns a polished rewrite
  instead of the exact words you said.
- **DoNotType:** keeps a recoverable verbatim transcript, grounds spelling in your screen, and is
  open source with your choice of provider.

<img src="Resources/Demo/hero.svg" alt="Illustrative example: a paper page shows ByteDance Research and UI-TARS. Audio-only dictation writes 'Best Dong's UI task'; DoNotType combines the audio with screen context and writes 'ByteDance's UI-TARS'." width="880">

*An illustrative example, not a benchmark result. The screen contributes the exact spelling;
the recording remains the authority for what was said.*

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

## Research and contribute

The central research question is not whether more context helps. It is **which context helps,
under a finite token, latency, and privacy budget, without overriding the recording**. The shipped
system deliberately uses bounded screen context and an optional personal dictionary; prior
transcripts are not sent. Better context policies should be established by ablation rather than
intuition.

Questions worth testing include:

- Which screen regions carry the most useful signal: the caret neighborhood, visible text,
  window title, browser URL, screenshot, or application identity?
- Do recent transcripts improve project vocabulary, or anchor the model to words the speaker did
  not say this time?
- Can edits made immediately after dictation become safe, spelling-only correction signals?
- How should a fixed context budget be divided among screen text, a personal dictionary, recent
  vocabulary, and other opt-in sources?
- Which sources improve names and technical terms without increasing substitution when the
  context and audio disagree?

Community contributions are welcome across the full stack:

| Area | Useful contributions |
|---|---|
| **Context research** | Controlled ablations of individual context sources and fixed-budget combinations, including accuracy, substitution, latency, and privacy tradeoffs. |
| **Prompts** | Prompt and context-format improvements with before/after evaluation results. |
| **Models and providers** | New hosted or local backends, capability declarations, live probes, and model comparisons. |
| **Benchmarks** | Reproducible cases, legally shareable corpora, cassettes, scoring improvements, and independently replicated results. |
| **Clients and tooling** | Cross-platform parity, diagnostics, evaluation infrastructure, accessibility, and documentation. |

Start with [CONTRIBUTING.md](CONTRIBUTING.md), the current
[context format](docs/CONTEXT_FORMAT.md), and the [evaluation method](docs/EVALUATION.md). Changes
to `prompt/` or the context format need **a measurement, not an argument**.

## Security

DoNotType reads your screen — that is the feature, and it deserves a plain description of what
the app can see, where keys live, and the honest threat model (including prompt injection).
See [SECURITY.md](SECURITY.md). Please do not open a public issue for vulnerabilities.

## License

[MIT](LICENSE).
