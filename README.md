<div align="center">
  <img src="Resources/Icon/rendered/appicon.png" alt="DoNotType logo" width="112">

  <h1>DoNotType</h1>

  <p><strong>Your voice says it. Your screen spells it.</strong></p>

  <p>
    Open-source voice dictation that preserves what you said,<br>
    while using on-screen context to spell names, jargon, and technical terms correctly.
  </p>

  <p>
    <a href="https://github.com/bojieli/DoNotType/actions/workflows/ci.yml"><img src="https://github.com/bojieli/DoNotType/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
    <a href="https://github.com/bojieli/DoNotType/actions/workflows/release.yml"><img src="https://github.com/bojieli/DoNotType/actions/workflows/release.yml/badge.svg" alt="Release status"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
  </p>

  <p>
    macOS · Windows · Android · iOS<br>
    Your API key · No DoNotType account · No server in the middle
  </p>

  <p>
    <a href="https://github.com/bojieli/DoNotType/releases"><strong>Download</strong></a>
    · <a href="#quick-start">Quick start</a>
    · <a href="#how-it-works">How it works</a>
    · <a href="docs/README.md">Documentation</a>
    · <a href="CONTRIBUTING.md">Contribute</a>
  </p>
</div>

<br>

<div align="center">
  <img src="Resources/Demo/hero.svg" alt="Illustrative example: a paper page shows ByteDance Research and UI-TARS. Audio-only dictation writes 'Best Dong's UI task'; DoNotType combines the audio with screen context and writes 'ByteDance's UI-TARS'." width="880">
  <br>
  <sub>
    Illustrative example, not a benchmark result. The screen contributes the spelling;
    the recording remains the authority for what was said.
  </sub>
</div>

## Dictation that stays yours

Most voice tools make you choose between keeping your natural phrasing and spelling uncommon
terms correctly. DoNotType is built around a third option: **transcribe first, ground the spelling
in visible context, and keep the original recoverable.**

| | What happens |
|---|---|
| **Built-in dictation** | Keeps your phrasing, but without screen context it often misses project names, jargon, and other technical terms. |
| **Commercial AI dictation** | Uses larger models and context, but commonly returns a polished rewrite instead of the exact words you said. |
| **DoNotType** | Produces and stores a verbatim transcript first, uses your screen only to ground spelling, and makes rewriting an optional second stage. |

| Verbatim first | Context grounded | Direct and inspectable |
|:---:|:---:|:---:|
| Your original transcript is stored before any optional rewrite or summary. | Visible text helps resolve names, acronyms, brands, and code-switched terms. | Requests go to the provider you choose, and the prompt and sent context remain visible. |

## Quick start

Download a prebuilt **macOS**, **Windows**, or **Android** package from
[Releases](https://github.com/bojieli/DoNotType/releases). Every artifact has a matching
`.sha256` file. The iOS client can currently be built from source.

No versioned release has been published yet, so what is there now is
[the rolling build from the newest green `main`](https://github.com/bojieli/DoNotType/releases/tag/latest).
It is development output and says so: the macOS app is ad-hoc signed, so Gatekeeper will refuse it
until you allow it in System Settings › Privacy & Security; Windows is unsigned; Android is signed
with a debug key. Building from source below gives you a locally signed macOS app instead, which is
the smoother path today.

To build and install the macOS app:

```bash
git clone https://github.com/bojieli/DoNotType
cd DoNotType
export GEMINI_API_KEY=...       # or add it later in Settings
make app && make install        # builds, signs, and installs to /Applications
```

Then **hold Right ⌘, speak, and release**. Your words appear where the cursor was. On first
launch, the app guides you through Accessibility and Microphone permissions.

Existing recordings use the same pipeline from the app or the CLI:

```bash
dnt transcribe interview.m4a                          # verbatim, to stdout
dnt transcribe standup.wav --mode summary:actions     # decisions and next steps
dnt doctor --probe                                    # check keys, prompt, and connectivity
```

See the [full CLI reference](docs/CLI.md) for history, diagnostics, logging, and every option.

## How it works

| 1. Record | 2. Gather context | 3. Transcribe | 4. Insert |
|:---:|:---:|:---:|:---:|
| Hold the platform shortcut and speak naturally. | While you are speaking, DoNotType captures bounded context around the focused app. | Audio and context go directly to your configured provider under a spelling-only contract. | The verbatim result is stored and inserted at your cursor; optional transformations remain separate. |

Screen context is captured with a 500 ms budget while you are still speaking, so it does not add
a separate wait. Accessibility text is preferred, with a screenshot fallback where the platform
supports it. If the recording and the screen disagree, the recording is supposed to win.

### Three modes, one recoverable original

| Mode | Best for | Behavior |
|---|---|---|
| `verbatim` | Everyday dictation | One transcription request; preserves the speaker's words. |
| `rewrite` | Formal, concise, or casual variants | Runs as a second stage beside the stored verbatim transcript. |
| `summary` | Briefs, bullet points, or action items | May discard content by design, but never replaces the stored original. |

Undo a transformation and return to the original with `⌘⌥Z` on macOS or `Ctrl+Alt+Z` on Windows.

## Highlights

| Capability | What you get |
|---|---|
| **Four platforms, one contract** | macOS menu bar, Windows tray, Android keyboard, and iOS voice keyboard clients all bundle the same versioned [`prompt/`](prompt/). |
| **Screen grounding** | Accessibility tree on macOS, UI Automation on Windows, and `AccessibilityService` on Android, with screenshot fallback where supported. |
| **Provider choice** | Google Gemini by default, OpenRouter, self-hosted vLLM or llama.cpp, and speech-recognition services including xAI, Deepgram, and Mistral Voxtral. |
| **Personal dictionary** | A local, visible, optional dictionary with one-column CSV import; correction learning is opt-in, labelled, and removable. |
| **File transcription** | WAV, MP3, M4A, and Opus recordings through the same pipeline, with per-item history and retry. |
| **Offline tolerance** | Dictation queues before a request is spent and resumes on reconnect; failed audio remains available until it succeeds. |
| **Fallback backend** | An optional second backend can bound the latency tail without changing your primary provider. |
| **Honest diagnostics** | Structured logs with transcripts withheld by default, plus median/p95 wait and per-model success rates measured on your own setup. |

## Platform support

| | Dictation | Screen grounding | Personal dictionary | File transcription | CLI | Build |
|---|---|---|---|---|---|---|
| **macOS** | Menu-bar app, hold Right ⌘ | ✅ Accessibility tree + screenshot | ✅ Manual, CSV, optional learning | ✅ | `dnt` | `make app` |
| **Windows** | Tray app, hold Right Ctrl | ✅ UI Automation | ✅ Manual, CSV, optional learning | ✅ | `dnt.exe` | `cd windows && dotnet build` |
| **Android** | Keyboard, records in-process | ✅ `AccessibilityService` | ✅ Manual, CSV, optional learning | ✅ | — | `cd android && ./gradlew assembleDebug` |
| **iOS** | Voice keyboard; containing app records | ❌ Not possible in the sandbox | ✅ Manual, CSV, best-effort learning | ✅ | — | `cd ios && xcodegen generate` |

See [platform parity](docs/PARITY.md) for a feature-by-feature breakdown and the reason for every
gap.

## Principles

1. **Dictation, not authorship.** The verbatim transcript is produced first, stored first, and
   recoverable. Rewrites and summaries sit beside it rather than replacing it.
2. **Grounding spells; it never decides.** Screen context is sent raw—without term extraction or
   prior transcripts—and its authority is limited to spelling. The audio remains authoritative.
3. **No DoNotType server in the middle.** There is no DoNotType account, sign-in, subscription,
   telemetry, or analytics. Requests go from your device to the provider you configure with
   `store: false`; keys live in Keychain, DPAPI, or Android Keystore.
4. **Everything is inspectable.** The transcription prompt is made of versioned files you can
   read, edit, and restore. The Context Inspector shows exactly what was sent with each dictation.
5. **Claims carry numbers.** Prompt, context-format, and default-backend changes require
   before-and-after measurements, not arguments.

## What this will never do

- Treat your original words as a disposable implementation detail.
- Intentionally let screen content decide what you said.
- Require a DoNotType-operated account, subscription, or intermediary server.
- Hide the transcription contract or the context sent to your chosen provider.
- Present an intuition as an accuracy claim without measuring it.

These boundaries are product constraints, not roadmap gaps. Optional rewriting can improve the
presentation of a transcript, but it will not become the only transcript.

## Status, honestly

DoNotType is working and tested, with one central unsolved problem. A tool that reads your screen
must earn trust, so the limitations are part of the front-page documentation.

- **Digit substitution is mitigated, not solved.** When text beside the caret contained a number
  that contradicted the recording, the model took the screen's value 75% of the time. The shipped
  mitigation—a second, screen-blind transcription that supplies the digits—brings that to 20%,
  on by default, at the cost of a second request and about 1.5 seconds. Word-level grounding
  (names, acronyms, brands, and code-switching) passes the full adversarial suite.
- **Accuracy on ordinary dictation is unmeasured.** The published results cover deliberately
  adversarial cases; a verified corpus for everyday speech is still in progress.
- **iOS cannot read the screen.** The sandbox provides no user-grantable way to do so. This is a
  platform restriction, not a roadmap item.
- **Microphone capture and text injection are not covered by CI.** They require hardware and are
  checked manually once per release.

Read the [evaluation method, per-channel results, and falsified mitigations](docs/EVALUATION.md).

## Documentation

| Start here | What it covers |
|---|---|
| [`prompt/`](prompt/) | The transcription contract itself—the exact text sent, one part per file. |
| [Prompt design](docs/PROMPT.md) | Why the contract is worded this way and its measured changelog. |
| [Architecture](docs/ARCHITECTURE.md) | How the components fit together and which decisions were measured. |
| [CLI reference](docs/CLI.md) | File transcription, history, diagnostics, and logging. |
| [Platform parity](docs/PARITY.md) | What each client can do and why anything is missing. |
| [Evaluation](docs/EVALUATION.md) | How quality is measured and what the current numbers say. |
| [Models and providers](docs/MODELS.md) | Which backends can perform the required audio-and-context workflow. |
| [Context format](docs/CONTEXT_FORMAT.md) | How screen context is framed, bounded, ordered, and truncated. |

The [documentation index](docs/README.md) also includes localization, settings transfer, GPU
testing, release instructions, and other maintainer guides.

## Research and contribute

The central research question is not whether more context helps. It is **which context helps under
a finite token, latency, and privacy budget without overriding the recording**. Better policies
should be established by controlled ablation rather than intuition.

<details>
<summary><strong>Questions worth testing</strong></summary>

- Which screen regions carry the most useful signal: the caret neighborhood, visible text,
  window title, browser URL, screenshot, or application identity?
- Do recent transcripts improve project vocabulary, or anchor the model to words the speaker did
  not say this time?
- Can edits made immediately after dictation become safe, spelling-only correction signals?
- How should a fixed context budget be divided among screen text, a personal dictionary, recent
  vocabulary, and other opt-in sources?
- Which sources improve names and technical terms without increasing substitution when context
  and audio disagree?

</details>

| Area | Useful contributions |
|---|---|
| **Context research** | Controlled ablations of individual sources and fixed-budget combinations, including accuracy, substitution, latency, and privacy tradeoffs. |
| **Prompts** | Prompt and context-format improvements with before-and-after evaluation results. |
| **Models and providers** | New hosted or local backends, capability declarations, live probes, and model comparisons. |
| **Benchmarks** | Reproducible cases, legally shareable corpora, cassettes, scoring improvements, and independent replications. |
| **Clients and tooling** | Cross-platform parity, diagnostics, evaluation infrastructure, accessibility, and documentation. |

Start with [CONTRIBUTING.md](CONTRIBUTING.md), the current
[context format](docs/CONTEXT_FORMAT.md), and the [evaluation method](docs/EVALUATION.md). Changes
to `prompt/` or the context format need **a measurement, not an argument**.

## Security

DoNotType reads your screen—that is the feature, and it deserves a plain description of what the
app can see, where keys live, and the threat model, including prompt injection. Read
[SECURITY.md](SECURITY.md), and please do not open a public issue for vulnerabilities.

## License

DoNotType is available under the [MIT License](LICENSE).
