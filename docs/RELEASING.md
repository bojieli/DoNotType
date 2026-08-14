# Releasing

Releases are cut by tag. Everything else is automatic.

```bash
git tag v0.2.0
git push origin v0.2.0
```

That runs [`.github/workflows/release.yml`](../.github/workflows/release.yml), which builds all four
platforms, runs each one's tests first, and opens a **draft** GitHub release with the artifacts
attached. Read the generated notes, then publish.

Each job stamps the version into its own checkout first, with
[`scripts/stamp-version.sh`](../scripts/stamp-version.sh) — four platforms keep four version fields,
and a release that stamps some of them turns every bug report into a question about which build it
came from. The tag is the only source; nothing is committed back.

To exercise the packaging without cutting a release, run the workflow manually from the Actions tab
with **publish** unchecked. It builds and uploads everything as workflow artifacts and creates no
release.

## What comes out

| artifact | contents |
|---|---|
| `DoNotType-macOS.zip` | the `.app` bundle |
| `DoNotType-Windows-x64.zip` | self-contained `.exe`, `opus.dll`, `PROMPT.md` |
| `DoNotType-Android.apk` | installable APK |
| `*.sha256` | one per artifact |

iOS is **built but not shipped**. Distributing it needs a provisioning profile and App Store
Connect, which is an account decision rather than a packaging one, and an unsigned `.app` nobody can
install is not a release artifact. The job exists so a tag cannot be cut on a commit where iOS is
broken.

## Package managers

Manifests live in [`packaging/`](../packaging/) and are **not** submitted yet: both registries want
a signed installer and a release history, and this project has neither. They are kept in the tree so
the shape is reviewable and so submitting is filling in a version rather than authoring three files
under time pressure.

After a release is published:

```bash
./scripts/update-packaging.sh 0.2.0
```

That reads the `.sha256` files the workflow published beside each artifact and writes the version
and checksums into all four manifests. Nobody types a hash by hand — a cask with a stale one fails
at install complaining about a corrupt download, and a winget manifest with one complains about a
tampered package. Both read as something far more alarming than a forgotten field.

Submitting is deliberately manual, because each is a pull request to somebody else's repository:

| | where |
|---|---|
| Homebrew | copy `packaging/homebrew/donottype.rb` into your tap's `Casks/` |
| winget | `wingetcreate submit packaging/winget/` |

## Signing

The workflow runs without any secrets and produces working, unsigned builds. That is deliberate —
someone should be able to fork this and get artifacts — but unsigned builds are for trying it out,
not for living with:

- **macOS** refuses to open an ad-hoc-signed app normally, and because TCC keys permissions to the
  code signature, every update makes the system forget your Accessibility grant. You would re-grant
  it on every release.
- **Android** falls back to a debug key. It installs from a file, but a debug-signed APK can never
  be updated in place by a differently-signed one — you would uninstall and lose your history each
  time.

Configure these repository secrets to fix that. Each is optional and independent; the workflow
checks for each and degrades rather than failing.

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

Base64 for the two file secrets:

```bash
base64 -i DeveloperID.p12 | pbcopy
base64 -i release.keystore | pbcopy
```

Notarization only runs when `NOTARY_KEY_ID` is set, and stapling means the app opens without a
network round trip on first launch.

## libopus

Windows is the only platform with no Opus encoder in the box, so the workflow **builds libopus from
source** — a pinned tag, compiled in the open — rather than downloading a binary. A release `.dll`
pulled from an arbitrary host is a supply-chain decision nobody reviewed; a compile anyone can audit
from the build log is not.

`opus.dll` ships beside the executable, which is where the import resolver looks first. Without it
the app still dictates, it just uploads WAV: roughly 16× more data and noticeably slower.

## Before tagging

The workflow runs each platform's tests, so a red suite fails the release rather than shipping. It
does **not** run the evaluation suite — that calls a paid API and depends on the network, which
would make releases a coin flip. Run it yourself when the prompt, the model, or the context encoder
changed:

```bash
swift run dnt-eval suite eval/nearmiss
```

Read the per-pass ranges rather than the totals. The suite reports its own noise floor, and a change
that moves a count by less than that range has not been shown to do anything.

### The gate that is not about code

**Ordinary-dictation accuracy is unmeasured, and a release that makes quality claims should not
ship while it is.** Everything published about transcription quality comes from a 16-case
adversarial suite, which is a regression detector rather than a quality measure. The 100-clip
corpus of real speech has no ground truth at all.

```bash
./eval/make-review-sheet.py          # → eval/dictation/review.html
open eval/dictation/review.html      # ~20 clips, worst backend disagreement first
./eval/score-review.py               # word error rate per backend, per language
```

Roughly an hour, and it either supports the shipped default or overturns it. This project's claim
on a reader's attention is that its numbers are honest; shipping while the central one is
unmeasured would undercut that more than any bug would.

### Numbers in the announcement must have replicated

Four measurements were corrected within two days of being published — the keyterm latency cost, the
digit rule being "structurally safer", a truncation attribution, and both native-Gemini figures.
Each correction was the process working, and none of them belonged in a launch post. Before quoting
a number publicly:

- It came from **two independent sessions**, not two passes of one run. `--repeat-count` varies the
  model; it does not vary the day, and several of these figures move more between days than between
  passes.
- A substitution rate from a 10–12 trial ablation is a **screening result**. Those separate models
  differing by 60 points and say nothing about differences under about 20.
- Record it — `--record eval/cassettes/<name>.json`. Replay needs the audio, which is gitignored,
  so this is not something a reader can re-run; it is every answer the provider gave, kept next to
  the score, so a later disagreement about the grading can be settled without re-billing the suite.

Then run [the checks a machine cannot do](MANUAL-CHECKS.md) — the round trip, permissions from cold,
the failure modes, and a file through the GUI. Fifteen minutes, and they cover the four things no
runner can: a microphone, a focused window in another app, a paid request, and somebody who knows
what was said. Record the result in the draft notes, including anything you did not check.
