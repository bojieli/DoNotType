# Security

This document describes the security properties of DoNotType: what data the app can access and
send, what it never does, where API keys are stored, the blocklist, per-platform permissions,
vulnerability reporting, and the threat model.

## Data the app can see

DoNotType is a dictation tool that reads the screen. That is the feature, and it is described
here plainly.

When dictation is active, the app may send to the configured model provider:

- the recording,
- the visible text of the focused window (up to 10,000 characters),
- the text either side of the cursor (1,000 characters each way),
- the app name, window title, and browser URL,
- a screenshot of the focused window, **only** when the accessibility tree returns too little text
  to be useful,
- personal-dictionary entries, when any have been added or learned, as a spelling-only reference.

The app does **not** send: anything from unfocused windows, anything while dictation is not
active, anything from an app or URL on the blocklist, any password/secure control contents, or any
stored history. Dictation into a password field is still possible, but it runs without screen
grounding.

If correction learning is enabled, the app also reads the exact editable target where it just
inserted text for up to one minute. This is local observation, not another provider request.
Password/secure fields are excluded and moving to a different field ends observation. On macOS,
Windows and Android, the text before and after the insertion remains in memory only for that
one-minute comparison; it is never persisted or sent and is discarded when observation ends. Only
classifier-approved spelling or capitalisation fixes are stored. On iOS the keyboard can check
this only while it is active, so it persists just 32 characters on each side across a keyboard
switch rather than storing the surrounding document.

## What the app never does

- **No first-party server.** Requests go directly from the user's machine to the configured
  provider, with the user's key. There is no DoNotType backend, no telemetry, no analytics, no
  crash reporting.
- **No third-party recipients.** The only outbound host is the provider's API.
- **`store: false`** is set on every Gemini request, so the provider is asked not to retain it.

## Secret storage

| Platform | API key storage |
|---|---|
| macOS | Keychain (`app.donottype`) |
| iOS | Keychain |
| Windows | DPAPI, scoped to the Windows account |
| Android | AES-GCM ciphertext; key is non-exportable in Android Keystore |

Android migrates the old app-private plaintext preference in place after the first successful
Keystore write. It never falls back to plaintext for a new key if secure storage is unavailable.

Keys are never written to the settings file in plaintext, never logged, and never included in an
error message.

## Blocklist

The blocklist is evaluated **before** capture, never after — filtering a context that was already
collected still means the text was in the process's memory. It ships non-empty (password managers,
banking, credential prompts) and is re-checked once a browser URL is known, so a login page inside
an allowed browser is still excluded.

Ship-blocking bugs in this area are the highest priority for reporting.

## Permissions

| Permission | Why it is needed | Optional? |
|---|---|---|
| Accessibility (macOS) | see the hotkey; paste into the focused app; read screen text | no |
| Microphone | record while the key is held | no |
| Screen Recording | capture the focused window when accessibility text is unavailable | yes |

macOS revokes Accessibility whenever an app's code signature changes, so the app re-checks at
every launch rather than once.

## Reporting a vulnerability

Do **not** open a public issue for anything involving key handling, blocklist bypass, or data
leaving the machine unexpectedly.

Email the maintainer at the address in the git history, with:

- what was done,
- what was sent or exposed,
- the version or commit.

An acknowledgement follows within a few days. There is no bounty programme; this is a personal
open-source project.

## Threat model

**In scope:** the app sending more than the user expects, sending it somewhere unexpected, leaking
a key, or bypassing the blocklist.

**Out of scope:** an attacker who already controls the machine. A dictation tool with
Accessibility access cannot defend against local root.

**Known and unresolved:** text on the screen is untrusted input that reaches a model. The prompt
treats it as data and an integration test asserts that imperative screen text is not obeyed, but
prompt injection is not a solved problem and this app's design surface for it is unusually direct.
The blocklist and the Context Inspector exist so the user can see and limit what is exposed.
