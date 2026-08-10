# Contributing

Thanks for looking. This is a small project with one unusual rule, so it is worth reading the
short version before opening a PR.

## The one unusual rule

**Changes to `PROMPT.md` or `CONTEXT_FORMAT.md` need a measurement, not an argument.**

Those two files are the product. Everything else is plumbing that delivers them. Three times in
this project's short history a change was justified by a plausible mechanism and then measured to
do the opposite:

- Restating the fidelity rule closer to the audio *should* have helped. Substitution went from
  11/19 to 15/18.
- A two-pass rewrite *should* have preserved numbers better than one pass. It was twice as bad
  (75% versus 38%) and the single pass was the slower one.
- Screen grounding *should* be a clear win. On real speech it roughly doubles the error rate on a
  hard case.

So: if your PR changes prompt text, budgets, ordering or the context format, include before/after
numbers from `swift run dnt-eval ablate` or `dnt-eval suite --repeat-count 5`. See
[docs/EVALUATION.md](docs/EVALUATION.md). A PR that improves the numbers is welcome even if the
reasoning is unclear. A PR with clear reasoning and no numbers will be asked for numbers.

## Getting set up

```bash
git clone https://github.com/bojieli/DoNotType && cd DoNotType
swift test                     # 73 unit tests, no network, no key needed
export GEMINI_API_KEY=...      # only needed for integration and eval
make app && open .build/DoNotType.app
```

Per platform:

| | requirements | build |
|---|---|---|
| macOS | Xcode 26+, Swift 6 | `make app` |
| Android | Android SDK 35, JDK 17 | `cd android && gradle assembleDebug` |
| iOS | Xcode 26+, `brew install xcodegen` | `cd ios && xcodegen generate` |
| Windows | .NET 10 SDK | `cd windows && dotnet build` |

The Windows core targets plain `net10.0` and its tests run anywhere; `EnableWindowsTargeting` lets
even the WinForms app compile off-Windows, so you can check a change builds without a Windows box.
You cannot *run* it without one.

## What good looks like here

**Comments explain why, not what.** `// increment i` is noise. `// waveIn rather than WASAPI
because 16 kHz mono PCM is exactly what it produces natively` is the comment that stops someone
"improving" it later. Most comments in this codebase exist because a decision looks arbitrary until
you know what was tried.

**Failure messages answer "what do I do now?"** `FailureAdvice` exists for this. "The operation
couldn't be completed" is not an error message.

**No silent caps.** If a view truncates a list or a budget drops content, say so in the UI. A
history list capped at 20 with nothing said about it reads as "this is all of it" — that was a real
bug here, and it is the kind that erodes trust rather than crashing.

**Privacy decisions happen before capture, not after.** Filtering a context you already collected
still means the text was in the process's memory.

## Ports

A change to one platform's behaviour should usually land in all four, or explain why not. The
contract files are copied into each bundle at build time specifically so the platforms cannot drift
— if you find yourself editing a duplicated copy of a rule, that is a bug in the build, not
something to work around.

Not everything ports. iOS has no screen grounding and never will; Windows needs no accessibility
permission. Those differences are documented in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and are
not defects.

## Commits and PRs

- One coherent change per commit; the body explains why, not a restatement of the diff.
- `swift test`, `dotnet test` and `gradle test` must pass. Integration tests are opt-in and not
  required in CI.
- If you touched a platform you cannot run, say so in the PR. "Compiles, untested on device" is
  useful and honest; silence is not.

## Reporting a transcription bug

The useful report has three parts, because without them nobody can reproduce it:

1. What you said, exactly.
2. What came out.
3. What was on screen at the time — the Context Inspector in Settings shows precisely what was sent.

If you can, add it to `eval/nearmiss/` as a case with a `.wav`. A reproducible failure is worth
more than a description of one.

## Security

See [SECURITY.md](SECURITY.md). Please do not open a public issue for anything involving key
handling or data exfiltration.
