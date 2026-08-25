# Changelog

Notable changes, newest first. Behaviour changes that affect transcription quality carry the
measurement that justified them; see [docs/EVALUATION.md](docs/EVALUATION.md).

Format loosely follows [Keep a Changelog](https://keepachangelog.com/). Release dates use the
repository's local calendar date.

## Unreleased

## 0.3.0 - 2026-08-25

A model that quietly dropped most of a long dictation, and the three ways that is now caught. The
default model moves back to `gemini-3.6-flash`, a new guard notices a transcript too short for the
audio, and cuts in a long recording are placed by Silero rather than by frame energy. On Windows,
the settings windows and the recording pill finally scale with the display.

### Fixed

- **A long recording could come back missing most of what was said, with nothing to indicate it.**
  Measured on a 90-second Mandarin recording, `gemini-3.5-flash` returned roughly 100 characters of
  a 310-character transcript on **6 runs in 10**, stopping mid-sentence at the identical point each
  time; `gemini-3.6-flash` did it 0 times in 20. It is not the output-token cap. Nothing in the
  pipeline noticed, because `HallucinationGuard`'s rate ceiling is a *maximum* and 1.1 characters a
  second passes it by being below the floor of suspicion rather than above the ceiling — so the
  text read as fluent and plausible and was only wrong in what it did not say. `TruncationGuard`
  now measures the transcript against Silero-confirmed speech rather than recording length, because
  length cannot separate the cases: across 350 real dictations the legitimate minimum is 1.55
  characters a second of audio and the truncated transcript ran 1.09, while against speech the
  truncated runs are 2.00 and 2.27 and the lowest real dictation is 4.92. Nothing is deleted — a
  truncated transcript is still part of what was said — and short clips, unknown speech length and
  an empty transcript are all left alone.

- **Windows split long recordings at the first quiet frame instead of near a minute.** A C# record
  *struct* ignores its primary constructor's defaults for `new()` and zero-initialises instead, so
  `AudioChunker.DefaultPolicy` was every field zero: no minimum chunk length, a zero target, a zero
  horizon that emptied the preferred set on every call, and a minimum pause of zero that made a
  single 20 ms dip a legal cut. Swift and Kotlin aimed at 60 seconds throughout. Every chunker test
  passed, because they assert that cuts land in silence and that no audio is lost, and both stay
  true when the chunks are tiny. The default is now explicit and pinned field-for-field in all three
  cores.

- **A cut preferred a breath near the target over a clean sentence break slightly earlier.** The
  boundary score subtracted the raw distance from the target — linear, unbounded, and in the same
  units as nothing else in the score — so it dominated every quality term. Normalised by the width
  of the acceptable window, distance still breaks ties but can no longer overrule a much better
  pause inside the range the policy already called acceptable. Measured over the 60 retained
  recordings past the splitting threshold: the median pause a cut lands in goes from 0.76 s to
  1.32 s and cuts landing in a pause of a second or more from 40% to 60%, with the same number of
  chunks and a slightly shorter final chunk.

- **The Windows settings windows and the recording pill scale with the display.** No window ever
  assigned `AutoScaleMode`, so it stayed at `Inherit` and scaled nothing while the manifest asked
  for PerMonitorV2 and the fonts scaled regardless; every pixel count in those files is a 96 DPI
  number. The General tab's Save button sat below the fold with nothing left to scroll, because a
  scrolling panel takes its extent from the last control's bounds and not from the container's
  bottom padding — and the same was true of the Context Inspector's body, which renders the whole
  encoded context and so does overflow. The recording pill was a 96 DPI drawing carrying a 9pt font
  that grows with the display: at 200% a 24px line was asked to sit in a pill laid out for a 15px
  one.

### Changed

- **`gemini-3.6-flash` is the default again.** It was demoted on 2026-08-17 because it was slow:
  4.39 s median on a short clip against 1.34 s, a 10.59 s p90, a 39.06 s maximum and 16% of
  requests over 8 s. Re-measured, it answers the same clip in 1.95 s median against 1.45 s, p90
  2.36 s, max 2.57 s, and nothing over 8 s in 20 runs; across recording lengths it costs 1.14–1.43×,
  or +0.4 s to +1.8 s. The near-miss margin between the two is 41/47 against 39/47, inside the
  suite's own per-pass noise, and is deliberately not the argument — the truncation behaviour above
  is. **An existing installation keeps whatever model it has explicitly stored; only fresh installs
  and unset fields change.**

- **Cuts in a long recording are placed by Silero, not by frame energy.** Silero has been loaded and
  run on every recording since it replaced the noise-floor heuristic, but only ever as a yes/no gate
  on whether a chunk contains speech. The energy finder fragments a long pause the moment a breath
  or a keyboard tap crosses the floor — 226 pauses of two seconds or more across 147 real
  recordings, against 451 that Silero finds in the same audio. Taking the gaps between finalised
  speech runs instead moves the median pause a cut lands in to 2.14 s and cuts landing in a pause of
  a second or more to 77%. The model's recurrent state is carried across the capture rather than
  re-read, so a live recording costs about 1.6 s of CPU for five minutes of audio instead of
  roughly a core; audio Silero cannot parse still falls back to the energy finder rather than
  growing into one unbounded request. macOS and iOS; Android still uses energy boundaries.

- **The tokens a thinking level spends are reported rather than discarded.** The Gemini API returns
  `total_thought_tokens` beside `total_output_tokens`, and every client threw it away, so the cost
  of the dial was invisible in history and in the logs. It is a separate field, not part of the
  output count: `total_tokens` is input + output + thought. Measured on a 22-second clip, `minimal`
  and `low` both report exactly 0 on both shipping models — they are the same behaviour under two
  names — and `medium` reports 500 and 700 against an 81-token transcript.

### Documentation

- **`docs/INCREMENTAL.md` records an investigation that ended in the feature not being built.**
  Transcribing a long dictation while it is still being spoken, with a slower model on the hidden
  latency and the earlier transcripts as context, was measured and rejected: segmenting recovered
  more than 15% more text on 0 of 10 long recordings, was consistently worse on 6 Mandarin ones,
  and a review of 258 aligned disagreements preferred the whole-file transcript. Raising the
  thinking level was worse on both models, 1.6–2.3× slower, and quintupled screen-context
  regressions on 3.6. The document keeps the rejected designs, the measurements that killed them,
  and the mistakes made along the way — chief among them citing the near-miss suite for a question
  its short clips cannot see.

## 0.2.0 - 2026-08-20

Release preparation repaired the Android build after the AGP 9 migration, refreshed the Windows
app's locked transitive dependency graph after the ONNX Runtime update, and fixed the release
pipeline itself: build provenance is skipped where GitHub cannot issue it, and the two CLIs report
one version format.

### Added

- **The connection test now sends a recording, so an endpoint that cannot take one fails the
  test.** It previously sent audio only to speech-recognition backends, which reject a text-only
  request by design, and sent a line of text everywhere else — the one request shape a dictation
  never uses. A text-only relay or a `vllm serve` in front of a text-only checkpoint answered that
  text perfectly and passed, and the truth arrived on the first real dictation instead. Every
  backend now gets the same quarter-second of silence, which is `minimumSpeechMilliseconds` — the
  shortest clip this app will ever send for real, so whatever a provider does to the probe it would
  do to a dictation. A refused recording and a silently dropped one both land as "fix this" rather
  than "could not ask": the probe sends a fixed, minimal request, so advice saying a retry will not
  help is advice about the endpoint setting, not about the network.

- **The endpoint field says that a compatible API is not necessarily an audio API.** Pointing a
  model backend at a third-party or self-hosted URL now shows a caveat in the macOS and iOS
  settings panels, beside both the primary and the fallback endpoint: dictation sends the recording
  itself, and plenty of services that speak the same request shape serve text and images only. It
  points at the connection test for the answer, and names the one case that test cannot settle — a
  service that reports no token usage at all. The `local` backend carries the caveat with no
  override set, since a `vllm serve` in front of a text-only checkpoint is the likeliest way to
  meet this. Speech recognition backends do not, because a mirror of one that could not carry audio
  would not be a mirror of it.

- **Release artifacts now have enforced provenance and stricter security boundaries.** macOS
  signing failures can no longer fall back silently to an ad-hoc signature, tagged builds verify
  the resulting signature, transient signing material is removed, and every downloadable app
  receives a GitHub build-provenance attestation. The tag workflow now runs the iOS UI
  suite and Android lint instead of accepting compile-only evidence, while CI checks shell scripts
  and workflow definitions and dependency updates cover Swift and NuGet as well as Gradle and
  Actions. It stamps and checks every bundled version, validates APK and notarization signatures,
  verifies every checksum and archive, and publishes only the four intended release assets rather
  than flattening iOS test-result internals beside them. Provider requests also refuse cross-origin
  redirects so API-key headers, audio, and screen context cannot be forwarded to an endpoint the
  user did not configure; remote overrides require HTTPS, reject embedded credentials, and now fail
  explicitly instead of silently sending a recording to the built-in provider when the override is
  malformed.

- **Cold iOS keyboard handoff survives app activation.** Keyboard ownership is recorded before the
  asynchronous microphone start, so the brief inactive scene phase during a cold launch cannot
  erase the return instructions. The overlay exposes stable accessibility identifiers on current
  iOS runtimes, and its direction cue now stops after three pulses instead of animating forever.

- **Project documentation is organized as a public reference.** The README now states the
  project's motivation and operating principles, including its differences from built-in and
  commercial AI dictation. Long-form documents live behind an indexed `docs/` entry point and
  use a consistent, neutral structure. The rewrite preserves the commands, measured results,
  falsified predictions, dated experiment history, platform caveats, and security boundaries
  that support the project's claims. A scan-friendly three-bullet introduction and motivating
  diagram now use the ByteDance UI-TARS paper to show how visible text can resolve an uncommon
  name, and the contribution guide identifies context construction, prompt work, provider
  integrations, and reproducible benchmarks as open research areas.

- **Mobile dictation and rewriting are separate choices.** iOS and Android now use a compact
  Dictate/Rewrite switch instead of presenting Verbatim beside Formal, Concise, and Bullets as if
  all four were one kind of setting. Rewrite style now lives in its own Settings section, separate
  from transcription fidelity, and the iOS keyboard carries the same switch as the main dictation
  screen. The iOS personal-dictionary row also renders its entry count instead of showing the
  Swift expression that was meant to produce it.

- **MIT licensing now travels with every build.** The canonical repository license is copied into
  macOS, iOS, Android, and Windows deliverables, Apple and .NET metadata identify the grant, and CI
  inspects the packaged files so a release cannot silently omit its license notice.

- **A stopped recording always explains what happened.** Recordings that are too short, contain no
  detected speech, or produce a blank transcript now leave a visible, short-lived notice on macOS,
  iOS, Windows, and Android instead of making the recording UI disappear without an answer. The
  controls remain immediately retryable; Android also fixes an error state whose retry-looking
  button previously ignored taps. Windows confirmations can no longer race with a later recording
  and hide its overlay.

- **Reproducible Android and self-contained Windows builds.** Android now carries the
  Gradle 8.9 wrapper and checksum required by its pinned Android Gradle Plugin instead of trusting
  whichever system Gradle happens to be installed. The Windows app and CLI now share one private
  .NET runtime, so both can work on a clean machine without a global .NET installation when built
  locally. Windows production packaging is not part of CI or releases, as recorded under Removed.

- **Microphone capture follows the visible mobile UI.** Closing the Android keyboard now discards
  an active recording instead of leaving the microphone running in an invisible IME service, and
  explains that outcome when the keyboard reopens. iOS stops capture when the app leaves the
  foreground and deactivates its audio session after every stop or startup failure, restoring the
  previous audio route promptly. Both recorder teardowns now fully unblock and remove their input
  hooks before returning, so a failed start or fast retry cannot inherit half-open capture state.

- **Screen grounding has a bounded, password-safe failure boundary.** macOS now applies the
  Accessibility API's native IPC timeout and observes task cancellation between attribute reads;
  the advertised 500 ms walk can no longer wait indefinitely for a hung target application. Its
  traversal prefers visible children, skips hidden controls, validates selection ranges, and uses
  AX's UTF-16 caret offsets correctly after emoji. macOS, Windows, and Android all refuse password
  controls as grounding, correction-learning, and delayed-submit sources while still allowing the
  user to dictate into those fields without screen context.

- **Android API keys are encrypted at rest.** Existing private SharedPreferences keys migrate in
  place to AES-GCM values protected by a non-exportable Android Keystore key. New secrets never
  fall back to plaintext when secure storage fails, the settings screen reports that failure, and
  newly entered keys join log redaction immediately rather than only after the next app launch.

- **Windows contains failures at its native and UI lifecycle boundaries.** Finishing from the
  low-level hotkey now runs behind an observed asynchronous safety boundary, so an unexpected
  setup or teardown exception becomes a visible failure with diagnostics instead of terminating
  the tray process. The native keyboard callback also contains managed exceptions before they can
  cross into Windows. Microphone capture no longer runs managed work or requeues buffers inside the
  driver callback, an operation Microsoft documents as deadlock-prone; a signaled worker consumes
  stable unmanaged headers instead. Exit cancels producers before disposing controls, ignores
  late UI callbacks, and leaves cancellation-source disposal to the tasks still using those
  sources. Microphone start is now transactional: every native return code is checked, partial
  setup releases its handles and pinned buffers, a driver that stops accepting buffers is reported
  instead of uploading truncated speech, and a failed live consumer falls back to the complete
  local recording. Cancelled live segments now finish unwinding before their cancellation and
  concurrency handles are released, so repeated escape/retry cycles neither accumulate resources
  nor race an HTTP completion during shutdown; a late completion also cannot clear the live
  session belonging to a newer recording. A per-session mutex now prevents a second tray process
  from installing the same hook and recording or inserting every dictation twice.

- **The iOS UI suite now waits for actionable controls, not merely allocated rows.** SwiftUI can
  expose a lazy Form row just outside the viewport, where XCUITest reports that it exists but a tap
  does not activate its navigation link. Settings navigation waits for an on-screen row, and the
  prompt editor is located by its stable identifier across Xcode accessibility-type changes. CI
  now retains the complete Xcode result bundle on failure, including the screenshots and
  accessibility hierarchy that console output omits.

- **Android file import rejects incomplete audio instead of transcribing a plausible fragment.**
  The Ogg reader now verifies every page checksum, stream and sequence number, continuation, Opus
  header, channel mapping, and end marker; a partial download can no longer return its readable
  first half as a complete recording. Platform codecs validate their actual PCM format and buffer
  bounds, release partial startup state, and turn a 15-second decoder/encoder stall into actionable
  failure or the original WAV fallback. The Opus upload encoder waits for a real end marker rather
  than treating its first temporarily empty poll as completion, and a device test now exercises
  the full app WAV → Opus → WAV path and checks its duration and signal.

- **History writes survive interruption and stay inside their data directory.** Android and
  Windows now flush a complete sibling index and replace the live JSON atomically, so a crash or
  shutdown during persistence leaves the previous history readable rather than a half-written
  file. Unreadable indexes are diagnosed without being overwritten merely by launch. All three
  shared history stores treat retained audio filenames as untrusted data and refuse paths that
  could read or delete outside the history audio directory. Retry recordings are now flushed
  before an index advertises them and are removed only after the replacement index commits; an
  I/O failure can therefore no longer leave a visible failed row whose audio disappeared during a
  retry, delete, or retention prune. Failed persistence rolls the live list back to the durable
  view, while orphan audio from a failed insert is cleaned up. “Don't keep history” also keeps the
  current process empty immediately instead of retaining a session-only list until relaunch.
  Startup finishes interrupted transactions by deleting unreferenced app-named recordings, but
  preserves every file when the index is unreadable so recovery never destroys its own evidence.
  Android prompt overrides and Windows prompt/settings files now use the same flushed sibling-and-
  replace discipline, so interrupted edits keep the prior valid configuration; a Windows settings
  write failure is contained and shown instead of escaping a UI event and terminating the tray app.

- **One-key finish with Return/Enter on macOS and Windows.** Pressing Return/Enter while recording
  now always stops capture, waits for transcription, and inserts the result. Sending an additional
  Return/Enter or the configured `⌘ Return` / `Ctrl+Enter` remains opt-in. The physical key is
  captured only during recording, the intent survives the transcription wait, and submission
  happens only after a successful insertion if the exact original field still has focus.
  Cancellation, failures, clipboard-only fallback, or changed focus never send. The recording and
  progress overlays show the pending action, and the confirmation distinguishes sent text from a
  safely skipped submit.

- **A local personal dictionary, including optional learning from corrections on all four apps.** Typeless's
  useful incentive is real: people correct a misspelling while it is in front of them and rarely
  stop work to populate a settings list in advance. DoNotType now accepts direct entries and a
  Typeless-compatible one-column CSV, with search, edit and delete in a dedicated Dictionary tab.
  The list is local, capped visibly at 100 entries, and has no account or sync service behind it.

  Correction learning is opt-in. For 60 seconds after an insertion, the app reads the still-focused
  field to isolate the span it inserted, keeps the two surrounding boundaries in memory for no
  longer than that minute, waits for the edit to be stable twice, and runs the before/after span
  through the existing transcript-diff classifier. Changing fields stops observation. Spelling and
  capitalisation fixes are learned;
  insertions, deletions, ordinary rewording and number changes are not. Learned entries carry their
  source in the UI, trigger a visible notice, and the newest batch can be undone from the desktop
  tray/menu or the mobile keyboard notice. Windows observes its exact UI Automation element;
  Android checks the same active `InputConnection`. iOS persists a one-minute document anchor
  across keyboard switches and checks it when the DoNotType keyboard becomes active again. That
  last loop is best-effort because iOS suspends an inactive keyboard extension.

  Model backends receive a delimited spelling-only reference that says an entry is not evidence it
  was spoken. Recognition backends receive safe entries through their keyterm channel even when
  screen-derived biasing is off; entries containing digits are withheld because those endpoints
  have nowhere to attach the audio-wins rule. Manual and learned entries are both opt-in state, so
  the default empty dictionary leaves the measured request byte-for-byte unchanged.

- **A stalled transcription is re-sent instead of waited out.** Latency here is bimodal rather
  than slow: six sequential requests for one three-second clip took 4.9, 61.6, 50.5, 5.8, 5.9 and
  30.2 seconds, with zero thought tokens throughout, so the sixty-second draws are queueing rather
  than model work. A tool that usually answers in five seconds and sometimes in sixty is worse
  than one that always takes six.

  A request is now called stalled once it has run for at least eight seconds *and* at least a
  quarter of the audio's own length, and a second identical request goes out beside it. Both terms
  matter: the floor stops a two-second dictation being duplicated over a response that was merely
  unremarkable, and the share-of-audio term stops every long recording being called stalled at
  eight seconds, which is a good pace for four minutes of speech. On a split recording it is the
  chunk that stalled that gets re-sent, not the dictation.

  It is not a timeout — the first request is never abandoned, and if it answers first it wins.
  Cancelling it would throw away a request that has already paid its queueing cost and might be a
  second from returning, so the same two requests would cost the same and take longer. It is not
  the fallback backend either: that reaches for a *different* provider and is off unless one is
  configured, whereas this re-asks the backend you chose, so the transcript comes from your model
  either way. All four clients; off in the eval harness, where doubling a suite's spend would be a
  harness defect.

- **A provider is no longer named after its model.** The picker offered "Gemini" beside
  "Openrouter" — a model beside a gateway — under a field labelled Service, with the model in a
  second field below it. So a configuration that is *gemini-3.6-flash through OpenRouter* read as
  "openrouter", and "Gemini via OpenRouter" could not be said at all, even though the difference
  is one this project measures: the same model ID scores 2–5 regressions per suite run through the
  gateway against 1 direct.

  The provider is now who serves the request, the model is what runs it, and the window states the
  pair — *gemini-3.6-flash via Google* — under a Provider picker that names providers: Google,
  OpenRouter, xAI, Deepgram, Mistral, Local server. `.gemini` became `.google` throughout, on
  macOS, iOS and both CLIs.

  Renaming a case would ordinarily orphan everything keyed by its name, so stored values resolve
  through `init?(persistedValue:)`, and the per-provider model *and Keychain entry* are read under
  the old name when the new one is empty. An install configured with Gemini keeps its key, its
  model and its selection; `--provider gemini` still works.

- **The xAI key rewrites as well as transcribes.** Selecting a recognition backend disabled the
  rewrite hotkey, the summary mode and `--text-provider` alike, on the reasoning that a
  speech-to-text endpoint has no text input. True of the endpoint, wrong about the account: the
  same `XAI_API_KEY` reaches Grok chat models on `/v1/chat/completions`, so the limitation was
  ours rather than xAI's, and a key that can rewrite was being told it could not.

  "Cannot read your screen" and "cannot rewrite what you said" are now separate questions with
  separate answers. xAI answers the first yes and the second no; Deepgram and Voxtral still answer
  both, and the UI still says so rather than offering a rewrite that could only fail. The second
  stage prefers the selected provider's own text model — same key, same account, nothing extra to
  configure — and only borrows another configured backend when there is genuinely nothing else,
  which is the behaviour file transcription already had. The model is editable in Settings, on
  `--text-provider xai`, and via `DNT_XAI_TEXT_MODEL`.

  Screen grounding stays off for xAI regardless: the audio never passes through a chat model, so
  there is nowhere for the context to go.

- **Nothing without speech in it is ever sent.** A model handed three seconds of room tone does not
  reliably return nothing — it returns a plausible sentence, and a dictation tool that types that
  into your document has invented words you never said. `PROMPT.md` rule 7 asks for an empty
  transcript, and that rule was carrying the whole defence despite two holes: it only reaches model
  providers, so Deepgram, xAI and Voxtral never received it at all, and an instruction is a request
  rather than a guarantee.

  The audio is now checked before the request on every client, which is the only defence that works
  for a backend that never sees the prompt. The gate runs the official Silero VAD v6.2.1 ONNX model
  locally, so deciding what is speech belongs to a standard multilingual detector rather than a
  volume threshold. The same checked-in model and upstream defaults run on macOS, iOS, Windows and
  Android.

  Against the shared corpus it finalises 0 ms for silence, room tone, steady noise, mains hum and
  keyboard/mouse clicks; 481 ms for the one-word “Yes” fixture; 1,500 ms for speech at its recorded
  level; and 700 ms after attenuating that speech by −52 dB. See
  [eval/audio/silence/README.md](eval/audio/silence/README.md).

- **`dnt-eval silence`**, which asks a real backend to transcribe those recordings and reports what
  comes back. A pass is an empty transcript; anything else is printed verbatim, because recognising
  the shape of the invention matters more than the count. It exits non-zero if anything was
  invented, and is now in the per-release manual checks.

- **The Context Inspector on Windows and Android.** If an app reads your screen, you should be able
  to read what it read — that is the answer to a tool that encrypts its captured context to a
  server key you do not hold, and until now only macOS could give it. Both render the stored
  context back through the real `ContextEncoder`, so what appears is the text that went over the
  wire rather than a description of it, and the test is that the output contains the encoder's
  actual output. One click from the history row it belongs to.

- **The rewrite works in live dictation on every client.** It was on macOS only, then macOS and
  Windows. Android gets style chips above the talk button; iOS gets a segmented picker above the
  record button. A phone has no second hotkey, so the choice is a control — but the rule the
  desktop's second key preserves is kept: chosen *before* speaking, never from a menu afterwards.
  Both hide the control entirely when no configured backend can rewrite text, because a control
  that cannot work is worse than one that is not there.

- **The numeric guard runs on Windows and Android.** The one feature this project is actually about
  was on one platform out of four. Every regression grounding has produced in the evaluation suite
  is a number — 1.5 becoming 2.5, 4240 becoming 1024 — and unlike a misspelled name a wrong number
  is not recoverable by reading it. The Swift tests were ported case for case, including the
  Mandarin code-switch regression, and all eighteen passed first time in both languages.

- **Undo, revert-to-verbatim and re-paste on Windows** — `Ctrl+Shift+Z`, `Ctrl+Alt+Z`,
  `Ctrl+Alt+V`. Not `Ctrl+Z`, which belongs to whatever you are typing into.

- **A pinned microphone and start/stop tones on Windows.** The system default follows whatever was
  plugged in last, so a headset quietly becomes a monitor's microphone across the room and the only
  sign is a worse transcript. Stored by name, not by index — indices shift when a device is
  unplugged, which would reintroduce the exact failure the setting prevents.

- **[docs/PARITY.md](docs/PARITY.md)**, which says what each client can do and why anything missing
  is missing. Screen grounding on iOS is the one real capability difference: the sandbox forbids
  reading another app's screen, and everything downstream of grounding is therefore absent there
  too. The rest of the gaps are named, with the reason.

- **The rewrite key works on Windows.** Hold-to-talk there was verbatim only: `RewriteStyle`
  existed in the core and the file transcriber, and the live path never touched it, so the two
  desktop apps had different products behind the same hotkey. Windows now has the same optional
  second key as macOS — bound in Settings, producing formal, concise or bullets — and the choice is
  made by which key you hold rather than from a menu after speaking.

  The verbatim transcript is stored either way, so a rewrite never loses what was actually said.
  The overlay names the stage it is on ("Tightening…", "Making bullets…") rather than continuing to
  say "Transcribing…" through a request that is not a transcription.

  Two ways it can go wrong are now said out loud rather than left to be noticed. A backend that
  only transcribes audio cannot rewrite text at all, so Settings says so when a second key is bound
  to one — at the moment the choice is made rather than the moment it fails. And when a rewrite
  fails for any other reason the words are still delivered, with "— not rewritten" on the
  confirmation, on both desktops. macOS had swallowed that silently since the feature existed.

  Windows still has no undo shortcuts; the verbatim text is in History, which is what would make
  them cheap to add.

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
  [what this project will never do](README.md#principles).

- **CI runs what ships, on every platform's own decoders.** Both CLIs are built and executed, the
  macOS app is launched and has to still be alive and to have logged its own startup, the Windows
  core tests run on Windows, and an emulator decodes all four audio formats on Android.

  This is the part that paid for itself. Media Foundation and `MediaCodec` are the platforms' own
  decoders and neither has an off-platform equivalent, so most of what the audio layer does had
  never been executed by any test. The Windows job found three bugs in the interop on its first run;
  the Android one found a fourth on its first run, which had been silently discarding a third of
  every Opus recording. Every one of them was a wrong number rather than a failure — audio that
  decodes to something plausible and shorter, which nothing downstream can detect.

### Changed

- **macOS Settings navigates from a sidebar, because its tab bar had hidden every panel again.**
  The window opened on one unlabelled `»` chevron and nothing else, so all nine sections were
  unreachable without knowing to click it.

  The changelog already records this bug once, for six tabs. That fix widened the window and set a
  700pt floor, and its own note said widening alone would only move the cliff. Three tabs were
  added afterwards, the floor went to 820 to keep up, and nine tabs wanted more than the 840 the
  window opened at. So the cliff moved and we walked into it, which is the argument for changing
  axis rather than measuring again: a macOS tab bar is a single toolbar item, not one per tab, and
  it lays out whole or collapses whole. However wide the window is, there is a number of sections
  that hides all of them.

  A sidebar list scrolls. Its capacity is bounded by window height, which this window has to
  spare, so a tenth section can never hide the other nine — and it is where macOS itself went when
  System Settings dropped top tabs in Ventura. All nine panels keep their names and symbols, now
  in three groups a tab bar could not express: what shapes the text, what already happened, and
  the app itself. The sidebar is pinned open with no toggle, since one that can be hidden is the
  same defect by another route.

  The window is 980x640 rather than 840x600 and its floor is 880 rather than 820 — both up, not
  down. The sidebar costs about 180pt off the top of every panel, and Transfer's buttons,
  History's toolbar and Stats' four tiles had no slack to give; the tiles' text is already capped
  at `minimumScaleFactor(0.8)`. Paying for the sidebar out of panel width would have traded a
  navigation bug for a legibility one. Transfer's seven buttons move to two rows regardless, along
  the seam a divider already marked, since that row was the first thing to break at any width.

  A split view rebuilds the panel on every visit where a tab view kept all of them alive, so what
  a panel must not lose now lives on the model. One of those was destructive rather than
  cosmetic: the Transfer editor fills itself from *this* machine when it appears empty, a guard
  written when empty could only mean "first look". Pasting a config from another Mac, checking an
  endpoint against it and coming back would have replaced the pasted document with your own
  settings under the words "Loaded the current settings", one click from importing them. The
  dictionary's search filter is the same shape one step down — a filter silently reset to
  everything still looks like a filtered list. Alongside them, the empty API key field no longer
  re-steals the caret on every visit to General, and the licence text is read once per process
  rather than once per view.

- **Casual replaces Bullets as a rewrite style, and is the default rewrite everywhere.** The
  bullet formatter left the rewrite picker on the owner's call: it overlapped the summary styles
  in appearance without their purpose. The new `casual` style rewrites as relaxed, typed prose
  while keeping every fact — its clause leads with "as if typed, not spoken" because the
  voice-first draft measurably kept spoken openers (2/48 fixture samples) and the flipped one
  kept none. Bare `rewrite` on the CLI and a fresh install's rewrite setting both mean casual now,
  the in-flight label is "Loosening…", and a stored or transferred `bullets` selection degrades
  to the default instead of failing. `summary:bullets` is untouched. Fixture gate: 0 content lost
  and 0 fillers retained for all three styles; near-miss 37/11/2, noise-identical to baseline.
- **The prompt word-count caps (160/100/90) are removed from the Swift, .NET and Android test
  suites.** They pinned a few words of headroom over the current text rather than measuring
  anything, and had already priced an example out of the light clause. Concision stays as a
  changelog norm; the 972→448 measurement in [PROMPT.md](docs/PROMPT.md) is its evidence.
- **Light fidelity now removes vocal fillers unconditionally, measured on retained real
  dictations.** The light clause's "when they add no meaning" used to dangle at the end of the
  whole removal list, vocal fillers included; it now governs only discourse fillers, and
  "um/uh/ah/er" removal stands in its own sentence. The retained-hotkey benchmark (497 real
  dictations × five models) showed filler survival was overwhelmingly a gemini-3.5-flash behavior —
  146 of 190 hits — and on the seven worst clips the rewritten clause cut vocal-filler hits from
  182 to 75, with the near-miss suite indistinguishable between arms (36 matched in both; the
  regression-count difference is inside the suite's per-pass noise floor). The assembled
  instruction stays at the 160-word cap. Full numbers in [PROMPT.md](docs/PROMPT.md).

- **The local speech gate is Silero VAD, replacing the recording-relative heuristic that could
  delete an entire dictation.** The old detector assumed every recording contained a quiet section
  and derived its threshold from the quietest tenth. Continuous speech after aggressive microphone
  gain control violates that assumption: part of the voice becomes the inferred floor, so stopping
  the recording looks exactly like “nothing was said” and no request is made. A regression fixture
  built by companding the shared real-speech recording reproduces it: the old gate reports 0 ms;
  Silero finalises 1,404 ms.

  All four clients now execute the same official v6.2.1 ONNX model with Silero's 512-sample windows,
  recurrent state and defaults: 0.5/0.35 probability hysteresis, 100 ms end silence and a 250 ms
  minimum speech segment. The 2.3 MB model is pinned by SHA-256 and carries its MIT notice. The
  silence corpus, one-word answer, quiet-speech ladder and gain-controlled regression run through
  the actual model in Swift, C# and Kotlin tests rather than through mocked probabilities.

- **Gemini 3.5 Flash replaces 3.6 as the recommended Google model.** Seven recent retained
  technical-dictation recordings — 5m48s covering product names, shell commands, networking terms
  and Mandarin/English switching — gave 3.5 the strongest qualitative terminology retention among
  the hosted models tested, at 2.54 s median against 10.54 s for 3.6. The clips have no human
  goldens, so this is explicitly a workload recommendation rather than an accuracy score; the
  older golden near-miss campaign still favours 3.6. Fresh installs and unset Google/OpenRouter
  model fields now use `gemini-3.5-flash`; an explicitly stored 3.6 selection is preserved.

- **Provider connection tests show their round-trip latency.** A successful “Test Google” or
  “Test xAI” result now ends in milliseconds or seconds, measured around the complete request so
  it includes the network, authentication and response parsing. Rejected and inconclusive tests
  show the same elapsed time, and fallback-provider tests use the identical measurement.

- **The recording pill shows how loud you are, rather than that sound exists.** The meter was five
  bars driven by `min(1, rms * 6)` and animated by a travelling sine wave. Measured across every
  speech fixture in `eval/audio/`, that scale spent 4–77% of the frames somebody was actually
  speaking in pinned flat against the top of the meter — 77% on `port-number`, 59% on the shared
  `speech.wav` — so it could report that audio was arriving and nothing else, while quiet speech and
  an empty room drew nearly the same sliver at the other end. The movement was invented too: the
  bars swayed identically whether the microphone was hearing a sentence or nothing at all, which is
  the one question somebody looks at a level meter to answer.

  It is now the last 1.4 seconds of the recording — 24 bars of 60 ms, oldest to the left — on a
  decibel scale: −60 dBFS draws nothing, −6 dBFS fills the bar. Room tone (−58) is flat,
  conversational speech (−21) is 0.72 of a bar, and a bar that reaches the top means the input is at
  the edge of clipping rather than that somebody spoke. Over the same fixtures the meter now pins
  one bar in 333 in the loudest of them and none at all in the other fifteen, and moves through
  25–77% of its height as the voice does. Bars containing samples that were clamped at the rail are
  drawn amber, which is the only thing in the app that will ever mention input gain set too high.
  Silence is a flat row of dots that keeps scrolling: the microphone is live and hearing nothing,
  which is a different report from a meter that has stopped.

  Levels are measured in 20 ms frames on the capture thread and collected by the UI, rather than the
  UI sampling a current value. A tap buffer is around 85 ms, so a meter redrawing thirty times a
  second was reading the same number three times over and stepping through movement the audio never
  made. The scale lives in `AudioLevelMeter` in Core, where the table above is asserted against the
  fixtures rather than chosen by eye.

  Windows had the same five bars with a *peak* rather than an RMS feeding them, so it pinned harder
  still, and its capture buffer was half a second — the meter could not have been more current than
  that whatever the UI did. The Android keyboard had the same five bars again, driven by a raw
  16-bit peak over a divisor of 12000, which any syllable at a sensible recording level clears.
  All three now run the same scale, asserted against the same fixtures in three languages, and the
  audio reaches them in pieces small enough to draw: 100 ms buffers on Windows, 50 ms reads on
  Android.

  iOS had no bars at all — a ring around the record button that pulsed with the level, which at
  least was already in decibels. It gets the same twenty-four bars, under the button, on the same
  scale and the same 60 ms a bar, and the ring keeps pulsing with the newest one. `AVAudioRecorder`
  writes the file itself and never hands over the samples, so there the level is the recorder's own
  reading of each interval rather than the loudest of three 20 ms frames, and clipping is its peak
  meter reaching full scale rather than a count of clamped samples: the same question, asked with
  what the platform can see.

- **The contract moved from `PROMPT.md` into `prompt/`, one part per file — and doing it fixed a bug
  that had been in every request since the contract was written.** `PROMPT.md` was two documents
  under one filename: about 95 lines that ship to the model, and 250 of argument, ablation tables and
  changelog. `<!-- BEGIN SYSTEM -->` markers existed only so the loader could tell them apart, and
  the loader took the *first* match anywhere in the file. Line 5 quoted that marker inside backticks
  while explaining what the loader did, so every request carried eight lines of the file's own
  documentation ahead of rule 1 — and because that same sentence also mentions `{{FIDELITY_RULE}}`,
  **the fidelity clause was being sent twice**. The 2026-08-09 entry in `PROMPT.md`'s changelog
  records that restating the fidelity rule made substitution worse, 11/19 → 15/18; the prompt had
  been doing an accidental version of exactly that throughout every measurement in it.

  A part is a whole file now — no markers, no fences, nothing stripped — so there is no convention
  left to get wrong. All nine marker and placeholder constants are gone from Swift, C# and Kotlin
  alike, and the assembled instruction drops from 41 lines to 33. `PROMPT.md` keeps its name and its
  job as the argument for the contract and the home of the changelog; it ships nothing.

  Overrides are per part, which removes a failure mode rather than tidying one. The old override was
  the whole file, so a prompt edited before summaries existed had no summary block and the stage
  failed outright — there was an error string apologising for it. Editing `system.md` now says
  nothing about `summary.md`, and a part you never touched cannot go stale. An existing edited
  `PROMPT.md` is split into part files once, on first launch, and only the parts that actually
  differ from the shipped text become overrides; the original is kept alongside as
  `PROMPT.md.migrated`.

  Each of the four settings screens becomes a part picker over one editor rather than the whole
  contract in a single scrolling box, with per-part *Restore default*.

  **The measured numbers in `PROMPT.md`'s changelog were all taken with the stray preamble present
  and have not been re-measured without it.**

  Two things this turned up on the way. The fallback transcriber and the retry coordinator read the
  bundled contract directly while the primary read the store, so an edited prompt applied to a first
  attempt and not to its retry — on macOS, Windows and iOS. And `eval/local-gpu-benchmark.py`
  reimplemented the loader in Python, so it carried its own copy of the same bug.

- **A fresh install now defaults to Gemini 3.6 Flash via Google, not xAI.** A recogniser cannot see
  the screen, so defaulting to one shipped the product with the feature it exists for switched off,
  in a way no setting revealed: grounding was not disabled, it was structurally impossible, and the
  first run misrepresented what the tool does.

  The near-miss suite measures exactly that axis, and the two shipping configurations are not
  close — **43/48 for Gemini grounded against 15/48 for xAI**. The cost is latency, and it is real:
  on the 100-clip ordinary-dictation corpus xAI returns in **0.98 s median** against several
  seconds for a model, and that corpus is why xAI was the default in the first place. Those numbers
  are unchanged and still in [docs/EVALUATION.md](docs/EVALUATION.md); what changed is which axis
  the default is chosen on.

  One number is deliberately not quoted: the 5.44 s on record is the same model class through
  OpenRouter, and nobody has timed the first-party API on that corpus. The near-miss suite says
  first-party beats the gateway on accuracy (15/15 against 12/15), which says nothing about speed.
  Quoting the gateway's figure as this default's cost would be inventing a measurement, so the
  honest statement is "several seconds rather than one, exact figure unmeasured".

  Nothing changes for an existing install: this is the value used when no provider has been stored,
  and a configured one keeps its provider, its key and its model. Anyone who wants the latency back
  picks xAI in Settings — one dropdown, and it keeps its own key and model.

### Removed

- **Windows production downloads.** Windows source remains in the repository and is compiled by
  the cross-platform validation job, but CI no longer creates a self-contained Windows production
  layout and neither rolling nor versioned releases attach one. The prior archive was unsigned and
  had not completed the manual release checks; leaving it beside signed, verified artifacts made a
  stronger claim than the evidence supported. Distribution can return after both manual validation
  and Authenticode signing are available.

- **The number check.** It transcribed every grounded dictation a second time without the screen
  and spliced that run's digit sequences into the first one, because every regression grounding
  has produced in the evaluation suite is a number: `1.5` → `2.5`, `4240` → `1024`. On the
  reference clip it cut substitution from 58% to 8%, which is why it existed.

  It was removed for what it charged rather than what it bought. Two concurrent requests mean the
  dictation waits on the *slower* of two draws from the provider's latency distribution, and that
  distribution's tail is the thing users actually feel. Profiled over 38 requests carrying the same
  22.8 s clip against `gemini-3.6-flash`: 8.9 s median, 21 s at p90, 43 s max, and one connection
  dropped outright at 62 s. Waiting on the slower of two moves p90 to 37 s and puts 26% of
  dictations past 20 seconds instead of 14%.

  The trigger made that permanent rather than occasional. `whenCaretHasNumbers` fired on any digit
  in a 1,000-character caret window, which in a terminal or an editor is every time — sampled
  against real stored contexts, 6 of 6. A number the model got wrong is a grounding and prompt
  failure, and it belongs where it is caused rather than in a runoff vote afterwards. The
  substitution rates stay in EVALUATION.md, because they are still the argument against grounding
  numbers at all.

  Gone with it: `NumericGuard`, `NumberCheckPolicy`, the Settings picker on all three clients,
  `dnt transcribe --verify-numbers`, and the `digit-guard` ablation condition.

- **Pre-upload.** A resumable Files API session opened at hotkey-down so the handshake was paid
  while the user was still speaking, and the finished recording was referenced by URI instead of
  carried as base64. The handshake trick was sound; the rest of it did not pay.

  Measured on the machine that reported it: the upload cost about a second of serial time after
  key release and saved about a second of body transfer on the request that followed — a wash. Its
  worst case was not a wash. `finishUpload` carried a 60-second timeout and no shorter deadline, so
  a stalled upload held the dictation for as long as it took to give up before falling back to the
  inline path, which then worked first time. One dictation in six paid 54 seconds for it, on a
  network where transit was measured at 0.44 s and never exceeded 0.7 s.

  The recording now always rides in the request, compressed. Gone with it: `AudioUploader`,
  `InputPart.remoteAudio`, `ITranscriptionProvider.SupportsPreUpload` and `IAudioUploader` on
  Windows, and the `audioPart` parameter threaded through the transcription path on both. Android
  never had it.

- **Paste last transcript** (`⌘⌃V` on macOS, `Ctrl+Alt+V` on Windows), along with its menu bar item
  and its line in the Shortcuts list. It re-inserted the newest completed transcript, which is the
  one you are least likely to have lost — you just watched it land. Anything older, which is the
  case that actually comes up, it could not reach at all. History does that job for any entry on
  any of the four clients, so the shortcut was a second, worse way to do a subset of it, holding a
  chord on two platforms and a row in the parity table on all four.

### Fixed

- **`dnt --version` printed a different line on each desktop.** macOS answered `0.1.0` and Windows
  answered `dnt 0.1.0`, because Swift ArgumentParser prints `configuration.version` verbatim while
  the C# CLI writes its own line. The version string is the first thing pasted into a bug report,
  and which client produced it should not change how it reads. Both now print `dnt <version>` with
  the build's commit and date, and `doctor` opens with that same line rather than assembling its
  own. The release workflow had asserted the shared format all along — its macOS signature check
  greps for `^dnt $VERSION (`, which no macOS build could ever satisfy, so cutting a tag failed
  after the app had been built, signed and notarized. CI now checks the stamped literals and both
  CLIs' actual output, on the two jobs that already run those binaries.

- **The recording pill was being cut off by its own window.** The overlay panel was created 220
  points wide and never resized; the pill inside it is as wide as whatever it is currently saying,
  which measures between 253 points for the recording hint and 382 for a failure message. A window
  clips its content to its own frame, and SwiftUI does not overflow one — it wraps, and then it
  truncates — so this never surfaced as a layout error anywhere. It surfaced on screen: "Release or
  tap to send" broke onto two lines, and a failure ended mid-word,
  `Gemini rejected the request: the API key is n…`. The pill is where a failure is read and the
  message is written to be the thing somebody quotes; nothing else in this project truncates an
  error. The panel is now wider than any pill it will hold — still transparent, still ignoring the
  mouse, so the room it does not draw in costs nothing.

- **The Context Inspector could not be opened on macOS.** The eye button on every history row set
  the state that selects a record and nothing presented it — no `.sheet`, no `.popover`, no window,
  anywhere in the app target. `ContextInspectorView` was complete, with a working `dismiss` and a
  Done button, and had no call site: clicking the button did nothing at all, silently.

  The parity table has claimed macOS ✅ for "inspect what was sent" throughout, and the feature was
  described as shipping on macOS first and being ported outward. Windows and Android are wired
  correctly and always were; the platform that supposedly had it was the one that did not. This is
  the second time this feature has been documented without existing — the changelog already records
  it once. Now presented as a sheet from the row it belongs to, verified end to end on the running
  app: the button opens it, the encoded context and token count are real, and Done closes it.

- **Every tab in macOS Settings was invisible, including History and Logs.** The window opened on
  an unlabelled `»` chevron and nothing else, so the six panels behind it — General, Grounding,
  History, Stats, Prompt, Logs — could not be found at all without knowing to click it.

  A macOS tab bar is a single toolbar item rather than one per tab: it lays out whole or collapses
  whole into the overflow menu, taking every tab with it. Six tabs need a 625pt window and this one
  was built at 620, missing by under five points and losing the entire settings UI for it. The
  window is now 760pt and, more to the point, resizable with a 700pt minimum, so the width can no
  longer be dragged below where the tabs vanish. The `.frame(width:height:)` pinning the content to
  the old size is gone too — it was what stopped the window growing out of the problem.

  Measured rather than guessed: the tab bar collapses at 620pt and lays out at 625pt, with every
  width up to 860 checked. The 700pt floor is deliberate headroom, because a longer label in a
  translated build would otherwise reintroduce exactly this bug with no code change.

- **The API key field on macOS could be typed into but not pasted into.** Cut, Copy, Paste, Select
  All and Undo are menu items on macOS rather than behaviour built into a text field:
  `NSApplication` dispatches ⌘V by walking `mainMenu` for a matching key equivalent. This app builds
  every window in code and never set a main menu, so the one field whose contents always arrive on
  the clipboard — 50-odd random characters from a provider dashboard, never typed by hand — was the
  one field that would not take them.

  There is now a main menu carrying the standard editing commands, plus ⌘W and ⌘Q. It stays
  invisible: `LSUIElement` apps do not own the menu bar, so activating this one still leaves the
  frontmost app showing its own menus, and the items exist only so the key equivalents have
  somewhere to land.

- **Retrying a failed dictation on Windows and Android asked a different question.** Neither kept
  the screen context the original request was sent with, so a retry re-ran *ungrounded* — no screen
  text, no caret window — on a history row that still named the same provider and model. A
  transcript that came back worse looked like the backend having a bad day rather than like the
  retry having asked something else. The context is stored on the row now, and the retry sends it.

- **Every Opus recording on Android decoded to two thirds of its length.** A 1.5 second file came
  back as 1.02, and a forty-minute meeting would have lost thirteen minutes from the middle of a
  transcript that looked complete. Nothing threw and nothing logged. The cause was a presentation
  timestamp of zero on every packet handed to the decoder: Android reads a timestamp that does not
  advance as a seek, and discards its seek pre-roll again for each one. Packet duration is now read
  from the packet — RFC 6716 §3.1 — rather than assumed to be 20 ms, which is what this project's
  own encoder emits and would have been wrong for anything recorded elsewhere.

  Found by a new instrumentation test on its first run. `MediaExtractor` and `MediaCodec` have no
  JVM equivalent, so the whole compressed-audio path had never been executed by a test.

- **M4A files decoded short on Windows.** The same shape of bug, found the same way. An AAC decoder
  advertises a default output format before it has parsed the stream — 32 kHz stereo for a file that
  is 16 kHz mono — and Media Foundation does not reliably announce the correction. The output format
  is now specified from the container's own declaration, which is available before decoding starts.
  M4A is back in the file dialog and the supported list.

- **A batch of recordings could overwrite its own transcripts.** `dnt transcribe a/speech.wav
  b/speech.mp3 --output out/` wrote both to `out/speech.txt` and reported success twice. Output
  names are worked out for the whole batch before the first request, and compared without case,
  because APFS and NTFS are both case-insensitive by default.

- **A crash decoding certain Opus files on Android.** The resampler carries its fractional position
  between decoder blocks, and that position could be exactly -1.0 — the next block then read
  `samples[-1]`. It needed the block length and the rate ratio to line up, which they do at 48 kHz
  to 16 kHz, the rate Opus decodes at.

- **Two processes writing to the same log file overwrote each other's lines** on macOS and iOS. The
  sink held a handle positioned at the end once, at open, rather than appending. `DNT_LOG_FILE`
  pointing at the app's log, or two `dnt` invocations at once, lost lines silently.

- **`--mode rewrite:` meant different things on different platforms** — the stage default on Apple,
  rejected on Windows and Android. All four now agree, and the parity table is repeated verbatim in
  each language's tests.

- **`--path` and `--probe` were the same flag.** The Windows argument parser matched a flag by its
  first letter, so every flag was aliased to its initial and asking about an empty name threw. The
  parser also moved out of a Windows-only executable, which is why it had never been tested.

- **A folder or an empty file produced "The operation couldn't be completed."** That sentence is
  named in [docs/MANUAL-CHECKS.md](docs/MANUAL-CHECKS.md) as the thing a failure must not say, and
  it was reachable from the file picker in one gesture. All three platforms now say which of those
  it was.

- **Six places listed the supported formats by hand and had drifted.** Every list on Apple and
  Android had lost Opus, the format this project's own encoder produces — which is part of why
  nobody noticed it was broken there. They read from the decoder's own constant now.

- **A server error whose body quoted a client error was never retried.** Windows and Android
  classified retryability by asking whether the message contained "HTTP 4", which searched the
  provider's own response body as well. A 502 whose body said "upstream returned HTTP 404" was
  written off as permanent. The status is a field now, set where the response is read.

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

- **The start and stop tones are a pair, not two unrelated system sounds.** macOS played Tink to
  open and Pop to close — two single events borrowed from the system, with nothing relating one to
  the other, so which one you had just heard was a question of memory rather than hearing. Pop
  also runs for 1.6 seconds, well past the moment it is reporting.

  Both cues are now anchored on G4: starting resolves a fourth up to C5, stopping the same fourth
  down to D4, each a struck-bar voice that decays inside 0.44 seconds. The ear reads the direction
  of an interval before it identifies a timbre, so up and down separate without being learned.
  They are synthesised in memory from an envelope and three partials rather than shipped as .wav
  files, which keeps a reviewable diff in place of two binary assets.

  Windows plays the same pair, in place of Asterisk and Beep — two unrelated single events, one of
  which is also what Windows says when it refuses a click. System sounds had a real argument in
  their favour, that they respect a scheme the user chose including a silent one, and the setting
  that turns these off is what now carries it.

  The cue is one implementation in the core, ported by hand like `ContextEncoder`, so both desktops
  are checked against the same reference: `dnt-eval tone-golden` writes it, and the Swift and C#
  suites each measure their own output back to 392 → 523 and 392 → 294 with a Goertzel filter
  rather than comparing hashes. Android and iOS still have no tones, for the reason in
  [docs/PARITY.md](docs/PARITY.md).

- **Nothing cuts a failure any more.** Response bodies were truncated at 400 characters in six
  places before anybody could see them — in the exception message, so the CLI printed a fragment,
  and in the history row, so the "copy the full error" button copied a fragment too. What gets
  dropped is routinely the useful part: providers put the offending field name and the request id
  after the human-readable message.

  The failure now exists twice, because one string cannot do both jobs. `errorMessage` is the
  sentence somebody reads; `errorDetail` is the status, the whole body and the exception chain
  exactly as they arrived, and it is what the copy buttons copy. Windows gained a "Copy the last
  error" item in the tray. Log fields escape newlines rather than dropping them, so a JSON body
  stays whole and one event stays one line.

- **Every stage of a dictation is logged, under one id.** Recording started, recording finished,
  the request with its grounding and target app, the transcript with characters and tokens and
  whether a fallback answered, the second stage, the insertion, the total. Each line carries
  `dictation=` — the first eight characters of the history row's id — because a log with three
  dictations in it is three interleaved stories. `dnt logs --grep <id>` gives one of them. See
  [docs/CLI.md](docs/CLI.md#following-one-dictation).

  Three lines exist for questions people actually ask: a tap too short to send (which was silent,
  and is the usual cause of "I pressed the key and nothing happened"), a recording with nothing in
  it (which reads as a failure and is not one), and whether Accessibility was actually granted at
  the moment of the paste.

  Failed responses now have their body logged in full. The rule that bodies stay out of the log is
  about your audio and your transcript; neither is in a 4xx.

- **A missing permission takes you to it.** Every platform listed its permissions at onboarding and
  then never checked again — and permissions are revoked later, since macOS drops Accessibility on
  every signature change. The failure that left was the worst kind: the hotkey works, the recording
  runs, the transcript comes back, and the paste goes nowhere, because a keystroke sent without
  Accessibility is ignored rather than refused.

  macOS refuses to record without the microphone rather than capturing silence, and when
  Accessibility is off it puts the transcript on the clipboard and says "Copied — press ⌘V" — a
  working dictation with one extra keystroke instead of a failure. Windows tells "no device" from
  "another app has it" from a privacy block, and opens the privacy page for the ones that are one.
  The Android keyboard's status line is now the way into the app rather than an instruction to find
  it. iOS opens its own Settings page, and its keyboard asks the system whether Full Access is on
  rather than inferring it from a missing container — both produce an empty list and they are
  different problems.

- **Failures say what went wrong and what to do about it, on every platform.** Windows and Android
  had no version of this at all: a history row read `HTTP 429: {"error":{"code":
  "rate_limit_exceeded","message":…`, and the Android keyboard — which has one line to say anything
  in — showed either that or a generic "saved, retry when you are back online" regardless of what
  had happened.

  The provider's own sentence leads, because it is more specific than a status code can be; the
  advice follows. `Invalid API key provided. Check it in Settings.` `models/gemini-9 is not found.
  Pick another in Settings.` `This model does not accept audio input. Retrying will not change it.`
  Anything that is not a sentence — a trace ID, an HTML error page, a wall of JSON — is dropped
  rather than pasted onto somebody's screen. The wording is identical in all three languages,
  checked by printing every case through each and diffing.

  Two rules that used to disagree now cannot. Every unhandled 4xx was described as "saved, retry
  from History" — advice that can never work for a request this app got wrong — and there is a test
  that the retry loop and the sentence shown for the same failure agree about every status.

- **The interface names the thing it is waiting for.** Every screen said "Writing the result…" while
  the second request ran, and the macOS overlay said "Transcribing…" through a request that is not a
  transcription and is usually the slower of the two. Somebody who chose Bullets is waiting for
  bullets: it now says "Summarising…", "Making bullets…", "Picking out the actions…". The word lives
  beside the mode rather than in each of the five interfaces, and is in the parity table.

- **The Windows overlay grew up.** It confirms an insertion, as macOS has always done — otherwise
  the pill vanishes and success is something you infer from text appearing, which you cannot do if
  the target window scrolled. And a failure is given as much room as its sentence needs instead of
  being cut at 48 characters, which is shorter than "The API key was rejected. Check it in
  Settings." — so what people saw was the diagnosis with the instruction missing.

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
- **Windows microphone capture and text injection still require a manual release check.** CI
  launches the packaged app and exercises the packaged CLI on Windows, and the native boundaries
  have unit coverage, but a hosted runner cannot speak into `waveIn` or verify `SendInput` in a
  separately focused application.
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

- **Making rule 2's carve-out explicit ("Apart from those removals, …" instead of "Otherwise …").**
  The suspicion was that "preserve wording" pulls fillers back in against the cleanup rule; on the
  four worst filler clips it netted 67 hits against the clause-only fix's 73 — inside per-clip
  noise — while editing the contract shared by all three fidelities. `system.md` unchanged.
- **Restating rule 4 at the closing line, without any decoy-valued example.** The earlier failure
  named the decoy; the example-free form was the remaining untried version. On the real clip with
  gemini-3.5-flash, verbatim substitution went 13/15 baseline → 13/13 restated — no improvement.
  Restating rule 4 stays rejected in all forms tried so far.
- **Telling the rewriter the text came from speech** ("…unchanged, even one that looks wrong or
  outdated" on the preservation bullet). Targeted at the measured two-pass failure where the
  rewriter "corrects" a stale-looking version number with world knowledge. Two-formal substitution
  on the real clip: 14/14 baseline → 11/12 with the sentence (1 correct, 3 no-version) — inside
  noise at 15 trials, and the rewrite fixtures were unchanged. No demonstrated rescue; not shipped.
- **Restating the fidelity rule immediately before the audio.** Substitution rose from 11/19 to
  15/18. The restatement named the decoy value as its example, which appears to prime it.
- **Two-pass rewriting to protect number fidelity.** Twice as bad as single-pass (75% versus 38%),
  and single-pass was the slower of the two (15.7 s versus 7.5 s).
- **Chunked upload during recording.** Impossible with WAV: a streaming-convention header
  (`0xFFFFFFFF`) uploads successfully and is then rejected with `invalid argument`.
- **An opaque, automatic dictionary of every correction.** Rejected in that form: an invisible
  stored-term list can overrule clear audio and reinforce its own mistakes. The shipped alternative
  is opt-in, bounded, visible, undoable, spelling-only, and withholds number-bearing entries from
  bare recogniser hint channels.
