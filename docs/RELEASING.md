# Releasing

This document describes the DoNotType release process: the tag-driven workflow, the artifacts it
produces, the package-manager manifests, the signing configuration, and the gates to run before
tagging.

## Latest successful CI build

Every fully green push to `main` updates the rolling `latest` prerelease with the macOS and Android
packages produced by that same CI run. The release links the exact commit and workflow run, verifies
each archive before promotion, and publishes a matching `.sha256` beside every app.

This is a development download surface, not a versioned release. On the upstream repository the
macOS bundle is Developer ID signed and notarized so it can be used as an everyday install; the
Android APK uses a debug key. Windows source still compiles in CI, but no Windows production layout
is built or distributed until it has been manually verified and Authenticode signing is available.
Forks without Apple secrets still exercise the same macOS bundle and launch checks with an ad-hoc
signature, but cannot publish the upstream `latest` release. The moving `latest` tag is updated only
after every CI job succeeds; stable `v*` tags are never moved or overwritten.

## Tag-driven releases

Releases are cut by tag. Everything else is automatic.

```bash
git tag v0.2.0
git push origin v0.2.0
```

Pushing a tag runs [`.github/workflows/release.yml`](../.github/workflows/release.yml), which builds
macOS and Android release artifacts, and opens a **draft** GitHub release with the artifacts
attached. The iOS UI suite still runs asynchronously for version-stamped diagnostics, but iOS is
not shipped and therefore does not hold publication behind the simulator test. Read the generated
notes, then publish.

### Version stamping

Each job stamps the version into its own checkout first, with
[`scripts/stamp-version.sh`](../scripts/stamp-version.sh). Four platforms keep four version fields,
and a release that stamps only some of them turns every bug report into a question about which
build it came from. The tag is the only source; nothing is committed back.

Versions use canonical `x.y.z` numbers. Minor and patch are limited to `0`–`99` because the Apple
build number and Android version code reserve two decimal places for each; the stamping script
rejects a value that would collide or exceed Android's numeric limit.

Three numbers and nothing else. No leading `v` — the tag is `v0.2.0`, the version is `0.2.0` — and
no `-rc1` or `+build` suffix: `CFBundleVersion` and `versionCode` are integers computed from those
three numbers, so a suffix has nowhere to go on two of the four platforms. To ship a candidate, use
an ordinary version and mark the GitHub release itself as a pre-release, which is a property of the
release rather than of the number every client reports. A `Version` job validates the string before
any platform builds, so a mistyped input costs one runner instead of failing all four.

### Dry runs

To exercise the packaging without cutting a release, run the workflow manually from the Actions tab
with **publish** unchecked. This builds and uploads everything as workflow artifacts and creates no
release.

Checking **publish** on a manual run is intentionally a release action: after the signed macOS and
Android jobs pass, it creates `v<version>` at the exact tested commit and opens the same draft release
a pushed tag would. The asynchronous iOS test may still be running when that draft appears; its
result remains visible in the workflow and does not produce a release asset. Leave publish unchecked
for an ordinary packaging rehearsal.

## Release artifacts

| artifact | contents |
|---|---|
| `DoNotType-macOS.zip` | the `.app` bundle |
| `DoNotType-Android.apk` | installable APK |
| `*.sha256` | one per artifact |

Every downloadable app also receives a GitHub artifact attestation in its platform build job. The
attestation binds the artifact's digest to this repository, workflow, commit, and runner identity;
it is stored by GitHub rather than copied into the release assets. After downloading an artifact:

```bash
gh attestation verify DoNotType-macOS.zip --repo bojieli/DoNotType
```

The checksum detects a damaged or substituted file when compared with the release page. The
attestation additionally proves which repository workflow produced that digest.

### iOS

iOS is **built but not shipped**. Distributing it requires a provisioning profile and App Store
Connect, which is an account decision rather than a packaging one, and an unsigned `.app` that
nobody can install is not a release artifact. The release workflow runs the UI suite asynchronously
for diagnostics and version coverage; the signed macOS and Android jobs are the publication gate.
Normal main-branch CI still runs the full iOS suite as regression coverage.

## Package managers

Manifests live in [`packaging/`](../packaging/) and are **not** submitted yet. Homebrew onboarding
should follow a notarized macOS release with some public history. The winget drafts remain dormant:
there is no Windows release artifact for them to reference until Windows production verification
and Authenticode signing exist.

After a release is published:

```bash
./scripts/update-packaging.sh 0.2.0
```

The script reads the macOS `.sha256` file the workflow published and writes the version and checksum
into the Homebrew cask. No hash is typed by hand: a cask with a stale checksum fails at install with
a complaint about a corrupt download, which reads as something far more alarming than a forgotten
field. It deliberately does not update the dormant winget drafts.

Submission is deliberately manual, because each submission is a pull request to somebody else's
repository:

| | where |
|---|---|
| Homebrew | copy `packaging/homebrew/donottype.rb` into the tap's `Casks/` |
| winget | unavailable until a verified, Authenticode-signed Windows artifact is restored |

## Signing

A dry run — `workflow_dispatch` with `publish=false` — needs no secrets and still produces working
artifacts. This is deliberate: a fork should be able to exercise the complete packaging path. Those
artifacts are ad-hoc or development-signed depending on the platform and are suitable for testing
rather than an official public release:

- **macOS** refuses to open an ad-hoc-signed app normally, and because TCC keys permissions to the
  code signature, every update makes the system forget the Accessibility grant, forcing it to be
  re-granted on every release.
- **Android** falls back to a debug key. The APK installs from a file, but a debug-signed APK can
  never be updated in place by a differently-signed one; each update requires an uninstall and
  loses the history each time.

Configuring the following repository secrets enables release signing. Values within a group must
be set together; the workflow fails early on a partial configuration rather than silently producing
the wrong signature.

Signing is **required**, not merely recommended, for any run that can reach users: a `v*` tag push,
or a manual run with `publish=true`. Those runs fail in their first step when a platform's signing
configuration is absent. A manual run with `publish=false` still builds test-signed artifacts, so a
fork can exercise the complete packaging path without holding any credential.

| secret | what it is |
|---|---|
| `MACOS_CERTIFICATE` | Developer ID Application `.p12`, base64-encoded |
| `MACOS_CERTIFICATE_PASSWORD` | its export password |
| `NOTARY_KEY_ID` | App Store Connect **Team** key ID |
| `NOTARY_ISSUER_ID` | App Store Connect issuer ID |
| `NOTARY_KEY` | the `.p8` private key, verbatim — not base64 |
| `ANDROID_KEYSTORE` | upload keystore, base64-encoded |
| `ANDROID_KEYSTORE_PASSWORD` | its password |
| `ANDROID_KEY_ALIAS` | key alias inside the keystore |
| `ANDROID_KEY_PASSWORD` | optional separate key password; defaults to the keystore password |

Base64-encode the two binary file secrets with:

```bash
base64 -i DeveloperID.p12 | pbcopy
base64 -i release.keystore | pbcopy
```

The App Store Connect key must be a **Team** key with the Developer role. Individual keys are not
eligible for the Notary API and fail with an unhelpful `401`. Validate it before loading it, so a
bad credential surfaces in seconds instead of at the end of a release build:

```bash
xcrun notarytool history --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>
```

Notarization runs only when the complete notary group is set and requires the macOS certificate.
The workflow validates the stapled ticket. Android verifies the APK's signature and stamped version
before upload.

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
