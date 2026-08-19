# Client feature parity

What each of the four clients — macOS, Windows, Android, iOS — can do, and, where something is
missing, whether it is missing because nobody has built it or because the platform does not allow
it. The second kind is recorded with its cause: "not on iOS" reads as neglect until the sandbox
restriction behind it is written down. This document also records the `--mode` spellings shared by
all four parsers and the settings surface of the clients.

Checked by reading each client's source rather than from memory. Where a row says ✅ the feature
is reachable by a user of that client, not merely present in its core library.

## Dictation

| | macOS | Windows | Android | iOS |
|---|---|---|---|---|
| Hold a key and speak | ✅ Right ⌘ | ✅ Right Ctrl | ✅ keyboard button | ✅ keyboard button ¹⁶ |
| Tap to toggle, hold to talk | ✅ | ✅ | ✅ | ✅ |
| Cancel recording or transcription | ✅ Escape / None | ✅ Escape / None | ✅ drag off the button ¹⁴ | ✅ ¹⁴ |
| Finish recording, insert, and submit | ✅ Return / ⌘Return / Off ¹⁵ | ✅ Enter / Ctrl+Enter / Off ¹⁵ | — ¹⁵ | — ¹⁵ |
| Push-to-talk / hands-free as a *setting* | ✅ | ✅ | — ¹ | — ¹ |
| Rewrite a dictation | ✅ second hotkey | ✅ second hotkey | ✅ style chips | ✅ style picker |
| Says why a rewrite is unavailable | ✅ | ✅ | ✅ | ✅ |
| Summarise a dictation live | — ⁶ | — ⁶ | — ⁶ | — ⁶ |
| Undo the last insertion | ✅ ⌘⇧Z | ✅ Ctrl+Shift+Z | — ² | — ² |
| Revert a rewrite to verbatim | ✅ ⌘⌥Z | ✅ Ctrl+Alt+Z | — ² | — ² |
| Put a past transcript in again | ✅ ³ | ✅ ³ | ✅ ³ | ✅ ³ |
| Start/stop tones | ✅ | ✅ | — ⁴ | — ⁴ |
| Pin a microphone | ✅ | ✅ | — ⁵ | — ⁵ |

¹ The gesture is the setting. A phone has one button, and it already does both: a tap toggles, a
hold talks. There is no second input to assign, so a preference would be a control with nothing to
control.

² The transcript goes into a text field the user owns, and both platforms have their own undo for
that. A keyboard deleting characters it did not necessarily insert is a worse bet than the system's.
The verbatim text is in History on every platform, which is what makes the desktop version cheap.

³ A list rather than a shortcut, on all four: every transcript is in History, and selecting one
puts it in again. A dedicated re-paste key existed on the desktops and was removed — it did the
same job as picking the entry actually meant, but only ever for the newest one, which is rarely
the missing one.

⁴ A keyboard already makes its own sounds, and an app in the foreground is being looked at. The
desktop tone exists because the overlay is at the bottom of the screen while the user looks
elsewhere.

⁵ Both systems route audio themselves and switch with the headset, which is the behaviour expected
on a phone. The desktop problem — the default silently following whatever was plugged in last —
does not arise the same way.

⁶ Deliberate, and the same on all four. Live dictation puts words where the cursor is, and a
summary of ten seconds of speech is not that. Summaries are offered where a recording is long
enough for one to mean something: the file transcription screen and `dnt transcribe --mode
summary:brief`. The wall is in the type system rather than in a convention — the live path is
typed `RewriteStyle`, which has no summary case, so no client can reach one by accident.

¹⁴ The mobile gesture cancels capture before it is sent. Desktop Escape also cancels an in-flight
request or rewrite, and is intercepted only during that active dictation; at idle it remains the
foreground application's key.

¹⁵ Desktop Return/Enter finishes capture only while recording and inserts the transcript. Sending
an additional Return/Enter is opt-in: the app latches that request before transcription and emits
the configured submit key only if the exact field focused at recording start still has focus after
insertion. Mobile clients already own their foreground recording UI but cannot submit a message in
another app, so there is no equivalent key.

¹⁶ The iOS keyboard cannot open a microphone itself. A cold press opens the containing app, starts
capture there, and asks the user to swipe back; while its five-minute audio session is warm, later
tap/hold dictations stay in the keyboard. The app still owns the same recorder and transcription
pipeline used by its main button.

## Screen grounding

| | macOS | Windows | Android | iOS |
|---|---|---|---|---|
| Read the focused field and window | ✅ accessibility tree | ✅ UI Automation | ✅ `AccessibilityService` | ❌ ⁷ |
| Screenshot fallback | ✅ | — ⁸ | — ⁸ | ❌ ⁷ |
| Turn grounding off | ✅ | ✅ | ✅ | ❌ ⁷ |
| Never read these apps | ✅ | ✅ | ✅ | ❌ ⁷ |
| Number check (second, screen-blind request) | ✅ | ✅ | ✅ | ❌ ⁷ |
| Keyterm biasing for recognisers | ✅ | ✅ | ✅ | ❌ ⁷ |
| Inspect what was sent | ✅ | ✅ | ✅ | ❌ ⁷ |

⁷ **Not possible.** An iOS app cannot read another app's screen; the sandbox has no equivalent of
the accessibility APIs the other three use, and no screenshot of anything it does not own. This is
the one platform-imposed capability difference between the clients, rather than a feature that has
simply not been ported. Everything downstream of grounding — the blocklist, keyterms — is
therefore absent too, because there is nothing for them to act on.

⁸ macOS falls back to a screenshot when an app exposes no readable text — Figma, a GPU-rendered
terminal, a PDF. UI Automation and `AccessibilityService` return text for most of what people
dictate into, so the fallback has not been needed; it is a gap rather than an impossibility.

## Transcription

| | macOS | Windows | Android | iOS |
|---|---|---|---|---|
| Transcribe a recording from disk | ✅ | ✅ | ✅ | ✅ |
| WAV, MP3, M4A, Opus | ✅ | ✅ | ✅ | ✅ |
| Verbatim, rewrite, summary modes | ✅ | ✅ | ✅ | ✅ |
| Split long recordings on silence | ✅ | ✅ | ✅ | ✅ |
| Re-send a stalled request to the same backend | ✅ | ✅ | ✅ | ✅ |
| Fallback backend when the primary stalls | ✅ | ✅ | ✅ | ✅ |
| Compress the upload with Opus | ✅ | ✅ | ✅ | ✅ |

## Other capabilities

| | macOS | Windows | Android | iOS |
|---|---|---|---|---|
| History with search and filters | ✅ | ✅ | ✅ | ✅ |
| Retry a failed dictation | ✅ | ✅ | ✅ | ✅ |
| …with the context it originally had | ✅ | ✅ | ✅ | n/a ⁷ |
| Retention policy and keep-audio | ✅ | ✅ | ✅ | ✅ |
| Edit the prompt | ✅ | ✅ | ✅ | ✅ |
| Log viewer, level, content toggle | ✅ | ✅ | ✅ | ✅ |
| Performance statistics | ✅ | ✅ | ✅ | ✅ |
| Copy a diagnostic report | ✅ | ✅ | ✅ | ✅ |
| Personal dictionary (manual + CSV) | ✅ | ✅ | ✅ | ✅ |
| Opt-in learning from spelling corrections | ✅ | ✅ | ✅ | ✅ ¹³ |
| Guided permissions | ✅ | ✅ ⁹ | ✅ | ✅ |
| Command line | ✅ `dnt` | ✅ `dnt.exe` | — ¹⁰ | — ¹⁰ |
| Stop trusting an idle connection | ✅ | ✅ | ✅ | ✅ |
| Open the connection while recording | ✅ | ✅ | ✅ | ✅ |
| Hedge and retry on their own connection | ✅ | ✅ | — ¹¹ | ✅ |
| Only type where the dictation started | ✅ | ✅ | ✅ | n/a ¹² |

⁹ Windows has no permission prompt for the microphone at all — access is a Settings toggle — so
what it does instead is open the privacy page when recording is refused.

¹⁰ There is no shell to run one in. The equivalent is the app.

¹¹ `HttpURLConnection` exposes no way to demand a connection that has never been used — the pool
is OkHttp's, inside the platform, and picking from it is not the caller's decision. Android gets
the other three rows, and what stands in for this one is that a failed exchange evicts its own
connection. The gap is real and the row says so rather than being marked met.

¹² The iOS keyboard keeps the insertion target while the containing app records and returns a
result through the shared container. After a cold microphone activation, the containing app opens
the host bundle identifier captured by the extension so iOS restores that keyboard/document; the
extension never attempts desktop-style cross-app injection, so there is no stored focus handle.

¹³ iOS is best-effort. A keyboard extension sees only the active document's limited text context,
and it stops running while another keyboard is active. DoNotType persists a one-minute correction
anchor and checks the same document when its keyboard returns; if the user never switches back,
iOS provides no process that can observe the edit. Windows uses UI Automation and Android uses the
active `InputConnection`, so both can watch the exact insertion target continuously.

The four connection rows exist because the tail they fix was worth 24% of dictations taking
between 20 and 69 seconds while the model was answering in 2.1. Measured on macOS and described in
`ProviderTransport`; ported by hand, so this table records whether the port
happened.

Retrying with the original context is listed separately because it was silently wrong on two
clients until recently: Windows and Android re-ran the request *ungrounded*, which made a retry a
different question from the one that failed, on a row that still named the same provider and
model. On iOS there is no context to reuse, so the row is not applicable rather than met.

## Settings

The settings the clients expose, with platform differences noted where they exist. The measured
comparisons cited here are described with their method in [EVALUATION.md](EVALUATION.md).

- **Providers and keys.** The provider is who serves the request and the model is what runs it,
  so they are two fields and the window states the pair: *gemini-3.5-flash via Google*. Google,
  OpenRouter, a self-hosted server (vLLM, llama.cpp), or a speech recognition service (xAI,
  Deepgram, Mistral Voxtral), with a live connection test. Keys and models are stored per
  provider, so switching backends to compare them is one dropdown rather than a re-typing
  exercise. Keys live in the Keychain / DPAPI / Android Keystore, never in a config file.
- **Recognition services are a different trade.** They return a transcript in around 1.2 s against
  6.5 s for a model, and cannot read the screen. xAI can still rewrite, on a Grok chat model
  behind the same key; Deepgram and Voxtral cannot. Selecting one states that under the picker
  rather than leaving grounding controls that have no effect. Spelling hints from the screen
  are not offered: measured, they made transcripts worse, by feeding the recogniser whatever was
  on screen — including the term that was not said. Without them xAI scores 15/48 on the near-miss
  suite against native Gemini's 43–44/48, at 1.19 s against 5–60 s — an order of magnitude faster,
  and much less accurate on exactly the identifiers that suite is built from. Gemini via Google is
  the default, because grounding is what this tool is for and a recogniser cannot do it at all:
  defaulting to one shipped a fresh install with the headline feature structurally inert. The
  speed is a real preference and xAI is one dropdown away, keeping its own key and model. Deepgram
  cannot transcribe Chinese under any autodetecting setting, failing 44 of 68 Mandarin clips
  outright. Voxtral and xAI both handle Mandarin and English together.
- **Fallback.** An optional second backend, started only once the primary has clearly stalled. The
  first-party Gemini API is the most accurate measured and its latency is bimodal: six sequential
  requests for one three-second clip took 4.9, 61.6, 50.5, 5.8, 5.9 and 30.2 s. The fallback
  bounds that tail. Both services, both keys, and how long the primary gets alone are chosen by
  the user; history records which one actually answered, because a tool whose transcript quality
  varied invisibly would not be worth trusting.
- **Hotkey.** Which key, whether a tap toggles or a hold talks, and an optional second key bound
  to a rewrite (formal, concise, casual) for producing an email rather than a transcript. The
  main key always stays verbatim. An opt-in finish-and-send action makes Return/Enter during
  recording insert and then submit with plain Return/Enter, `⌘ Return`, or `Ctrl+Enter`; the key
  continues to belong to the foreground app whenever recording is not active.
- **Shortcuts.** Undo the last insertion, or revert a rewrite to what was actually said: `⌘⇧Z` /
  `⌘⌥Z` on macOS, `Ctrl+Shift+Z` / `Ctrl+Alt+Z` on Windows. Both are cheap only because the
  verbatim transcript is always kept. Not `Ctrl+Z`, which belongs to whatever is being typed into.
- **Audio.** Pin a microphone rather than following the system default; start/stop tones are on by
  default and can be disabled.
- **Fidelity.** `raw` keeps every filler and correction; `light` (default) removes empty fillers,
  repetitions, false starts, and superseded corrections; `tidy` also applies standard casing and
  punctuation without rephrasing.
- **Grounding.** On/off, screenshot fallback, and two blocklists evaluated before capture.
- **History.** Search, filters, per-item retry and delete, retention policy, per-dictation
  timings, and a Context Inspector showing exactly what was sent with any dictation.
- **Stats.** Median and p95 wait, wait per second spoken, success rate, retries, and a per-model
  breakdown measured on the microphone and network in use rather than on a vendor's benchmark.
- **Prompt.** The contract is editable in place on any platform, validated before saving, and
  restorable to the shipped default.
- **Logs.** The last few thousand events, filterable by level and text, with the recording level
  beside them and one button to reveal the file. Transcripts stay out of the log unless explicitly
  enabled, and the panel says so when they are.

## Mode spellings

What `--mode` accepts, identically on all four platforms. The table is repeated verbatim in each
platform's test suite to keep parsing behavior aligned across clients.

| Typed | Means | Why |
|---|---|---|
| `verbatim` | verbatim | |
| `raw`, `transcribe`, `none` | verbatim | the spellings people reach for |
| `rewrite` | rewrite, casual | a bare stage takes that stage's default |
| `rewrite:formal` | rewrite, formal | |
| `rewrite:concise` | rewrite, concise | |
| `rewrite:casual` | rewrite, casual | |
| `rewrite:` | rewrite, casual | an unfinished colon is not a style |
| `rewrite:verbatim` | rejected | verbatim is not a rewrite; `--mode verbatim` says it |
| `summary` | summary, brief | |
| `summary:brief` | summary, brief | |
| `summary:bullets` | summary, bullets | |
| `summary:actions` | summary, actions | |
| `summarise`, `summarize` | summary, brief | both spellings |
| `SUMMARY:Bullets` | summary, bullets | case is not significant |
| ` summary ` | summary, brief | surrounding space is not significant |
| `` (empty) | rejected | |
| `nonsense` | rejected | |
| `rewrite:nonsense` | rejected | a wrong style is not silently the default |

Historical divergence: `rewrite:` and `summary:` used to differ — macOS took the default, Windows
rejected it, Android rejected it. No dependent behavior exposed the difference, so it was not
detected until the parsers were compared directly.

## Drift prevention

Ports are by hand, so these tables drift unless they are checked. Three of the mechanisms that
stop it:

- **Parity tests.** The [mode grammar table](#mode-spellings) is repeated verbatim in each
  language's test suite, and so are the numeric guard's cases. A shared fixture file would be read
  by whichever platform remembered to read it.
- **Text checked by diffing, not by reading.** For `FailureAdvice`, every case was printed through
  all three implementations and diffed. Reading code side by side finds structural differences and
  misses a word.
- **CI runs each platform's own decoders**, on a Windows runner and an Android emulator. Two
  silent wrong-duration bugs were found that way, both of which produced plausible audio of the
  wrong length rather than an error.

## See also

- [EVALUATION.md](EVALUATION.md) — measurement method and full numbers behind the figures cited in
  Settings.
- [CLI.md](CLI.md) — `dnt` and `dnt.exe`, including file transcription with `--mode`.
- [Documentation index](README.md)
