# Changelog

Notable changes, newest first. Behaviour changes that affect transcription quality carry the
measurement that justified them; see [docs/EVALUATION.md](docs/EVALUATION.md).

Format loosely follows [Keep a Changelog](https://keepachangelog.com/). This project has not cut a
release yet, so everything below is unreleased.

## Unreleased

### Added

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
- **Undo and revert-to-verbatim.** `⌘⇧Z` removes the last insertion; `⌘⌥Z` replaces a rewrite with
  the verbatim transcript. Cheap only because the original is always stored. Expires after a
  minute, since deleting characters from a field the caret has since left would destroy unrelated
  text.
- **Paste last transcript** (`⌘⌃V`), for when the first insertion landed in the wrong window.
- **Microphone selection**, pinned by device UID rather than ID so it survives reboots, falling
  back silently when the device is unplugged.
- **Launch at login** via `SMAppService`, so the toggle also appears in System Settings › Login
  Items where someone would look to remove it.
- **Optional start/stop tones**, off by default.
- **Cross-vendor model benchmark** (`eval/benchmark-models.sh`, results in
  [docs/MODELS.md](docs/MODELS.md)) covering 36 audio-capable models.
- 73 Swift unit tests, 24 C# unit tests, and an opt-in integration suite that runs against the live
  API on real recorded speech.

### Fixed

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
