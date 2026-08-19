<!--
Keep this short. The commit message is where the reasoning belongs; this is for what a reviewer
cannot see from the diff.
-->

## What this changes, and why

<!-- Why, not a restatement of the diff. If a decision here looks arbitrary, say what you tried. -->

## Numbers, if this touches transcription quality

<!--
Required for changes to prompt/, docs/CONTEXT_FORMAT.md, the token budgets, part ordering, or the
default backend. Before and after, from `dnt-eval suite --repeat-count 5` or `dnt-eval ablate`.

Three plausible-sounding changes in this project's history were measured and did the opposite of
what was predicted, which is why this section exists. A PR that improves the numbers is welcome
even if the reasoning is unclear.

Delete this section if it does not apply.
-->

| | before | after |
|---|---|---|
| matched | | |
| improved | | |
| **regressed** | | |

## Platforms

<!--
A behaviour change usually lands on all four, or says why not. "Compiles, untested on device" is
useful and honest; silence is not.
-->

- [ ] macOS
- [ ] Windows
- [ ] Android
- [ ] iOS
- [ ] Not a platform change

## Checks

- [ ] `swift test`, `dotnet test` and `./gradlew test` pass
- [ ] Comments explain *why* where a decision looks arbitrary
- [ ] Nothing new is logged that could contain a transcript or a key
