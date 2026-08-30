# CLI and logging reference

This document is the reference for the `dnt` command-line tools and for the logging facility they
share with the apps. Two implementations exist: the Swift `dnt` on macOS, and `dnt.exe` built from
`windows/DoNotType.Cli`. They have the same verbs, the same flags, and the same two output rules,
but they are separate tools in separate languages, because a single binary would require one
platform's core to ship inside the other's. Android and iOS have no shell to run a CLI from; their
equivalents are the log screen and the file screen in the app.

Everything below describes both implementations unless a line says otherwise.

Two command-line tools ship on the desktop, with different jobs:

| | for | when |
|---|---|---|
| **`dnt`** | using the product | transcribe a file, read the log, inspect history, check a key |
| **`dnt-eval`** | measuring the prompt | you changed a file in `prompt/` and owe the changelog a number |

`dnt-eval` is documented in [EVALUATION.md](EVALUATION.md). This document covers `dnt` and the
logging it exists to make readable.

## Building and running

```bash
make cli                       # .build/release/dnt
make install-cli               # installs the app, then links /usr/local/bin/dnt into the bundle
swift run dnt doctor           # from a checkout, without installing anything
```

The CLI is also inside the app bundle at `DoNotType.app/Contents/MacOS/dnt`, so a release carries
it and an installed copy finds the shipped `prompt/` beside itself without a checkout anywhere.

## Output rules

**stdout is the transcript.** Progress, warnings, summaries and log lines go to stderr. Therefore
the following produces a file containing words and nothing else, even with `--verbose` on:

```bash
dnt transcribe interview.m4a > interview.txt
```

**Nothing prints a secret.** Keys are reported by source (`environment (XAI_API_KEY)`, `keychain`),
never by value, and every key the tool resolves is registered with the logger before the first
request so it cannot appear even if a provider echoes it back inside an error body.

## Configuration

`dnt` reads the app's own settings, so the CLI and the app do not disagree about which backend is
"the" backend. Precedence, highest first:

1. flags — `--provider`, `--model`, `--fidelity`, `--prompt`
2. the app's preferences (`defaults read app.donottype`)
3. the fresh-install defaults

Keys resolve **environment first, then Keychain** — the opposite of the app, deliberately: a key
exported in the shell in use is an instruction for that invocation, while the Keychain entry is the
standing configuration. `GEMINI_API_KEY=other-key dnt transcribe …` therefore overrides the stored
key for that invocation. `--no-keychain` skips the Keychain entirely, which is the correct choice
in CI or when authorising a Keychain prompt is undesirable.

Edited prompt files are used wherever they exist, exactly as the app would use them. `dnt prompt
path` lists all twelve and says which file is in force for each; `dnt prompt validate` checks that
every one of them still resolves.

## `dnt transcribe` — existing recordings

This command is the offline half of the product. Everything else in DoNotType is built around
holding a key while speaking; `dnt transcribe` takes an existing recording and produces the same
three outputs the live path can.

```bash
dnt transcribe memo.m4a                          # verbatim, to stdout
dnt transcribe talk.wav --mode summary:bullets   # summary, verbatim kept
dnt transcribe *.m4a --output notes/ --save-history
dnt transcribe call.mp3 --json | jq -r .[0].verbatim
dnt transcribe standup.m4a --mode translate:English  # spoken Mandarin, written English
```

### Modes

| `--mode` | what it does | requests |
|---|---|---|
| `verbatim` (default) | word for word, at the chosen fidelity | 1 |
| `rewrite:formal` \| `concise` \| `casual` | verbatim, then rewritten — never loses a fact | 2 |
| `summary:brief` \| `bullets` \| `actions` | verbatim, then summarised — this one is allowed to | 2 |
| `translate:<language>` | verbatim, then written again in that language | 1–2 ¹ |

`rewrite` and `summary` alone mean `rewrite:casual` and `summary:brief`. A bare `translate` is
rejected: every other stage has an obvious default, and "into what?" has none — picking English
would be this project choosing a language on somebody's behalf.

The language is free text, spelled however you would say it — `translate:English`,
`translate:简体中文`, `translate:"Brazilian Portuguese"`. It is not enumerated for the same reason a
model ID is not: the model is the authority on which languages it can write, and a list here would
be a list of the ones we happened to think of.

¹ One request on a model backend, which returns the verbatim transcript and the translation
together; two on a speech recogniser, which cannot.

**The verbatim transcript is always produced.** `--json` carries both; `--output` writes the derived
text to `name.txt` and the transcript to `name.verbatim.txt` beside it. Rationale: a summary that
cannot be checked against what was actually said has to be taken on faith, which is the failure
mode this project exists to prevent.

### Output naming

With more than one recording, `--output` is a directory and each transcript is named after its
source. Two sources that want the same name keep their extension to tell them apart — `speech.wav`
and `speech.mp3` become `speech.txt` and `speech.mp3.txt` — and two with the *same* name in
different folders are numbered in the order given on the command line. The names are worked out
before the first request, so a collision cannot cost the file it would have overwritten.
Historical note: this previously overwrote silently and reported success twice.

### Two-stage backends

Rewriting and summarising need a language model. If the selected backend is a recogniser (`xai`,
`deepgram`, `mistral`) the command refuses **before uploading anything** and reports the two ways
forward — switch backend, or keep the fast recogniser and add a model for the second stage:

```bash
dnt transcribe long-meeting.m4a --mode summary:actions \
    --provider xai --text-provider google
```

The audio goes to xAI's speech endpoint, the text to Google, and the JSON output records both.
`--text-provider xai` also works, and keeps both stages on one key: xAI serves Grok chat models
alongside its recogniser. Older names still resolve, so `--provider gemini` remains valid.

### Formats and length

Supported on every platform: **WAV, MP3, M4A/AAC and Opus**, plus whatever else each system happens
to play. Everything is decoded to 16 kHz mono up front, which is what makes the rest work:
recordings over 90 seconds are split on silence and transcribed concurrently (`--concurrency`,
default 3), durations are recorded correctly, and the upload is Opus rather than raw PCM.

The decode path differs per platform; the differences matter when one misbehaves:

| platform | WAV | MP3, M4A, and the rest | Opus |
|---|---|---|---|
| macOS, iOS | CoreAudio | CoreAudio | CoreAudio |
| Android | `MediaExtractor` | `MediaExtractor` + `MediaCodec` | own Ogg reader + `MediaCodec` |
| Windows | managed code | Media Foundation | own Ogg reader + libopus |

Two of these decoders are the project's own rather than the platform's, for the same reason in both
cases — the system would not do it everywhere the app runs:

- **Android below API 29** cannot open an Ogg container holding Opus, and this app supports API 26.
  Since `.opus` is the format the project itself *encodes* to, a file it produced could fail to open
  on a device it supports. The app now demuxes Ogg itself and hands packets to `MediaCodec`, which
  has decoded Opus since API 21, so the behaviour is the same on every supported device.
- **Windows has no Opus decoder at all**, and libopus is already a dependency for the encode side —
  so the decode side costs a binding and an Ogg reader rather than a new dependency. MP3 and M4A go
  to Media Foundation, which is present on every supported Windows.

The container is sniffed from the bytes, not the extension: a `.wav` that is really an MP3 is a
thing recorders produce, and dispatching on the name would send it to the wrong reader.

One decoder quirk is documented because it produced a bug that looked like nothing: an AAC decoder
advertises a default output format before it has parsed the stream — 32 kHz stereo for a file that
is 16 kHz mono — and corrects itself on the first read. Code that believes the first answer
converts every buffer with the wrong sample rate, which is not an error, just wrong. Measured: a
1.5 second file came out at 0.4 seconds, and nothing anywhere reported it.

### Screen context

A file has no screen, but a *reproduction* of a dictation does. The loop:

```bash
dnt history show 8174a6b9 --context > context.json
dnt transcribe recording.wav --context-file context.json --mode verbatim
```

Individual fields can be supplied or overridden with `--visible-text`, `--before-caret`, `--app`
and `--window-title`.

## `dnt doctor` — diagnosis

```bash
dnt doctor            # keys, prompt, history, logging, audio support
dnt doctor --probe    # plus one real request, to check the key end to end
```

Exits non-zero when it finds a problem, so it works in a health check. `--probe` costs one small
request: a quarter-second of silence, sent as audio to every backend, so an endpoint that speaks
the API but cannot take a recording is caught here rather than on the first real dictation.

## `dnt providers`

Lists every backend, whether a key is found and where, the model that would be used, and — the
column that matters — whether it is a language model at all. Two of the six are not, which decides
whether grounding, rewriting and summarising work.

## `dnt history`

The history is a plain JSON file by design. These subcommands expose operations that were
previously only reachable through a window:

```bash
dnt history list --query migration --status failed
dnt history show 8174a6b9              # one entry in full, both texts
dnt history retry --all                # re-send what failed, with its stored audio and context
dnt history delete 8174a6b9            # one entry and its audio
dnt history prune --older-than 30 --dry-run
dnt history path
```

`--files-only` narrows to transcripts made from recordings rather than the microphone. Offline
transcriptions land in the same history as dictations on purpose: finding "that thing said about
the migration" should not depend on remembering how it was captured.

## `dnt prompt`

```bash
dnt prompt show --section system --fidelity tidy    # the exact text a request will carry
dnt prompt show --section summary --summary actions
dnt prompt validate                                 # every block and placeholder resolves
dnt prompt path                                     # shipped, or your edited copy
```

`show` expands the placeholders, so what it prints is what gets sent rather than the template.

## Logging

Everything logs through one facility in `DoNotTypeCore`, so the app, the CLI and the eval harness
behave the same way.

### Destinations

Every platform writes a file beside its history, at `info`, and keeps its native sink alongside it:

| | log file | also | read it in the app |
|---|---|---|---|
| **macOS** | `~/Library/Application Support/DoNotType/logs/donottype.log` | `os.Logger` → Console | Settings › Logs |
| **Windows** | `%APPDATA%\DoNotType\logs\donottype.log` | — | Settings › Logs |
| **Android** | app storage, `logs/donottype.log` | logcat | Settings › Diagnostics › Logs |
| **iOS** | the App Group container, `Logs/` | — | Settings › Diagnostics › Logs |
| **the CLIs** | none unless `DNT_LOG_FILE` is set | stderr, at `warn` | — |

A CLI does not write to the app's file by default: two processes appending would interleave and
race its rotation. The file rotates at 8 MB (4 MB on Android) and keeps exactly one previous
generation.

On Android and iOS the viewer offers **share** rather than reveal, because a share sheet is how a
log reaches a bug report from a phone — there is no Console, no shell, and no way to reach a file
inside the container without plugging the device into a computer.

### `dnt logs`

```bash
dnt logs                                  # last 200 lines of the app's log
dnt logs --follow --level warn
dnt logs --grep fallback --lines 1000
dnt logs --path                           # just the path, for piping into an editor
dnt logs --clear
```

In the app, Settings › Logs shows the same events live, with the recording level next to them —
raising the level no longer requires quitting and relaunching from a terminal.

### Following one dictation

Every stage logs, and every line carries a `dictation=` id — the first eight characters of the
history row's id, so the two can be lined up. A log containing three dictations is three
interleaved sequences, and the question being investigated is always about one of them.

```bash
dnt logs --grep 3f9c1a20
```

```
INFO  dictate  recording started    dictation=3f9c1a20 mode=hold provider=xai model=grok-stt …
INFO  dictate  recording finished   dictation=3f9c1a20 seconds=4.20 bytes=134444
INFO  dictate  transcribing         dictation=3f9c1a20 grounded=yes contextChars=812 app=Mail
DEBUG http     request              bytes=41220 model=grok-stt provider=xai url=https://api.x.ai/v1/stt
DEBUG http     response             status=200 bytes=612 ms=1809
INFO  dictate  transcript received  dictation=3f9c1a20 chars=126 chunks=1 audioTokens=210 ms=1809
INFO  inject   inserting            dictation=3f9c1a20 chars=126 app=Mail accessibility=granted
INFO  dictate  dictation complete   dictation=3f9c1a20 chars=126 totalMs=2140
```

Three log lines exist for questions users actually ask rather than for completeness:

- **`recording too short to send`** — "I pressed the key and nothing happened" is usually a tap
  rather than a hold, and it used to be silent.
- **`nothing was said`** — a silent recording produces an empty transcript, which reads as a
  failure. It is not one, and the log now says so.
- **`inserting … accessibility=MISSING`** — "it transcribed but nothing appeared" is a different
  failure from "it did not transcribe", and from outside they look identical. A paste sent without
  Accessibility is not refused, it is ignored.

### Levels

| level | what appears |
|---|---|
| `trace` | per-chunk and per-retry detail; enough to read a whole dictation from |
| `debug` | every provider request and response, the grounding route, the second stage |
| `info` | the default: what was transcribed, when a fallback fired, retention pruning |
| `warn` | degraded but recovered — a hedge fired, an encoder was missing |
| `error` | it failed and you noticed |

### Environment variables

Every desktop executable honours these, including the app when it is launched from a shell. Android
and iOS have no environment to set, which is why the level is a setting there — and on Windows for
the same reason, since a WinExe launched from Explorer inherits no shell environment either:

| | |
|---|---|
| `DNT_LOG_LEVEL` | `trace`, `debug`, `info`, `warn`, `error`, `off` |
| `DNT_LOG_FILE` | a path to append to, or `none` to turn the file off |
| `DNT_LOG_STDERR` | `1` to also write to stderr |
| `DNT_LOG_JSON` | `1` for one JSON object per line |
| `DNT_LOG_CONTENT` | `1` to include transcripts and screen text — see below |

```bash
DNT_LOG_LEVEL=debug dnt transcribe memo.wav
DNT_LOG_JSON=1 DNT_LOG_LEVEL=debug dnt transcribe memo.wav 2>&1 >/dev/null | jq -r .message
```

A bundle opened from Finder inherits launchd's environment, not the shell's — which is also why the
app has a level control in Settings rather than only an environment variable.

### Content withheld from logs

**Transcripts and screen contents.** These are content, and content is withheld by default: a log
line says a 412-character transcript came back, not what it said. `DNT_LOG_CONTENT=1` or the
"Include transcripts" toggle in Settings › Logs opens that door, and the app indicates visibly
when it is open.

**Keys.** Two mechanisms, because either alone leaks. Every resolved key is registered with the
logger before the first request, so the exact bytes are masked wherever they appear — including
inside a URL or a provider's error body. Anything else key-shaped is caught by pattern: known
prefixes (`sk-`, `AIza`, `xai-`, …) and long opaque tokens. Credentials in URL query parameters are
stripped before the URL is logged at all.

**Request bodies, and the response body of anything that worked.** A request body is the audio and
the screen contents; a successful response body is the transcript. What is logged is the shape:
endpoint, model, bytes each way, status, duration.

**The one exception is a failed response**, which is logged in full at `warn`. A 4xx or 5xx body
contains no audio and no transcript — it contains the provider saying which field it rejected and
why, which is the single most useful thing for diagnosing a failure and is gone by the time anybody
thinks to turn on `debug`. Registered keys are still masked inside it, as everywhere else.

## Scope of the CLI

The CLI does not record. Dictation needs a hotkey, a microphone permission and something to type
into, which is what the app is for. `dnt` starts where a recording already exists.

## See also

- [EVALUATION.md](EVALUATION.md) — the `dnt-eval` tool and the measurement workflow
- [PARITY.md](PARITY.md) — feature parity across platforms
- [ARCHITECTURE.md](ARCHITECTURE.md) — how the apps and cores are organised
