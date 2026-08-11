<img src="Resources/Icon/rendered/appicon.png" alt="" width="92" align="right">

# DoNotType

A voice input method that **transcribes what you said** instead of rewriting it, and reads your
screen so it spells the hard words right.

macOS · Windows · Android · iOS. Open source, your own API key, no server in the middle.

```
        hold a key ──▶ speak ──▶ release ──▶ your words, where your cursor was
                                    │
                        grounded in what is on your screen,
                        so "koffi" stays koffi and 3.5 stays 3.5
```

## Why

Dictation tools in this category get two things wrong.

**They rewrite.** Speak casually, get back something formal. The refinement *is* the product, so
there is no setting to turn it off and no raw transcript kept anywhere. In the tool this project
was built to replace, the only stored field is `refined_text` — going back through every schema
version, what you actually said was never saved.

**Their grounding overrules you.** A stored vocabulary of "correct" terms becomes a prior that
beats clear audio: say "Gemini 3.5 Flash" and get "Gemini 3 Flash", because that string is the one
the system already knows. Worse, a correction-fed dictionary makes it self-reinforcing.

DoNotType inverts both. The prompt is a versioned file you can read, edit and measure
([`PROMPT.md`](PROMPT.md)). Screen context is sent **raw** — no term extraction, no dictionary, no
prior transcripts — and its authority is scoped to spelling, never content.

## Status, honestly

This is a working tool with one unsolved problem, and it is the central one.

**Substitution is not fixed.** On real recorded speech with contradicting screen context, the model
writes the on-screen version number instead of the spoken one in roughly **36%** of runs — against a
**21%** baseline error rate with no context at all. So grounding roughly doubles an already
non-zero error rate on hard audio. Full numbers, method and two falsified mitigations are in
[docs/EVALUATION.md](docs/EVALUATION.md).

Everything else works and is tested. Each app is now driven by a UI test on the platform it ships
to — the iOS app is installed and exercised in a simulator, the Android app in an emulator, and the
Windows tray app is launched on a Windows runner and has to still be alive with its settings window
open before the build passes. That last one is new: for most of this project's life the Windows app
compiled and had **never been started on Windows**, and until recently the iOS app could not be
installed anywhere at all.

Still unexercised by any test: the iOS keyboard extension, which needs the keyboard enabling in iOS
Settings before a test can reach it, and dictation itself on every platform, which needs a
microphone and a paid API call.

## Platforms

| | Dictation | Screen grounding | Build |
|---|---|---|---|
| **macOS** | menu-bar app, hold Right ⌘ | ✅ accessibility tree + screenshot fallback | `make app` |
| **Windows** | tray app, hold Right Ctrl | ✅ UI Automation | `cd windows && dotnet build` |
| **Android** | keyboard, records in-process | ✅ `AccessibilityService`, pull-based | `cd android && gradle assembleDebug` |
| **iOS** | containing app; keyboard inserts | ❌ not possible in the sandbox | `cd ios && xcodegen generate` |

All four send the **same** `PROMPT.md`, copied into each bundle at build time rather than
duplicated, so no platform can quietly drift from what the evaluation measures.

iOS is the odd one out for a reason: a keyboard extension cannot open a microphone — "Allow Full
Access" grants network and a shared container, not the mic. See [ios/README.md](ios/README.md).

## Install

Prebuilt macOS, Windows and Android artifacts are attached to each
[release](../../releases), with a `.sha256` beside every one. iOS is not distributed — it needs a
provisioning profile, so build it from source.

From source on macOS:

```bash
git clone https://github.com/bojieli/DoNotType && cd DoNotType
export GEMINI_API_KEY=...       # or add it in Settings
make app && make install        # builds, signs, installs to /Applications
```

On first launch it walks you through Accessibility and Microphone permissions, and re-checks them
every launch — macOS revokes Accessibility whenever an app's signature changes.

## How it works

**Two-phase capture.** At hotkey-down it takes a cheap snapshot (app identity, cursor state) and
opens an upload session. While you are still speaking it runs the expensive accessibility walk
(10,000 characters, 500 ms cap) and, if the tree comes back thin, captures the focused window.
Everything expensive happens during the recording, because that time is free. What you feel is only
what happens after you let go.

**Upload with a fallback.** The finished recording is uploaded and referenced by URI, turning
megabytes of base64 into a few hundred bytes of JSON. Anything that fails falls back to inline
rather than failing the dictation — a flaky network should cost latency, never words.

**Offline queues rather than fails.** Being offline is detected *before* a request is spent, so the
dictation goes straight to history and sends itself when you reconnect.

**Failed dictations keep their audio** until they succeed. Otherwise "Retry" would be a button that
cannot work.

**Undo is cheap because the verbatim transcript is always kept.** A wrong transcript, or a rewrite
that came out too formal, is one key away from being fixed — `⌘⌥Z` swaps in what you actually said.
A tool that discards the original cannot offer this at all, which is the difference being argued.

More in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Settings

- **Providers and keys** — Gemini (default), any OpenAI-compatible gateway, or a server you run
  yourself (vLLM, llama.cpp), with a live connection test. Keys live in the Keychain / DPAPI, never
  in a config file.
- **Hotkey** — which key, whether a tap toggles or a hold talks, and an optional **second key
  bound to a rewrite** (formal, concise, bullets) for when you want an email rather than a
  transcript. Your main key always stays verbatim.
- **Shortcuts** — `⌘⇧Z` undoes the last insertion, `⌘⌥Z` reverts a rewrite to what you actually
  said, `⌘⌃V` pastes the last transcript again.
- **Audio** — pin a microphone rather than following the system default; start/stop tones are on
  by default and can be disabled.
- **Fidelity** — `raw`, `light` (default), `tidy`. Even `tidy` only changes typography, never words.
- **Grounding** — on/off, screenshot fallback, and two blocklists evaluated *before* capture.
- **History** — search, filters, per-item retry and delete, retention policy, per-dictation
  timings, and a **Context Inspector** showing exactly what was sent with any dictation.
- **Stats** — median and p95 wait, wait per second spoken, success rate, retries, and a per-model
  breakdown measured on your microphone and your network rather than on a vendor's benchmark.
- **Prompt** — edit the contract in place on any platform, validated before saving, restorable to
  the shipped default.

## Evaluation

The failure this project is about is invisible to ordinary assertions: a substituted version number
reads as a correctly transcribed technical term. So there is a measurement layer.

```bash
swift test                                    # 170 unit tests, no network
DNT_INTEGRATION=1 swift test                  # live API on real speech
swift run dnt-eval suite eval/nearmiss        # near-miss suite
swift run dnt-eval ablate                     # compare designs on fidelity and latency
./eval/model-sweep.sh                         # compare model versions
```

Historical runs found `gemini-3.6-flash` strongest on the reference clip, while older Gemini models
misheard its version number and `openai/gpt-audio` sometimes replied conversationally instead of
transcribing. The exact real-speech fixtures are not present in this checkout, so those figures are
handoff context rather than a currently reproducible benchmark; the ignored synthetic stand-ins are
not valid replacements. Current downloaded-checkpoint tests use separately labeled public real
audio. Full status in [docs/MODELS.md](docs/MODELS.md); method in
[docs/EVALUATION.md](docs/EVALUATION.md).

## Privacy

No server of ours, no telemetry, no analytics. Requests go straight from your machine to the
provider you configured, with `store: false` set. The blocklist is evaluated before capture and
ships non-empty. The Context Inspector shows exactly what was sent with any dictation.

Read [SECURITY.md](SECURITY.md) for what the app can see, where keys live, and an honest threat
model — including prompt injection, which this design has an unusually direct surface for.

## Contributing

Changes to `PROMPT.md` or the context format need **a measurement, not an argument**. Three
plausible-sounding changes in this project's history were measured and did the opposite of what was
predicted. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Documentation

| | |
|---|---|
| [PROMPT.md](PROMPT.md) | the transcription contract, and its measured changelog |
| [CONTEXT_FORMAT.md](CONTEXT_FORMAT.md) | part order, delimiters, caps, truncation direction |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | how the pieces fit, and which decisions were measured |
| [docs/EVALUATION.md](docs/EVALUATION.md) | how quality is measured and what the numbers say |
| [docs/MODELS.md](docs/MODELS.md) | which models and providers can actually do this job |
| [docs/GPU-TESTING.md](docs/GPU-TESTING.md) | running open-weight models locally, and what to measure |
| [docs/RELEASING.md](docs/RELEASING.md) | cutting a release, and which signing secrets change what |
| [Resources/Icon/README.md](Resources/Icon/README.md) | the app icon, and the one file every platform's copy is rendered from |
| [PLAN.html](PLAN.html) | the original reverse-engineering survey this design came from |

## License

[MIT](LICENSE).
