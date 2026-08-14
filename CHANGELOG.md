# Changelog

Notable changes, newest first. Behaviour changes that affect transcription quality carry the
measurement that justified them; see [docs/EVALUATION.md](docs/EVALUATION.md).

Format loosely follows [Keep a Changelog](https://keepachangelog.com/). This project has not cut a
release yet, so everything below is unreleased.

## Unreleased

### Added

- **Offline transcription of recordings that already exist, in the GUI and a new `dnt` CLI.** The
  app could only transcribe speech it had just recorded, which left every recording already on disk
  — a voice memo, a call, an interview — outside a tool built for turning speech into text.
  **Transcribe a Recording…** in the menu takes a file or a drop; `dnt transcribe interview.m4a`
  does the same from a shell and writes the transcript to stdout so it can be piped.

  Everything needed already existed in the core. What was missing, and is now `AudioDecoder`, is the
  front of the pipeline: a recording made by anything other than this app is 44.1 kHz stereo AAC,
  and three things downstream assume 16 kHz mono PCM — the chunker cannot split a compressed file,
  so a 40-minute recording would go out as one request; `durationSeconds` returns nil, so the
  history row records a zero-length dictation; and the Opus encoder cannot compress the upload.
  Decoding once at the front fixes all three at far faster than real time.

- **Three modes, in both places: verbatim, rewrite, summary.** Verbatim and rewrite are what the
  hotkey already did. Summary is new, and is deliberately **not** a rewrite style: rule 1 of the
  rewrite block is *never remove a fact*, a summary is defined by removing facts, and a summary
  style sitting in that list would be one entry quietly exempt from the block's first rule. It gets
  its own block in `PROMPT.md`, its own type, and no path to it from a rewrite.

  The verbatim transcript is produced and stored first in every mode, including summaries — the GUI
  puts it behind a toggle, `--output` writes it to `name.verbatim.txt` beside the result, and
  `--json` carries both. A summary you cannot check against what was said is one you have to take on
  faith, which is the thing this project exists to argue against.

  Rewriting and summarising need a language model, so a recognition backend cannot do them. That is
  now refused **before any audio is uploaded**, with the two ways forward in the message — and
  `--text-provider` splits the work, sending audio to the fast recogniser and text to a model.

- **`dnt`, a CLI for using the product** — distinct from `dnt-eval`, which measures the prompt. It
  transcribes files, and answers the questions that previously required opening the app or reading
  the source: `dnt doctor --probe` (keys, prompt, history, audio support, one live request),
  `dnt providers` (which backends have a key, and which are language models at all), `dnt history
  list|show|retry|prune`, `dnt logs --follow`, `dnt prompt show` (the exact instruction a request
  will carry, placeholders expanded).

  It reads the app's own settings and Keychain entries, so the two cannot disagree about which
  backend "the" backend is — and keys resolve environment-first, so
  `GEMINI_API_KEY=other dnt transcribe …` does what it obviously should. stdout is the transcript
  and nothing else; every diagnostic goes to stderr. It ships inside the app bundle, so a release
  carries it and an installed copy finds `PROMPT.md` beside itself.

- **Structured logging, with a file and a viewer.** The app used `os.Logger` directly, which is the
  right transport and a bad interface for a tool people are expected to debug. Four things were
  missing: a level you can turn up, a file you can attach to an issue, anything at all in
  `DoNotTypeCore` — where every interesting decision happens and there were two log lines in the
  whole target — and a redaction rule, without which none of the above is safe to share.

  Now: levels (`trace`…`off`), sinks for file, stderr and `os.Logger` together (so Console keeps
  working), rotation at 8 MB, JSON lines for `jq`, an in-memory buffer behind **Settings › Logs**,
  and `DNT_LOG_LEVEL` / `DNT_LOG_FILE` / `DNT_LOG_STDERR` / `DNT_LOG_JSON` / `DNT_LOG_CONTENT`
  honoured by every executable. At `debug` every provider request, the grounding route each backend
  was given, every retry with its transient/permanent verdict, and every fallback is a line.

  **Your words and your keys never reach it.** Transcripts and screen text are content and are
  withheld by default — a line says a 412-character transcript came back, not what it said — with
  `DNT_LOG_CONTENT=1` as the one door, which the app says out loud when it is open. Keys are masked
  two ways, because either alone leaks: every resolved key is registered before the first request so
  the exact bytes are caught wherever they appear, including inside a provider's error body, and
  anything else key-shaped is caught by pattern. Request and response bodies are never logged, only
  their shape.

  One provider-level refactor came with it: all six backends repeated the same four lines opening a
  request and casting the response, so that is now one `URLSession.send`, which is also the one
  place a request can be logged.

**All four platforms have it.** The logging facility, the three modes and offline file
transcription are on macOS, iOS, Android and Windows; `PROMPT.md` is copied into every bundle at
build time, so no platform can drift on the summary block's text. Three differences are real and
deliberate:

- **A CLI exists on macOS and Windows only.** Android and iOS have no shell to run one from. The
  two are separate tools in separate languages rather than one ported binary, and they take the
  same verbs, flags and output rules — stdout is the transcript, stderr is everything else.
- **Every client reads WAV, MP3, M4A/AAC and Opus.** Two of those routes are ours rather than the
  platform's, and for the same reason both times — the system would not do it everywhere the app
  runs. Android below API 29 cannot open an Ogg container holding Opus and this app supports API 26,
  which meant a file the project itself *encodes* could fail to open on a device it supports; it now
  demuxes Ogg itself and hands packets to `MediaCodec`, which has decoded Opus since API 21. Windows
  has no Opus decoder at all, so it demuxes the same way and decodes through libopus — already a
  dependency for the encode side, so this cost a binding rather than a new one. MP3 and M4A on
  Windows go through Media Foundation.

  The container is sniffed from the bytes rather than the extension, because a `.wav` that is really
  an MP3 is a thing recorders do.

  Fixtures live in `eval/audio/formats/` and are shared by all four suites rather than copied into
  each. They carry speech rather than silence deliberately: a decoder that drops every sample still
  returns the right *length* of silence, so a silent fixture cannot tell a working decoder from one
  that produced nothing — the tests assert the output is audible as well as the right length.
- **The log surface differs by what each platform has.** macOS and Windows reveal a file; Android
  and iOS share it, because on a phone a share sheet is how a log reaches a bug report and there is
  no Console or shell to reach it any other way. Every platform keeps its native sink alongside the
  file — `os.Logger`, logcat — so anything that already worked still does.

- **The suite can be re-run for free.** `dnt-eval --record` writes down what each backend said;
  `--replay` feeds it back with no network and no key. Every take is kept in order so the per-pass
  spread — this suite's own noise floor — survives, and the system instruction is part of the
  request key, so editing `PROMPT.md` misses every take rather than answering for a prompt that did
  not produce it. CI replays on every push once a cassette is committed.

- **Everything a first contributor needs.** Issue forms that ask for the three things a
  transcription report needs, a PR template that asks for numbers when quality is touched, a code of
  conduct whose one non-boilerplate clause is that claims here are settled by measurement, a
  [manual checklist](docs/MANUAL-CHECKS.md) for the four things no runner can do, and
  [what this project will never do](README.md#what-this-will-never-do).

- **CI runs what ships.** Both CLIs are built and executed, the macOS app is launched and has to
  still be alive and to have logged its own startup, and the Windows core tests run on Windows —
  where they immediately found two real bugs in the Media Foundation interop and a third that is now
  documented rather than silently truncating audio.

### Fixed

- **The app never passed the environment to `ProviderFactory`, so several documented variables did
  nothing.** Every caller that already had a key — from the Keychain or a settings field — wrote
  `make(kind, environment: [envVar: key])`, and that dictionary *replaces* the environment rather
  than adding to it. So `DNT_LOCAL_BASE_URL` was ignored and a self-hosted server was always assumed
  to be on `localhost:8000`, and `DNT_DEEPGRAM_LANGUAGE` was ignored — which the settings panel
  tells Chinese-speaking users to set, advice that could not have worked. There is now a
  `make(_:apiKey:)` overload that merges instead of replacing, and every call site uses it.

  Found by the new logging: the request line reports the URL, and it said `localhost:8000` while
  `DNT_LOCAL_BASE_URL` pointed somewhere else.

### Changed

- **Keyterm biasing is no longer offered in settings.** Measured, it made transcripts worse: 3
  regressions per evaluation run, because the terms it extracts are whatever is on screen — on
  `real-acronym` that is `GRPO` and `PPO` while the speaker said `DAPO`. It also yields nothing for
  60% of realistic screen contexts, 73% in Chinese, and nothing at all from a screenshot. The
  setting and the code remain so the finding stays reproducible; the switch is gone.

- **Two corrected figures for native Gemini.** Latency is not 5–60 s bimodal and it is not
  throttling — spacing requests 25 s apart does not help and no quota headers are returned. It
  measures 14–17 s on the 22-second reference clip, against the 35.75 s published from one bad
  window. And the reference-clip substitution rate does not replicate between sessions (8% vs 18%
  grounded, 30% vs 0% ungrounded), so that clip cannot support a claim either way for 3.6. The
  cross-model comparison survives, because 3.7 sits far outside 3.6's range in every session.

- **Gemini thinking level is chosen per model family, not hardcoded.** `gemini-3.7-flash` rejects
  `minimal` — *"Allowed values are: medium, low, high"* — so every request failed the moment the
  model field was changed to it, on all three platforms at once. The level is now the cheapest each
  family accepts, prefix-matched so a point release inherits its floor rather than silently costing
  thinking tokens on every dictation.

  Measuring the new model while fixing it: **`gemini-3.6-flash` remains the recommendation**, and
  now against its whole family. On the near-miss suite it matches 44/48 twice against 3.7's 40–41,
  `gemini-3-flash-preview`'s 36–37 and 3.5's 31–35, and it leads by more on the ungrounded column.
  On the reference clip 3.7 writes the wrong version number in 10 of 10 grounded runs and 9 of 11
  with no screen context at all — the second figure being mishearing rather than substitution,
  since there is no decoy to copy. Raising 3.7's thinking level to `high` makes it worse.
  Full tables in `docs/MODELS.md`.

- **An optional fallback backend, on all four platforms.** The first-party Gemini API is the most
  accurate measured and its latency is bimodal rather than slow — six sequential requests for one
  three-second clip took 4.9, 61.6, 50.5, 5.8, 5.9 and 30.2 s, with zero thought tokens throughout.
  A dictation tool that usually answers in five seconds and sometimes in sixty is worse than one
  that always takes six.

  It **hedges rather than races**: the primary gets the whole configured delay to itself, so a
  normal response is never second-guessed and never pays for a second request. It is **attributed,
  not silent** — the history row names the backend that answered, not the one that was asked. It is
  **off by default**, and the primary, the secondary, its own key and the delay are all
  configurable, because that delay is the accuracy-against-latency dial and the right value depends
  on which two backends are paired.

- **The default backend is now xAI speech-to-text, not Gemini.** Decided on a new 100-clip
  ordinary-dictation corpus — real speech at the lengths people actually dictate, with nothing on
  screen contradicting it — because the near-miss suite is adversarial by construction and had
  quietly become the thing choosing defaults. On that corpus xAI is the fastest backend at every
  clip length (0.89 s median against the model's 5.66 s; 2.8 s against 16.9 s on two minutes of
  speech) and fails 1 clip in 100. The model remains one dropdown away, and is the right choice
  when dictating identifiers with the reference on screen — but it costs 5.5× the wait for a
  grounding benefit measured at +4 improved against 3 regressed.

  **Deepgram is disqualified as a default by the same corpus**: it returned nothing for 48 of 100
  clips, including 44 of the 68 Chinese ones. It stays available for English-only use.

### Added

- **An ordinary-dictation corpus and `dnt-eval dictation`.** 100 clips, 38 minutes, 22 recordings,
  built by `eval/build-dictation-corpus.py` from a fixed seed. There is no ground truth and none is
  invented; the harness reports latency against clip length, failure rate, and cross-backend
  agreement, the last as a review queue rather than a score. Audio and manifest stay local.

- **`dnt-eval keyterms`.** Prints the spelling hints a screen context would send, for the same
  reason the app has a Context Inspector: the biasing list was the one part of a request nobody
  could read. It fails loudly if a digit ever reaches the list.

- **Provider choice on every platform.** macOS, Windows and Android all pick a backend from a
  dropdown that names what each one gives up, and all three store the API key **and the model per
  provider** — a single shared model field would send `gemini-3.6-flash` to `/v1/listen` the moment
  anyone switched to compare. Existing single-key installs are read as Gemini's, so nothing needs
  migrating. The connection test probes a recogniser with a quarter-second of generated silence
  instead of text, because a text-only round trip reports a working key as broken.

- **Mistral Voxtral (`/v1/audio/transcriptions`).** The recognition backend for anyone who switches
  language mid-sentence: it transcribes Mandarin and English together, keeping `retrieval pipeline`
  and `Google` in English inside Han text, without being told which is coming. It completes all 16
  near-miss cases where Deepgram errors on two. It has **no biasing channel** — `context=` and
  `prompt=` are accepted with HTTP 200 and leave the transcript byte-identical — so it reports no
  grounding rather than pretending. It is the only recogniser here that reports audio tokens, so
  the silent-drop guard is live on it. (This repository had previously marked Mistral out of scope;
  that was decided when no `MISTRAL_API_KEY` was configured, and `docs/MODELS.md` simultaneously
  called Voxtral's biasing the most promising follow-up.)

- **Speech recognition backends: Deepgram (`/v1/listen`) and xAI (`/v1/stt`).** The first backends
  here that are not language models, which the provider protocol now models explicitly rather than
  papering over. `GroundingSupport` says what a backend can do with the screen, and
  `TranscriptionService` sends each one only what it can use — so a recogniser never receives ten
  thousand characters of screen text it cannot read, and a dictation it produced is never recorded
  as grounded. Fidelity travels on the request rather than only inside the prompt, because a
  recogniser has no prompt to read it from. Rewriting through one fails with an error that says to
  switch provider, instead of a bare HTTP 400.

  Measured against a model provider on the near-miss suite (`eval/benchmark-speech.sh`, three
  passes): Deepgram nova-3 is roughly **five times faster** — 1.33 s against 6.50 s on the same
  22-second clip — and materially less accurate on the words that matter, writing `coffee` for
  `koffi` and `dash dash amend` for `--amend`. Two Mandarin cases fail outright: **no autodetecting
  setting transcribes Chinese**, and `detect_language` fails by returning HTTP 200 with an empty
  transcript, so nova-3 now defaults to `multi` (18/42 matched against detection's 12/42).

  **xAI turned out to be the strongest of the three** once a working key arrived: 29–30/48 matched
  with biasing on, against Deepgram's 27/42 and Voxtral's 21/48, at 1.19 s — the fastest backend
  measured, model providers included. It reads `XAI_API_KEY`, falling back to `GROK_API_KEY`.
  The range is real: three identical runs gave 30, 30, 29, and an earlier session gave 35, so its
  keyterm biasing varies between sessions rather than only between passes.

  It also justified the "verify before adding" rule it had been shipped in violation of. The first
  live request found two undocumented behaviours, both of which broke the default configuration:
  `format=true` is rejected without a `language` field, and **form fields written after the file
  part are silently ignored** — HTTP 200, no error, options simply not applied. The second is now
  pinned by a test, because reordering the body would disable formatting and biasing invisibly.

- **Optional keyterm biasing for recognition backends, off by default.** A recogniser's only
  grounding channel is a word list, so `Keyterms` derives one from the screen — and **never emits
  a token containing a digit**, because a version number in a biasing list is a request for the
  substitution bug, and unlike a prompt there is nowhere to attach "reference only". On the
  near-miss suite that structural guarantee held: **9 improved, 0 regressed**, against the model
  provider's 4 improved and 3 regressed. It stays off by default anyway, on principle rather than
  cost: it is still a vocabulary prior, and the corpus never tests it against a *wrong* on-screen
  name, which is exactly where a prior would do damage. It has **no measurable latency cost** —
  an earlier version of this entry claimed ~2 s from sending terms as query parameters, which
  measurement falsified in both directions (see `docs/EVALUATION.md`).

- **macOS, Windows, Android, iOS apps.** Hold a key, speak, release, get your words back. macOS and
  Windows are menu-bar/tray apps; Android is a keyboard that records in-process; iOS is a
  containing app plus a keyboard extension that inserts what the app produced.
- **Screen grounding** on macOS (accessibility tree + screenshot fallback), Windows (UI Automation)
  and Android (`AccessibilityService`). Not possible on iOS.
- **Two-phase capture.** A cheap snapshot at hotkey-down, then the expensive walk while the user is
  still speaking, so grounding costs no perceived latency.
- **Pre-upload with fallback.** A resumable Files API session opens at hotkey-down; the finished
  file is uploaded and referenced by URI, degrading silently to inline on any failure.
- **History with retry.** Failed dictations keep their audio until they succeed, so Retry is a
  button that works. Search across transcripts, errors, apps and window titles; status and app
  filters; per-item and bulk delete; retention policies.
- **Editable prompt.** The contract is editable in-app, validated before saving, restorable to the
  shipped default.
- **Recording modes.** Push-to-talk, hands-free, and an automatic mode where a tap toggles and a
  hold is push-to-talk.
- **Network-aware failure handling.** Offline is detected before a request is spent, so a dictation
  queues instead of timing out, and the queue drains itself when connectivity returns.
- **Recording overlay** at the bottom of the screen, with a level-driven waveform, a success
  confirmation, and reduce-motion support.
- **Permissions walkthrough**, re-checked at every launch because macOS revokes Accessibility when
  a signature changes.
- **Measurement layer.** `dnt-eval` with `probe`, `once`, `suite` and `ablate`, plus
  `eval/model-sweep.sh` and `eval/extract-real-audio.sh`.
- **Context Inspector** — shows exactly what was sent with any dictation, rendered back through
  the real `ContextEncoder`: every part in order, the screenshot when one was sent, the token cost,
  and whether audio was retained. If an app reads your screen you should be able to read what it
  read.
- **Optional rewrite on a second hotkey** — formal, concise or bullets, for turning a dictated
  paragraph into an email. The verbatim transcript is always produced and stored first, and the
  inspector shows both versions together, so what you actually said stays recoverable.
- **Releases are cut by tag.** `git push origin v0.2.0` builds all four platforms, runs each one's
  tests first, and opens a *draft* GitHub release with signed artifacts and checksums attached —
  draft rather than published, because a release is hard to retract and the notes are generated.
  Every signing secret is optional and independently checked, so a fork produces working unsigned
  builds instead of a red workflow. Windows builds libopus from a pinned source tag rather than
  downloading a binary.
- **Opus uploads on Windows,** via libopus — the one native dependency in the project, and only on
  this platform, since it is the only one with no encoder in the box. The container is a port of
  the same `OggOpusWriter`, checked byte-for-byte against the reference stream the Kotlin port
  passes. Missing library or failed encode falls back to WAV.
- **Opus uploads on Android too,** using `MediaCodec`'s native encoder and the same container
  writer as the Apple ports, checked byte-for-byte against a committed reference stream. Below API
  29, or on any encoder failure, it falls back to WAV — a compression optimisation must never be
  able to cost someone their words.
- **Uploads are Opus now, not PCM.** A 30-second dictation was 960 kB and is now about 60 kB —
  16× less to send. End-to-end latency fell from 6.9 s to 4.9 s at 10 s of speech, and 13.1 s to
  9.9 s at 30 s. The transcript is unaffected: the same fixtures transcribe identically as WAV,
  FLAC and Opus, and the provider bills the same audio-token count for each.

  CoreAudio encodes Opus natively but will only wrap it in CAF, and the API decodes Ogg — so
  `OggOpusWriter` writes the container directly rather than adding a libopus dependency to four
  build systems. Only the upload is compressed; history still keeps the WAV, because a retry
  re-runs the whole pipeline and the chunker needs PCM to find silence in.
- **Tap to talk, hold to talk — on every platform.** The Android keyboard was hold-only, which
  means keeping a finger down for the length of a thought: fine for a sentence, miserable for a
  paragraph. It now behaves like the desktop hotkey — a quick tap starts and a second tap stops,
  while holding past 350 ms records only while held. iOS gained the hold half of the same gesture.
  Recording begins on touch-down either way, because waiting to classify the gesture would clip
  the first word, which is the one people say fastest.
- **A distinct "thinking" animation once speech stops,** on all four platforms. Deliberately unlike
  the recording waveform: after you stop talking there is no input left to reflect, so a
  level-driven animation would be decoration pretending to be a signal. It exists to prevent one
  specific failure — deciding nothing happened and pressing the key again mid-request.
- **Cases that measure whether grounding *helps*,** not only whether it can do harm. The suite
  scored `improved 0` for a while, which looked like a failure of grounding and was actually a gap
  in the corpus: probing every clip with no context showed the model already spells VAD, ASR, Scrum
  and `retrieval pipeline` correctly unaided, so the screen had nothing to add. Three cases now use
  invented tokens the model cannot know. With them, the suite reports **5 improvements against 1
  regression** — grounding's benefit is measured for the first time, and it is narrower than
  "context improves transcription": it helps where the model is genuinely ignorant.

  One of the three fails, and is kept for what it shows: `Kaelith` returns as `Keyleth` — a name
  the model already knows — despite the correct spelling being on screen three times. That is this
  project's founding complaint one level down: not a user dictionary overriding the speaker, but
  the model's own.
- **Number checking now aims at the caret window, and is on by default there.** The channel result
  changed what this feature should do. Re-measured with the contradicting value beside the caret
  rather than off in the visible text: substitution is **75%** unguarded and **20%** guarded, against
  30%/8% in the weak channel. So the check is worth its extra request precisely where the text
  being edited already contains numbers, and `When the text you're editing contains numbers` is the
  default. Digits in the visible text alone do not trigger it — a sidebar or a row count would make
  the cost constant while the benefit stayed occasional.
- **Optional number verification.** Every measured grounding regression has been a number, never a
  word. Enabling this runs a second transcription that never sees the screen and takes the digit
  sequences from it, declining to act at all when the two runs disagree on how many numbers there
  are — aligning by position across a mismatch would move a value somewhere it was never spoken.
  On the reference clip it cuts substitution from 58% to 8%. **Off by default**: the two requests
  overlap but contend for the same upload, so the pair costs about 17 s against 8.6 s for one, and
  doubling the wait to fix a failure that only bites when a screen number contradicts a spoken one
  is the user's call, not the app's.
- **Cross-platform encoder conformance.** `ContextEncoder` exists four times and nothing checked
  that the ports agreed. A shared fixture set (`eval/conformance/`) is now encoded by Swift as the
  reference and verified byte-for-byte by the Kotlin and C# suites.

  It found a real bug on its first run: **Android and Windows were both shipping a truncated
  footer**, missing the three lines that restate the content rule immediately before the audio —
  the instruction that tells the model numbers must come from what was said, not from what is on
  screen. Those two platforms had been running without the project's central anti-substitution
  measure since their ports were written, and no test could have noticed. Both fixed.
- **Long dictations are split across concurrent requests** on all four platforms. Cuts land in
  the middle of the quietest 100 ms near the target, so no chunk starts or ends mid-word, and every
  chunk carries the *same* screen context — which is what keeps a name spelled the same on both sides of a seam.
  Under 90 seconds nothing changes, so an ordinary dictation pays nothing for this. The overlay
  shows "part 2 of 5" rather than sitting on "Transcribing…", which is the difference between slow
  and hung.
- **Timings, per dictation and in aggregate.** Each history row shows the wait, measured from key
  release rather than from the request — the screen-context read, a failed pre-upload and any retry
  are all time the user spends looking at the overlay, and a figure that excluded them would
  flatter the app. A Stats tab reports median and p95 wait, wait per second spoken, success rate,
  retries, and a per-model breakdown, so switching model shows its effect instead of being taken on
  faith. Median rather than mean throughout: one retry storm should not make the typical case look
  bad.
- **Undo and revert-to-verbatim.** `⌘⇧Z` removes the last insertion; `⌘⌥Z` replaces a rewrite with
  the verbatim transcript. Cheap only because the original is always stored. Expires after a
  minute, since deleting characters from a field the caret has since left would destroy unrelated
  text.
- **Paste last transcript** (`⌘⌃V`), for when the first insertion landed in the wrong window.
- **Microphone selection**, pinned by device UID rather than ID so it survives reboots, falling
  back silently when the device is unplugged.
- **Launch at login** via `SMAppService`, so the toggle also appears in System Settings › Login
  Items where someone would look to remove it.
- **Start/stop tones enabled by default**, with an Audio setting for silent dictation.
- **Cross-vendor model benchmark** (`eval/benchmark-models.sh`, results in
  [docs/MODELS.md](docs/MODELS.md)) covering 36 audio-capable models.
- 73 Swift unit tests, 24 C# unit tests, and an opt-in integration suite that runs against the live
  API on real recorded speech.
- **UI tests that run where the app runs.** Every test in this project used to stop at the core, so
  nothing knew whether the apps worked — which is how an iOS bundle that no device could install
  stayed green in CI. iOS gets an XCUITest target that installs and drives the app through
  settings, the API key round trip, history, the prompt editor and fidelity; Android gets
  instrumented tests including one asserting the scroll viewport is inset by the system bars; and
  the Windows job launches the real tray app and fails if it is not still running with its
  settings window open. All three run in CI, the last two on an emulator and a Windows runner.
- **An app icon** — a text insertion caret whose stem is a microphone, its lower serif doubling as
  the mic's base. It replaces the three placeholders that shipped before it: macOS drew SF Symbols
  in the menu bar and had no bundle icon at all, Windows showed the generic
  `SystemIcons.Application` in the tray, and Android used the platform's built-in
  `ic_btn_speak_now`. All four platforms now render from one file, `Resources/Icon/DoNotType.svg`,
  the same way they all copy one `PROMPT.md` — including the macOS menu-bar states, where the
  capsule is hollow when idle, solid while recording and a level meter while transcribing. See
  [Resources/Icon/README.md](Resources/Icon/README.md).

### Fixed

- **A bad or absent API key was only discovered by losing a dictation.** The key was read at the
  moment a recording needed it, so the first thing anyone learned about a wrong key was a failed
  transcript of something they had already said. macOS now checks it at launch and after every edit
  to the key, provider or model: one round trip, silence for the recognisers and a text probe for
  the models, with the settings window opening itself and the menu bar saying so when the answer is
  "fix this". A check that cannot complete — offline, timed out, provider having a bad day — is
  reported as exactly that and never as a bad key, because a settings window that opens itself on
  every flaky network is one people learn to close without reading.

  Three things had to be fixed for that answer to be right. **xAI rejects a bad key with HTTP 400,
  not 401**, and by status alone that read as a transient request failure — "saved, retry from
  History", advice that could never work for a request guaranteed to fail identically forever; a
  400 whose body names the API key is now attributed to the key. **The app and the provider factory
  disagreed about which environment variables hold the key**: the factory accepts `GROK_API_KEY`
  for xAI and the app only ever looked at `XAI_API_KEY`, so a shell holding the older name was told
  it had no key at all. They read one list now, and a test walks every name the factory advertises.
  And the settings window **says where it looked and why a key you are certain you set is not
  there** — an app opened from Finder or Login Items inherits launchd's environment, not your
  shell's, so `export XAI_API_KEY=…` in `~/.zshrc` is real in every terminal and invisible to the
  app. Pasting it into the field puts it in the Keychain, where every launch can find it.
- **The iOS app could not be installed.** Neither `Info.plist` declared `CFBundleIdentifier` or
  `CFBundleExecutable`. Xcode only synthesises those for targets that let it generate the whole
  file, and `xcodebuild build` does not check them, so CI was green for the life of the project
  while every installer rejected the bundle it produced: "Missing bundle ID". Found by trying to
  install it in a simulator, which nothing had ever done.
- **The Android settings screen drew under the status bar.** API 35 hands an app the area behind
  the system bars whether it asked for it or not, and a layout built in code gets no insets
  applied for it, so the heading sat behind the clock. The inset padding belongs on the scroll
  view rather than on the column inside it — padding the column fixes only the resting position
  and scrolled rows still run under the clock. The action bar is gone too, since the screen draws
  its own title and it was appearing twice, and the status bar icons are now tinted for the
  background they sit on instead of staying light on light.
- **The Android keyboard's only button was half covered** by the navigation bar. The IME window
  extends behind it; a gesture pill is thin enough to miss "Tap to talk", a three-button bar is
  not.
- **The iOS record button was invisible to VoiceOver.** It is a bare gesture on a `ZStack`, which
  exposes nothing, so the one control the app exists for could not be operated by anyone driving
  it that way. It now reports as a button, carries a label and hint, and toggles on activation,
  since press-and-hold is not a gesture VoiceOver can forward.

- **A gateway that silently discarded audio.** One OpenAI-compatible provider accepted an
  `input_audio` block, returned HTTP 200, billed 14 prompt tokens for a 6-second clip, and
  transcribed the *screen context* as though it were speech. The provider layer now throws when
  audio was sent and zero audio tokens were billed, and that provider was removed.
- **History lists silently truncated** at 20 items on Android and 200 on Windows, which read as
  "this is your whole history" when it was not. Both now render everything the retention policy
  kept, and per-item delete was added to both.
- **Models that reject `response_format` were unusable.** `openai/gpt-audio` and `gpt-audio-mini`
  return a provider error the moment a JSON schema is attached, while transcribing fine without
  one. The client now retries once without it and remembers per model — structured output is a
  convenience here, not a requirement.
- **Transcripts truncated by a token limit were discarded entirely.** Partial JSON is now salvaged
  rather than thrown away, because the words in it are words the user actually said.
- **The Context Inspector was documented but did not exist.** README, SECURITY.md and the
  architecture table all described it. A false claim in a privacy document is the worst place to
  have one; it is now built.
- **History search and the prompt editor were macOS-only.** Both are now on all four platforms,
  with the filtering and validation rules in each platform's core so they are testable without a
  UI. Editing an invalid prompt is rejected at the moment of editing rather than surfacing as a
  mid-dictation failure, and every fidelity must resolve before a prompt can be saved.

### Known issues

- **Substitution is not solved.** On real speech with contradicting screen context, the model
  writes the on-screen version number instead of the spoken one in roughly 36% of runs, against a
  21% baseline error rate with no context at all. Numbers, method and failed mitigations are in
  [docs/EVALUATION.md](docs/EVALUATION.md). This is the central open problem.
- **The Windows app has never been run.** It compiles and its core tests pass, but every Win32 path
  — keyboard hook, `waveIn` capture, `SendInput`, UI Automation, DPAPI — is unexercised.
- **The near-miss suite is red, deliberately.** Adding real-speech cases took it from 0 regressions
  to 3, which is the honest state: two are the version-number substitution reproducing, and one is
  a case written as a positive control that failed in the opposite direction. It is not to be made
  green by deleting cases.
- **Rewrite styles are implemented but not recommended.** Both single-pass and two-pass are
  measured and neither is good enough to enable by default.

### Open findings

- **Context corrupts numbers without copying the screen's value.** Speaker says 4240, screen says
  4250, transcript says **1240**. "Substitution" is too narrow a name for the failure: grounding
  degrades numeric accuracy generally, so a mitigation aimed only at "do not copy what is on
  screen" would miss this case.
- **The failure is specific to numbers.** Across twelve cases, every word-based near-miss passes —
  DAPO against GRPO, VAD/ASR against TTS/NLU, Scrum against Kanban and Jira, Google/Bing, Priya
  against Marcus — and both regressions are numeric. Whatever protects an unfamiliar word from
  being replaced does not protect a digit. That is a far narrower target than "grounding overwrites
  what you said".

### Measured and rejected

Recorded because the reasoning was plausible and someone will otherwise re-derive it.

- **Restating the fidelity rule immediately before the audio.** Substitution rose from 11/19 to
  15/18. The restatement named the decoy value as its example, which appears to prime it.
- **Two-pass rewriting to protect number fidelity.** Twice as bad as single-pass (75% versus 38%),
  and single-pass was the slower of the two (15.7 s versus 7.5 s).
- **Chunked upload during recording.** Impossible with WAV: a streaming-convention header
  (`0xFFFFFFFF`) uploads successfully and is then rejected with `invalid argument`.
- **A user dictionary of corrected terms.** Rejected by design — a stored term list is a prior that
  overrules clear audio, which is the mechanism behind the bug this project exists to fix.
