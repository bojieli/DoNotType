# Security

## What this app can see

DoNotType is a dictation tool that reads your screen. That is the feature, and it deserves a plain
description rather than a reassuring one.

When you dictate, it may send to your chosen model provider:

- the recording,
- the visible text of the focused window (up to 10,000 characters),
- the text either side of your cursor (1,000 characters each way),
- the app name, window title, and browser URL,
- a screenshot of the focused window, **only** when the accessibility tree returns too little text
  to be useful.

It does **not** send: anything from unfocused windows, anything while you are not dictating,
anything from an app or URL on the blocklist, or any stored history.

## What it never does

- **No server of ours.** Requests go directly from your machine to the provider you configured,
  with your key. There is no DoNotType backend, no telemetry, no analytics, no crash reporting.
- **No third-party recipients.** The only outbound host is your provider's API.
- **`store: false`** is set on every Gemini request, so the provider is asked not to retain it.

## Where secrets live

| Platform | API key storage |
|---|---|
| macOS | Keychain (`app.donottype`) |
| iOS | Keychain |
| Windows | DPAPI, scoped to your Windows account |
| Android | app-private `SharedPreferences` |

Android is the weakest of these and it is worth saying so: there is no Keychain equivalent an IME
can reach without a foreground activity. The file is readable only by this app's UID, which is
weaker than the others and stronger than a plaintext config file.

Keys are never written to the settings file in plaintext, never logged, and never included in an
error message.

## The blocklist

Evaluated **before** capture, never after — filtering a context you already collected still means
the text was in the process's memory. It ships non-empty (password managers, banking, credential
prompts) and is re-checked once a browser URL is known, so a login page inside an allowed browser
is still excluded.

Ship-blocking bugs in this area are the ones we most want reported.

## Permissions, and why each is needed

| Permission | Why | Optional? |
|---|---|---|
| Accessibility (macOS) | see the hotkey; paste into the focused app; read screen text | no |
| Microphone | record while you hold the key | no |
| Screen Recording | capture the focused window when accessibility text is unavailable | yes |

macOS revokes Accessibility whenever an app's code signature changes, so the app re-checks at every
launch rather than once.

## Reporting a vulnerability

Please **do not open a public issue** for anything involving key handling, blocklist bypass, or
data leaving the machine unexpectedly.

Email the maintainer at the address in the git history, with:

- what you did,
- what was sent or exposed,
- the version or commit.

You will get an acknowledgement within a few days. There is no bounty programme; this is a personal
open-source project.

## Threat model, honestly stated

**In scope:** the app sending more than the user expects, sending it somewhere unexpected, leaking
a key, or bypassing the blocklist.

**Out of scope:** an attacker who already controls your machine. A dictation tool with Accessibility
access cannot defend against local root, and pretending otherwise would be dishonest.

**Known and unresolved:** text on your screen is untrusted input that reaches a model. The prompt
treats it as data and an integration test asserts that imperative screen text is not obeyed, but
prompt injection is not a solved problem and this app's design surface for it is unusually direct.
The blocklist and the Context Inspector exist so you can see and limit what is exposed.
