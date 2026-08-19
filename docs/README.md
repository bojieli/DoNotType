# Documentation

Everything documented about DoNotType, grouped by audience. The entry point is the
[project README](../README.md).

## The contract

| | |
|---|---|
| [`prompt/`](../prompt/) | The transcription contract itself — the exact text sent to the model, one part per file. |
| [PROMPT.md](PROMPT.md) | Why the contract is worded that way, and its measured changelog. |
| [CONTEXT_FORMAT.md](CONTEXT_FORMAT.md) | How screen context is framed: part order, delimiters, caps, truncation direction. |

## User guides

| | |
|---|---|
| [CLI.md](CLI.md) | `dnt` and `dnt.exe`: file transcription, history, diagnostics, logging. |
| [PARITY.md](PARITY.md) | What each of the four clients can do, and why anything missing is missing. |
| [LOCALIZATION.md](LOCALIZATION.md) | Translating the interface, and why the prompt is never translated. |
| [SETTINGS-TRANSFER.md](SETTINGS-TRANSFER.md) | The settings import/export format shared by all GUI clients. |
| [ios/README.md](../ios/README.md) | Building the iOS app, and its keyboard/app architecture. |

## Design and measurement

| | |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the pieces fit, and which decisions were measured. |
| [EVALUATION.md](EVALUATION.md) | How transcription quality is measured, current numbers, and the experiment log. |
| [MODELS.md](MODELS.md) | Which models and providers can actually do this job, measured. |
| [GPU-TESTING.md](GPU-TESTING.md) | Running open-weight models locally, and what to measure. |
| [PLAN.html](PLAN.html) | The original reverse-engineering survey this design came from (historical). |

## Maintainer docs

| | |
|---|---|
| [RELEASING.md](RELEASING.md) | Cutting a release, and which signing secrets change what. |
| [MANUAL-CHECKS.md](MANUAL-CHECKS.md) | The hardware checks a machine cannot do, run once per release. |
| [Resources/Icon/README.md](../Resources/Icon/README.md) | The app icon, and the one file every platform's copy is rendered from. |
| [eval/cassettes/README.md](../eval/cassettes/README.md) | Recorded evaluation runs that can be re-scored for free. |

Root-level companions: [CONTRIBUTING.md](../CONTRIBUTING.md), [SECURITY.md](../SECURITY.md),
[CHANGELOG.md](../CHANGELOG.md), [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md).
