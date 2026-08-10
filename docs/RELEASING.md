# Releasing

Releases are cut by tag. Everything else is automatic.

```bash
git tag v0.2.0
git push origin v0.2.0
```

That runs [`.github/workflows/release.yml`](../.github/workflows/release.yml), which builds all four
platforms, runs each one's tests first, and opens a **draft** GitHub release with the artifacts
attached. Read the generated notes, then publish.

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
