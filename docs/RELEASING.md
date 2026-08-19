# Releasing

This document describes the DoNotType release process: the tag-driven workflow, the artifacts it
produces, the package-manager manifests, the signing configuration, and the gates to run before
tagging.

## Tag-driven releases

Releases are cut by tag. Everything else is automatic.

```bash
git tag v0.2.0
git push origin v0.2.0
```

Pushing a tag runs [`.github/workflows/release.yml`](../.github/workflows/release.yml), which builds
all four platforms, runs each platform's tests first, and opens a **draft** GitHub release with the
artifacts attached. Read the generated notes, then publish.

### Version stamping

Each job stamps the version into its own checkout first, with
[`scripts/stamp-version.sh`](../scripts/stamp-version.sh). Four platforms keep four version fields,
and a release that stamps only some of them turns every bug report into a question about which
build it came from. The tag is the only source; nothing is committed back.

### Dry runs

To exercise the packaging without cutting a release, run the workflow manually from the Actions tab
with **publish** unchecked. This builds and uploads everything as workflow artifacts and creates no
release.

## Release artifacts

| artifact | contents |
|---|---|
| `DoNotType-macOS.zip` | the `.app` bundle |
| `DoNotType-Windows-x64.zip` | self-contained `.exe`, `opus.dll`, `prompt/` |
| `DoNotType-Android.apk` | installable APK |
| `*.sha256` | one per artifact |

### iOS

iOS is **built but not shipped**. Distributing it requires a provisioning profile and App Store
Connect, which is an account decision rather than a packaging one, and an unsigned `.app` that
nobody can install is not a release artifact. The job exists so that a tag cannot be cut on a
commit where iOS is broken.

## Package managers

Manifests live in [`packaging/`](../packaging/) and are **not** submitted yet: both registries
require a signed installer and a release history, and the project has neither. They are kept in the
tree so that the shape is reviewable and so that submitting is filling in a version rather than
authoring three files under time pressure.

After a release is published:

```bash
./scripts/update-packaging.sh 0.2.0
```

The script reads the `.sha256` files the workflow published beside each artifact and writes the
version and checksums into all four manifests. No hash is typed by hand: a cask with a stale
checksum fails at install with a complaint about a corrupt download, and a winget manifest with one
fails with a complaint about a tampered package. Both read as something far more alarming than a
forgotten field.

Submission is deliberately manual, because each submission is a pull request to somebody else's
repository:

| | where |
|---|---|
| Homebrew | copy `packaging/homebrew/donottype.rb` into the tap's `Casks/` |
| winget | `wingetcreate submit packaging/winget/` |

## Signing

The workflow runs without any secrets and produces working, unsigned builds. This is deliberate: a
fork should be able to produce artifacts. Unsigned builds are suitable for trying the app, not for
daily use:

- **macOS** refuses to open an ad-hoc-signed app normally, and because TCC keys permissions to the
  code signature, every update makes the system forget the Accessibility grant, forcing it to be
  re-granted on every release.
- **Android** falls back to a debug key. The APK installs from a file, but a debug-signed APK can
  never be updated in place by a differently-signed one; each update requires an uninstall and
  loses the history each time.

Configuring the following repository secrets enables signed builds. Each secret is optional and
independent; the workflow checks for each one and degrades rather than failing.

| secret | what it is |
|---|---|
| `MACOS_CERTIFICATE` | Developer ID Application `.p12`, base64-encoded |
| `MACOS_CERTIFICATE_PASSWORD` | its export password |
| `NOTARY_KEY_ID` | App Store Connect API key ID |
| `NOTARY_ISSUER_ID` | App Store Connect issuer ID |
| `NOTARY_KEY` | the `.p8` private key, verbatim |
| `ANDROID_KEYSTORE` | upload keystore, base64-encoded |
| `ANDROID_KEYSTORE_PASSWORD` | its password |
| `ANDROID_KEY_ALIAS` | key alias inside the keystore |

Base64-encode the two file secrets with:

```bash
base64 -i DeveloperID.p12 | pbcopy
base64 -i release.keystore | pbcopy
```

Notarization runs only when `NOTARY_KEY_ID` is set, and stapling means the app opens without a
network round trip on first launch.

## libopus

Windows is the only platform with no Opus encoder in the box, so the workflow **builds libopus from
source** — a pinned tag, compiled in the open — rather than downloading a binary. A release `.dll`
pulled from an arbitrary host is a supply-chain decision that nobody reviewed; a compile that
anyone can audit from the build log is not.

`opus.dll` ships beside the executable, which is where the import resolver looks first. Without it
the app still dictates, but uploads WAV instead: roughly 16× more data and noticeably slower.

## Pre-tagging gates

### Platform tests

The workflow runs each platform's tests, so a red suite fails the release rather than shipping. It
does **not** run the evaluation suite: the suite calls a paid API and depends on the network, which
would make releases a coin flip. Run it manually when the prompt, the model, or the context encoder
changed:

```bash
swift run dnt-eval suite eval/nearmiss
```

Read the per-pass ranges rather than the totals. The suite reports its own noise floor, and a
change that moves a count by less than that range has not been shown to do anything.

### Dictation-accuracy gate

**Ordinary-dictation accuracy is unmeasured, and a release that makes quality claims should not
ship while it is.** Everything published about transcription quality comes from a 16-case
adversarial suite, which is a regression detector rather than a quality measure. The 100-clip
corpus of real speech has no ground truth at all.

```bash
./eval/make-review-sheet.py          # → eval/dictation/review.html
open eval/dictation/review.html      # ~20 clips, worst backend disagreement first
./eval/score-review.py               # word error rate per backend, per language
```

The review takes roughly an hour and either supports the shipped default or overturns it.
Rationale: the project requires its published numbers to be accurate, and shipping while the
central result is unmeasured would violate that requirement.

### Replication requirements for announced numbers

Four measurements were corrected within two days of being published: the keyterm latency cost, the
digit rule being "structurally safer", a truncation attribution, and both native-Gemini figures.
Each correction was the process working, and none of them belonged in a launch post. Before quoting
a number publicly:

- It must come from **two independent sessions**, not two passes of one run. `--repeat-count`
  varies the model; it does not vary the day, and several of these figures move more between days
  than between passes.
- A substitution rate from a 10–12 trial ablation is a **screening result**. Such ablations
  separate models differing by 60 points and say nothing about differences under about 20.
- Record the run with `--record eval/cassettes/<name>.json`. Replay needs the audio, which is
  gitignored, so a reader cannot re-run the suite; the cassette keeps every answer the provider
  gave next to the score, so a later disagreement about the grading can be settled without
  re-billing the suite.

### Manual checks

Run [the checks a machine cannot do](MANUAL-CHECKS.md): the round trip, permissions from cold, the
failure modes, and a file through the GUI. They take fifteen minutes and cover the four things no
runner can: a microphone, a focused window in another app, a paid request, and somebody who knows
what was said. Record the result in the draft release notes, including anything that was not
checked.

## See also

- [MANUAL-CHECKS.md](MANUAL-CHECKS.md) — the manual pre-release checks
- [EVALUATION.md](EVALUATION.md) — the evaluation suite referenced by the pre-tagging gates
