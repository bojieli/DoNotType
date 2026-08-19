# Contributing

This document describes how to contribute to DoNotType: the measurement rule for prompt and
context-format changes, build setup for each platform, project conventions, and how to report
bugs. The project is small, but one rule is unusual, so read this before opening a PR.

## The measurement rule

**Changes to `prompt/` or `docs/CONTEXT_FORMAT.md` need a measurement, not an argument.**

Those two are the product. Everything else is plumbing that delivers them. Three times in this
project's short history a change was justified by a plausible mechanism and then measured to do
the opposite:

- Restating the fidelity rule closer to the audio was predicted to help. Measured, substitution
  went from 11/19 to 15/18.
- A two-pass rewrite was predicted to preserve numbers better than one pass. Measured, it was
  twice as bad (75% versus 38%), and the single pass was the slower one.
- Screen grounding was predicted to be a clear win. Measured on real speech, it roughly doubles
  the error rate on a hard case.

A PR that changes prompt text, budgets, ordering or the context format must include
before/after numbers from `swift run dnt-eval ablate` or `dnt-eval suite --repeat-count 5`; see
[docs/EVALUATION.md](docs/EVALUATION.md). A PR that improves the numbers is welcome even if the
reasoning is unclear. A PR with clear reasoning and no numbers will be asked for numbers.

## Setup

```bash
git clone https://github.com/bojieli/DoNotType && cd DoNotType
swift test                     # 170 unit tests, no network, no key needed
export GEMINI_API_KEY=...      # only needed for integration and eval
make app && open .build/DoNotType.app
```

### UI tests

The apps have UI tests, which run where the app runs rather than on a build machine:

```bash
cd ios && xcodebuild test -scheme DoNotType \
  -destination 'platform=iOS Simulator,name=iPhone 17'   # installs and drives the app
cd android && ./gradlew connectedDebugAndroidTest         # needs a device or emulator attached
```

Run both before changing anything a window draws. A unit test cannot see that a screen renders
under the status bar, or that a bundle has no identifier and no installer will take it. Both
were real bugs here, and both survived a green CI for months because every test this project
had stopped at the core.

### Platform requirements

| Platform | Requirements | Build |
|---|---|---|
| macOS | Xcode 26+, Swift 6 | `make app` |
| Android | Android SDK 35, JDK 17 | `cd android && ./gradlew assembleDebug` |
| iOS | Xcode 26+, `brew install xcodegen` | `cd ios && xcodegen generate` |
| Windows | .NET 10 SDK, libopus | `cd windows && dotnet build` |

### CI Swift toolchain

CI compiles Swift with an older toolchain than a current local machine, and it is stricter. The
runners are macOS 15; a current machine is on 26. Swift 6.0 rejects some things 6.2 accepts —
most often a non-Sendable value crossing an `await` — so `swift build` can be clean locally and
fail in CI. This has happened twice. A Sendable error in CI that does not reproduce locally has
this cause, and the fix is to make the value genuinely Sendable rather than to reach for
`@preconcurrency`.

The Windows core targets plain `net10.0` and its tests run anywhere; `EnableWindowsTargeting`
lets even the WinForms app compile off-Windows, so a change can be compile-checked without a
Windows box.

### libopus

libopus is the one native dependency in the project, and only on Windows. macOS and iOS encode
Opus through CoreAudio and Android through `MediaCodec`; Windows ships no Opus encoder, so it
needs `opus.dll` beside the executable. The binding resolves the library name at load time
rather than hard-coding `opus.dll`, which means `brew install opus` (or
`apt install libopus0`) is enough to exercise the whole encoder path — including the P/Invoke
layer — on a developer machine and in CI. That was not portability for its own sake: a P/Invoke layer that
can only be tested by shipping it to Windows is not tested, and this one had a real bug that
only a live call could find — the P/Invoke path cannot be exercised without one.

If libopus is missing at runtime the app uploads WAV instead: slower, never broken.

## Conventions

- **Comments explain why, not what.** `// increment i` is noise. `// waveIn rather than WASAPI
  because 16 kHz mono PCM is exactly what it produces natively` is the comment that stops
  someone "improving" it later. Most comments in this codebase exist because a decision looks
  arbitrary until what was tried is known.
- **Failure messages answer "what do I do now?"** `FailureAdvice` exists for this. "The
  operation couldn't be completed" is not an error message.
- **No silent caps.** If a view truncates a list or a budget drops content, say so in the UI. A
  history list capped at 20 with nothing said about it reads as "this is all of it" — that was
  a real bug here, and it is the kind that erodes trust rather than crashing.
- **Privacy decisions happen before capture, not after.** Filtering a context already collected
  still means the text was in the process's memory.

## Strings

The interface is English and there are no translations yet. Two conventions keep that from
becoming permanent, and both cost nothing at the moment a line is already being edited:

- Interpolate rather than concatenate. `Text("Recording… \(hint)")` is one translatable
  sentence; `Text("Recording… " + hint)` is two fragments no language is obliged to keep in
  that order.
- On Android, new user-facing strings go in `strings.xml`.

`./scripts/localizable-report.py` counts what a translator could not reach. See
[docs/LOCALIZATION.md](docs/LOCALIZATION.md).

## Ports

A change to one platform's behaviour should usually land in all four, or explain why not. The
contract files are copied into each bundle at build time specifically so the platforms cannot
drift — editing a duplicated copy of a rule is a bug in the build, not something to work
around.

The app icon works the same way. Every platform's copy is rendered from
`Resources/Icon/DoNotType.svg`; edit that file and re-run `./Resources/Icon/make-icons.sh`, and
never touch a rendered `.icns`, `.ico`, `.png` or asset catalogue by hand. See
[Resources/Icon/README.md](Resources/Icon/README.md).

Not everything ports. iOS has no screen grounding and never will; Windows needs no
accessibility permission. Those differences are documented in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and are not defects.

## Documentation

Documentation lives in `docs/`, with an index at [docs/README.md](docs/README.md). Add new
documents to that index. Documentation uses the same neutral, declarative reference voice as
this file, and the measurement rule applies here as well: quality claims in documentation need
measurements, not arguments.

## Commits and PRs

- One coherent change per commit; the body explains why, not a restatement of the diff.
- `swift test`, `dotnet test` and `./gradlew test` must pass. Integration tests are opt-in and
  not required in CI.
- If a change touches a platform that cannot be run locally, say so in the PR. "Compiles,
  untested on device" records the verification boundary; omitting it does not.

## Reporting a transcription bug

A useful report has three parts, because without them nobody can reproduce the failure:

1. What was said, exactly.
2. What came out.
3. What was on screen at the time — the Context Inspector in Settings shows precisely what was
   sent.

When possible, add the case to `eval/nearmiss/` with a `.wav`. A reproducible failure is worth
more than a description of one.

## Security

See [SECURITY.md](SECURITY.md). Do not open a public issue for anything involving key handling
or data exfiltration.
