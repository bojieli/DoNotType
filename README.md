<div align="center">
  <img src="Resources/Icon/rendered/appicon.png" alt="DoNotType logo" width="112">

  <h1>DoNotType</h1>

  <p><strong>Your voice says it. Your screen spells it.</strong></p>

  <p>
    Open-source voice dictation that keeps your wording by default,<br>
    and uses the text on your screen to spell names, jargon, and technical terms correctly.
  </p>

  <p>
    <a href="https://github.com/bojieli/DoNotType/actions/workflows/ci.yml"><img src="https://github.com/bojieli/DoNotType/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
    <a href="https://github.com/bojieli/DoNotType/actions/workflows/release.yml"><img src="https://github.com/bojieli/DoNotType/actions/workflows/release.yml/badge.svg" alt="Release status"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
  </p>

  <p>
    macOS · Windows · Android · iOS<br>
    Bring your own API key · No DoNotType account · No DoNotType server
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

Live dictation has two modes. **Dictate** keeps your wording and is the default. **Rewrite** can make
the result formal, concise, or casual. The original transcript remains available in either mode.

DoNotType uses the text on your screen to resolve spelling. It can pick up a project name, an
acronym, or a version number that a model would otherwise guess at. The screen helps with spelling;
the recording remains the source for what you actually said.

| | What happens |
|---|---|
| **Built-in dictation** | Keeps your phrasing, but has no screen context to help with project names, jargon, or technical terms. |
| **AI dictation that rewrites** | Produces fluent text, but often gives you only the polished version. |
| **DoNotType** | Uses the screen for spelling, lets you choose the style, and keeps the original alongside it. |

| Style | Screen context | Transparency |
|:---:|:---:|:---:|
| Verbatim by default; polished text is available when you ask for it. | Visible text helps resolve names, acronyms, brands, and code-switched terms. | You can inspect the prompt and context sent with each request. |

## Quick start

Download a prebuilt **macOS** or **Android** package from
[Releases](https://github.com/bojieli/DoNotType/releases). Each artifact has a matching `.sha256`
file. The iOS client currently needs to be built from source.

Use the newest versioned release for reviewed artifacts, or
[the rolling build from the latest green `main`](https://github.com/bojieli/DoNotType/releases/tag/latest)
for development. The macOS download is Developer ID signed and notarized. Windows remains available
as source but is deliberately not distributed until its production build is manually verified and
Authenticode signing is available. The rolling Android build uses a debug key; versioned Android
releases use the configured release keystore.

To build and install the macOS app:

```bash
git clone https://github.com/bojieli/DoNotType
cd DoNotType
export GEMINI_API_KEY=...       # or add it later in Settings
make app && make install        # builds, signs, and installs to /Applications
```

Then **tap Right ⌘, speak, and tap it again**. The transcript appears at the cursor. On first
launch, DoNotType guides you through the Accessibility and Microphone permissions.

The same key supports either a tap or a hold:

| Gesture | What happens | Best for |
|---|---|---|
| **Tap, speak, tap** | The first tap starts recording and the second ends it. | Longer dictation and everyday use. |
| **Hold, speak, release** | After half a second, recording continues only while you hold the key. | Short utterances. |
| **Tap, speak, Return** | Return ends the recording, inserts the text, and can submit it. | Prompts and chat messages you were about to send. |

The third gesture is controlled by **Settings › Dictation › Finish with Return**. With
`Insert + Return`, DoNotType inserts the transcript and presses Return for you. This is useful for
CLI prompts such as Claude Code or Codex. In apps where Return creates a new line and ⌘/Ctrl Return
submits the message, choose `Insert + ⌘ Return` instead.

The default is `Insert only`, so a dictation never submits a message without your permission. The
extra keystroke is sent only when the original field is still focused. If you click somewhere else
while the request is in flight, DoNotType inserts the text and skips the submission. Escape cancels
an active dictation.

Existing recordings use the same pipeline, whether you start from the app or the CLI. File
transcription also has summary outputs for briefs, bullet points, and action items. These apply only
to saved recordings; Summary is not a live dictation mode.

```bash
dnt transcribe interview.m4a                          # verbatim, to stdout
dnt transcribe standup.wav --mode summary:actions     # decisions and next steps
dnt doctor --probe                                    # check keys, prompt, and connectivity
```

See the [full CLI reference](docs/CLI.md) for history, diagnostics, logging, and every option.

## How it works

| 1. Record | 2. Gather context | 3. Transcribe | 4. Insert |
|:---:|:---:|:---:|:---:|
| Tap the platform shortcut and speak naturally, or hold it if you prefer. | While you speak, DoNotType captures a bounded view of the focused app. | Audio and context go directly to the provider you chose. The prompt asks the model to use context for spelling only. | The text is inserted at the cursor in your chosen style. The original stays in history. |

DoNotType captures screen context within a 500 ms budget while you are still speaking, so it does
not add another wait. It prefers accessibility text and uses a screenshot where the platform
supports one. If the screen and the recording disagree, the recording wins.

### Two dictation modes

| Mode | Best for | Behavior |
|---|---|---|
| **Dictate** | Everyday dictation; the default | Returns the words you said, with screen context used to resolve spelling. |
| **Rewrite** | Formal, concise, or casual text | Returns both the rewritten text and the original transcript. |

Changed your mind after the fact? `⌘⌥Z` on macOS or `Ctrl+Alt+Z` on Windows puts your own wording
back.

All four clients follow the same behavior. A short, unsplit request to a model can return both
`transcript` and `styled`, so a rewrite does not require another round trip. Live segmented capture
and long recordings are assembled verbatim first and styled once. Speech-recognition providers
that cannot return styled text use the existing second-stage rewrite instead.

## Highlights

| Capability | What you get |
|---|---|
| **Shared prompt** | macOS menu bar, Windows tray, Android keyboard, and iOS voice keyboard clients all bundle the same versioned [`prompt/`](prompt/). |
| **Screen grounding** | Accessibility tree on macOS, UI Automation on Windows, and `AccessibilityService` on Android, with screenshot fallback where supported. |
| **Provider choice** | Google Gemini by default, OpenRouter, self-hosted vLLM or llama.cpp, and speech-recognition services such as xAI, Deepgram, and Mistral Voxtral. |
| **Personal dictionary** | A local dictionary with one-column CSV import; correction learning is opt-in, labelled, and removable. |
| **File transcription** | WAV, MP3, M4A, and Opus recordings through the same pipeline, with per-item history and retry. |
| **Works through interruptions** | Dictation waits before spending a request and resumes after reconnecting; failed audio remains available until it succeeds. |
| **Fallback backend** | An optional second backend can take over when the primary request stalls. |
| **Diagnostics** | Structured logs with transcripts withheld by default, plus median/p95 wait and per-model success rates measured on your own setup. |

## Platform support

| | Dictation | Screen grounding | Personal dictionary | File transcription | CLI | Build |
|---|---|---|---|---|---|---|
| **macOS** | Menu-bar app, tap or hold Right ⌘ | ✅ Accessibility tree + screenshot | ✅ Manual, CSV, optional learning | ✅ | `dnt` | `make app` |
| **Windows** | Tray app, tap or hold Right Ctrl | ✅ UI Automation | ✅ Manual, CSV, optional learning | ✅ | `dnt.exe` | `cd windows && dotnet build` |
| **Android** | Keyboard, records in-process | ✅ `AccessibilityService` | ✅ Manual, CSV, optional learning | ✅ | — | `cd android && ./gradlew assembleDebug` |
| **iOS** | Voice keyboard; containing app records | ❌ Unavailable in the iOS sandbox | ✅ Manual, CSV, best-effort learning | ✅ | — | `cd ios && xcodegen generate` |

See [platform parity](docs/PARITY.md) for the feature-by-feature breakdown and the reasons for
the differences.

## Principles

1. **Dictation, not authorship.** Rewriting is optional. Whatever style you choose, the original
   transcript is stored and can be recovered.
2. **Context helps with spelling.** Screen context is sent raw, without term extraction or prior
   transcripts. It can clarify a name or acronym, but the audio remains authoritative.
3. **No DoNotType server in the middle.** There is no DoNotType account, sign-in, subscription,
   telemetry, or analytics. Requests go from your device to the provider you configure with
   `store: false`. Keys stay in Keychain, DPAPI, or Android Keystore.
4. **Everything is inspectable.** The transcription prompt is made of versioned files you can read,
   edit, and restore. The Context Inspector shows exactly what was sent with each dictation.
5. **Measure changes.** Changes to prompts, context format, or the default backend come with
   before-and-after measurements.

## What this will never do

- Treat your original words as a disposable implementation detail.
- Intentionally let screen content decide what you said.
- Require a DoNotType-operated account, subscription, or intermediary server.
- Hide the transcription contract or the context sent to your chosen provider.
- Present an intuition as an accuracy claim without measuring it.

These are product boundaries, not unfinished roadmap items. Rewriting is useful when you want it,
but it never replaces your original transcript.

## Documentation

| Start here | What it covers |
|---|---|
| [`prompt/`](prompt/) | The transcription contract itself—the exact text sent, one part per file. |
| [Prompt design](docs/PROMPT.md) | Why the prompt is written this way and its measured changelog. |
| [Architecture](docs/ARCHITECTURE.md) | How the components fit together and which decisions were measured. |
| [CLI reference](docs/CLI.md) | File transcription, history, diagnostics, and logging. |
| [Platform parity](docs/PARITY.md) | What each client can do and why anything is missing. |
| [Evaluation](docs/EVALUATION.md) | How quality is measured and what the current numbers say. |
| [Models and providers](docs/MODELS.md) | Which backends can perform the required audio-and-context workflow. |
| [Context format](docs/CONTEXT_FORMAT.md) | How screen context is framed, bounded, ordered, and truncated. |

The [documentation index](docs/README.md) also includes localization, settings transfer, GPU
testing, release instructions, and other maintainer guides.

## Research and contribute

The central research question is **which context helps within a finite token, latency, and privacy
budget without overriding the recording**. We want to answer that with controlled ablations, not
intuition.

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

Start with [CONTRIBUTING.md](CONTRIBUTING.md), the current [context format](docs/CONTEXT_FORMAT.md),
and the [evaluation method](docs/EVALUATION.md). If you change `prompt/` or the context format,
include **a measurement, not an argument**.

## Security

DoNotType reads your screen; that is the feature. [SECURITY.md](SECURITY.md) explains what the app
can see, where keys live, and the threat model, including prompt injection. Follow the reporting
instructions there instead of opening a public issue for a vulnerability.

## License

DoNotType is available under the [MIT License](LICENSE).
