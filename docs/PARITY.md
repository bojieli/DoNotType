# What each client can do

Four clients, one product. This is the table that says so — and, where something is missing, whether
it is missing because nobody has built it or because the platform will not allow it. The second kind
is worth writing down: "not on iOS" reads as neglect until you know the sandbox forbids it.

Checked by reading each client's source rather than from memory. Where a row says ✅ the feature is
reachable by a user of that client, not merely present in its core library.

## Dictation

| | macOS | Windows | Android | iOS |
|---|---|---|---|---|
| Hold a key and speak | ✅ Right ⌘ | ✅ Right Ctrl | ✅ keyboard button | ✅ app button |
| Tap to toggle, hold to talk | ✅ | ✅ | ✅ | ✅ |
| Cancel mid-recording | ✅ Escape | ✅ Escape | ✅ drag off the button | ✅ |
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

³ A list rather than a shortcut, on all four: every transcript is in History, and selecting one puts
it in again. A dedicated re-paste key existed on the desktops and was removed — it did the same job
as picking the entry you actually meant, but only ever for the newest one, which is rarely the one
you are missing.

⁴ A keyboard already makes its own sounds, and an app in the foreground is being looked at. The
desktop tone exists because the overlay is at the bottom of the screen while you look elsewhere.

⁵ Both systems route audio themselves and switch with the headset, which is the behaviour people
expect on a phone. The desktop problem — the default silently following whatever was plugged in
last — does not arise the same way.

⁶ Deliberate, and the same on all four. Live dictation puts words where your cursor is, and a
summary of ten seconds of speech is not that. Summaries are offered where a recording is long
enough for one to mean something: the file transcription screen and `dnt transcribe --mode
summary:brief`. The wall is in the type system rather than in a convention — the live path is typed
`RewriteStyle`, which has no summary case, so no client can reach one by accident.

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
the one real capability difference between the clients, and it is the platform's decision rather
than ours. Everything downstream of grounding — the blocklist, keyterms — is
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

## Everything else

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
| Guided permissions | ✅ | ✅ ⁹ | ✅ | ✅ |
| Command line | ✅ `dnt` | ✅ `dnt.exe` | — ¹⁰ | — ¹⁰ |
| Stop trusting an idle connection | ✅ | ✅ | ✅ | ✅ |
| Open the connection while recording | ✅ | ✅ | ✅ | ✅ |
| Hedge and retry on their own connection | ✅ | ✅ | — ¹¹ | ✅ |
| Only type where the dictation started | ✅ | ✅ | ✅ | n/a ¹² |

⁹ Windows has no permission prompt for the microphone at all — access is a Settings toggle — so
what it does instead is open the privacy page when recording is refused.

¹⁰ There is no shell to run one in. The equivalent is the app.

¹¹ `HttpURLConnection` exposes no way to demand a connection that has never been used — the pool is
OkHttp's, inside the platform, and picking from it is not the caller's decision. Android gets the
other three rows, and what stands in for this one is that a failed exchange evicts its own
connection. The gap is real and the row says so rather than being marked met.

¹² The iOS keyboard reads transcripts out of the shared container the app writes them into; there is
no cross-app focus to lose in between, so there is nothing here to get wrong.

The four connection rows exist because the tail they fix was worth 24% of dictations taking between
20 and 69 seconds while the model was answering in 2.1. Measured on macOS and described in
`ProviderTransport`; ported by hand, so the table is the thing that says whether the port happened.

Retrying with the original context is listed separately because it was silently wrong on two
clients until recently: Windows and Android re-ran the request *ungrounded*, which made a retry a
different question from the one that failed, on a row that still named the same provider and model.
On iOS there is no context to reuse, so the row is not applicable rather than met.

## Keeping this true

Ports are by hand, so this table drifts unless it is checked. Three of the mechanisms that stop it:

- **Parity tests.** `docs/mode-parity.md` is repeated verbatim in each language's test suite, and so
  are the numeric guard's cases. A shared fixture file would be read by whichever platform
  remembered to read it.
- **Text checked by diffing, not by reading.** For `FailureAdvice`, every case was printed through
  all three implementations and diffed. Reading code side by side finds structural differences and
  misses a word.
- **CI runs each platform's own decoders**, on a Windows runner and an Android emulator. Two silent
  wrong-duration bugs were found that way, both of which produced plausible audio of the wrong
  length rather than an error.
