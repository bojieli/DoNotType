# The command line, and the log

There are two of these: the Swift `dnt` on macOS, and `dnt.exe` built from `windows/DoNotType.Cli`.
Same verbs, same flags, same two output rules — separate tools in separate languages, because a
single binary would mean one platform's core shipping inside the other's. Android and iOS have no
shell to run one from; their equivalent is the log screen and the file screen in the app.

Everything below describes both unless a line says otherwise.

Two command-line tools ship on the desktop, and they have different jobs.

| | for | when |
|---|---|---|
| **`dnt`** | using the product | transcribe a file, read the log, inspect history, check a key |
| **`dnt-eval`** | measuring the prompt | you changed `PROMPT.md` and owe the changelog a number |

`dnt-eval` is documented in [EVALUATION.md](EVALUATION.md). This file covers `dnt` and the logging
it exists to make readable.

```bash
make cli                       # .build/release/dnt
make install-cli               # installs the app, then links /usr/local/bin/dnt into the bundle
swift run dnt doctor           # from a checkout, without installing anything
```

The CLI is also inside the app bundle at `DoNotType.app/Contents/MacOS/dnt`, so a release carries
it and an installed copy finds the shipped `PROMPT.md` beside itself without a checkout anywhere.

## Two rules

**stdout is the transcript.** Progress, warnings, summaries and log lines go to stderr. So this
produces a file containing words and nothing else, even with `--verbose` on:

```bash
dnt transcribe interview.m4a > interview.txt
```

**Nothing prints a secret.** Keys are reported by source (`environment (XAI_API_KEY)`, `keychain`),
never by value, and every key the tool resolves is registered with the logger before the first
request so it cannot appear even if a provider echoes it back inside an error body.

## Configuration

`dnt` reads the app's own settings, so the two do not disagree about which backend "the" backend
is. Precedence, highest first:

1. flags — `--provider`, `--model`, `--fidelity`, `--prompt`
2. the app's preferences (`defaults read app.donottype`)
3. the fresh-install defaults

Keys resolve **environment first, then Keychain** — the opposite of the app, deliberately: a key
exported in the shell you are typing in is an instruction for this invocation, while the Keychain
entry is the standing configuration. `GEMINI_API_KEY=other-key dnt transcribe …` therefore does what
it obviously should. `--no-keychain` skips the Keychain entirely, which is what you want in CI or
when you would rather not authorise a prompt.

Your edited `PROMPT.md` is used if you have one, exactly as the app would use it. `dnt prompt path`
says which file is in force.

## `dnt transcribe` — recordings that already exist

This is the offline half of the product. Everything else in DoNotType is built around holding a key
while you speak; this takes a recording and produces the same three things the live path can.

```bash
dnt transcribe memo.m4a                          # verbatim, to stdout
dnt transcribe talk.wav --mode summary:bullets   # summary, verbatim kept
dnt transcribe *.m4a --output notes/ --save-history
dnt transcribe call.mp3 --json | jq -r .[0].verbatim
```

### Modes

| `--mode` | what it does | requests |
|---|---|---|
| `verbatim` (default) | word for word, at the chosen fidelity | 1 |
| `rewrite:formal` \| `concise` \| `bullets` | verbatim, then rewritten — never loses a fact | 2 |
| `summary:brief` \| `bullets` \| `actions` | verbatim, then summarised — this one is allowed to | 2 |

`rewrite` and `summary` alone mean `rewrite:formal` and `summary:brief`.

**The verbatim transcript is always produced.** `--json` carries both; `--output` writes the derived
text to `name.txt` and the transcript to `name.verbatim.txt` beside it. A summary you cannot check
against what was actually said is a summary you have to take on faith, which is the thing this
project exists to argue against.

Rewriting and summarising need a language model. If your backend is a recogniser (`xai`,
`deepgram`, `mistral`) the command refuses **before uploading anything** and tells you the two ways
forward — switch backend, or keep the fast recogniser and add a model for the second stage:

```bash
dnt transcribe long-meeting.m4a --mode summary:actions \
    --provider xai --text-provider gemini
```

The audio goes to xAI, the text to Gemini, and the JSON output records both.

### Formats and length

**WAV, MP3, M4A/AAC and Opus on every platform**, plus whatever else each system happens to play.
Everything is decoded to 16 kHz mono up front, which is what makes the rest work: recordings over 90
seconds are split on silence and transcribed concurrently (`--concurrency`, default 3), durations are
recorded correctly, and the upload is Opus rather than raw PCM.

How each platform gets there differs, and the differences are worth knowing when one misbehaves:

| platform | WAV | MP3, M4A, and the rest | Opus |
|---|---|---|---|
| macOS, iOS | CoreAudio | CoreAudio | CoreAudio |
| Android | `MediaExtractor` | `MediaExtractor` + `MediaCodec` | own Ogg reader + `MediaCodec` |
| Windows | managed code | Media Foundation (MP3; **not M4A**) | own Ogg reader + libopus |

Two of those are ours rather than the platform's, for the same reason in both cases — the system
would not do it everywhere the app runs:

- **Android below API 29** cannot open an Ogg container holding Opus, and this app supports API 26.
  Since `.opus` is the format the project itself *encodes* to, a file it produced could fail to open
  on a device it supports. It now demuxes Ogg itself and hands packets to `MediaCodec`, which has
  decoded Opus since API 21, so the answer is the same on every supported device.
- **Windows has no Opus decoder at all**, and libopus is already a dependency for the encode side —
  so the decode side costs a binding and an Ogg reader rather than a new dependency. MP3 and M4A go
  to Media Foundation, which is on every supported Windows.

The container is sniffed from the bytes, not the extension: a `.wav` that is really an MP3 is a
thing recorders do, and dispatching on the name would send it to the wrong reader.

**M4A does not work on Windows yet.** Media Foundation returns about a quarter of the audio — 0.4
seconds of a 1.5 second file, measured on CI — so it is left out of the file dialog and the
supported list rather than silently transcribing a fraction of a recording. Convert it, or use one
of the other three platforms:

```bash
ffmpeg -i meeting.m4a -ar 16000 -ac 1 meeting.wav
```

The test that characterises it is skipped rather than deleted, with what has already been ruled out
written down in it.

### Screen context

A file has no screen, but a *reproduction* of a dictation does. This is the loop:

```bash
dnt history show 8174a6b9 --context > context.json
dnt transcribe recording.wav --context-file context.json --mode verbatim
```

Individual fields can be supplied or overridden with `--visible-text`, `--before-caret`, `--app` and
`--window-title`. `--verify-numbers` runs the second, screen-blind pass described in
[EVALUATION.md](EVALUATION.md).

## `dnt doctor` — why is this not working

```bash
dnt doctor            # keys, prompt, history, logging, audio support
dnt doctor --probe    # plus one real request, to check the key end to end
```

Exits non-zero when it finds a problem, so it works in a health check. `--probe` costs one small
request.

## `dnt providers`

Every backend, whether a key is found and where, the model that would be used, and — the column
that matters — whether it is a language model at all. Two of the six are not, which decides whether
grounding, rewriting and summarising work.

## `dnt history`

The history is a plain JSON file by design. These are the operations that were previously only
reachable through a window:

```bash
dnt history list --query migration --status failed
dnt history show 8174a6b9              # one entry in full, both texts
dnt history retry --all                # re-send what failed, with its stored audio and context
dnt history delete 8174a6b9            # one entry and its audio
dnt history prune --older-than 30 --dry-run
dnt history path
```

`--files-only` narrows to transcripts made from recordings rather than the microphone. Offline
transcriptions land in the same history as dictations on purpose: "find that thing I said about the
migration" should not depend on remembering how it was captured.

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

### Where it goes

Every platform writes a file beside its history, at `info`, and keeps its native sink alongside it:

| | log file | also | read it in the app |
|---|---|---|---|
| **macOS** | `~/Library/Application Support/DoNotType/logs/donottype.log` | `os.Logger` → Console | Settings › Logs |
| **Windows** | `%APPDATA%\DoNotType\logs\donottype.log` | — | Settings › Logs |
| **Android** | app storage, `logs/donottype.log` | logcat | Settings › Diagnostics › Logs |
| **iOS** | the App Group container, `Logs/` | — | Settings › Diagnostics › Logs |
| **the CLIs** | none unless `DNT_LOG_FILE` is set | stderr, at `warn` | — |

A CLI does not write to the app's file by default: two processes appending would interleave and race
its rotation. The file rotates at 8 MB (4 MB on Android) and keeps exactly one previous generation.

On Android and iOS the viewer offers **share** rather than reveal, because a share sheet is how a log
reaches a bug report from a phone — there is no Console, no shell, and no way to reach a file inside
the container without plugging the device into a computer.

```bash
dnt logs                                  # last 200 lines of the app's log
dnt logs --follow --level warn
dnt logs --grep fallback --lines 1000
dnt logs --path                           # just the path, for piping into an editor
dnt logs --clear
```

In the app, Settings › Logs shows the same events live, with the recording level next to them —
turning detail up no longer means quitting and relaunching from a terminal.

### Levels

| level | what appears |
|---|---|
| `trace` | per-chunk and per-retry detail; enough to read a whole dictation from |
| `debug` | every provider request and response, the grounding route, the second stage |
| `info` | the default: what was transcribed, when a fallback fired, retention pruning |
| `warn` | degraded but recovered — a hedge fired, an encoder was missing |
| `error` | it failed and you noticed |

### Environment

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

Note that a bundle opened from Finder inherits launchd's environment, not your shell's — which is
also why the app has a level control in Settings rather than only an environment variable.

### What is never logged

**Your words.** Transcripts and screen contents are content, and content is withheld by default: a
log line says a 412-character transcript came back, not what it said. `DNT_LOG_CONTENT=1` or the
"Include transcripts" toggle in Settings › Logs opens that door, and the app says out loud when it
is open.

**Keys.** Two mechanisms, because either alone leaks. Every resolved key is registered with the
logger before the first request, so the exact bytes are masked wherever they appear — including
inside a URL or a provider's error body. Anything else key-shaped is caught by pattern: known
prefixes (`sk-`, `AIza`, `xai-`, …) and long opaque tokens. Credentials in URL query parameters are
stripped before the URL is logged at all.

**Request and response bodies.** A request body is your audio and your screen; a response body is
your transcript. What is logged is the shape: endpoint, model, bytes each way, status, duration.
That is enough to tell a rejected key from a stalled network from a model that answered instantly
with nothing.

## What the CLI is not

It does not record. Dictation needs a hotkey, a microphone permission and something to type into,
which is what the app is for. `dnt` starts where a recording already exists.
