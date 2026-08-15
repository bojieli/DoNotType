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
| Second key or chip that rewrites | ✅ second hotkey | ✅ second hotkey | ✅ style chips | ✅ style picker |
| Undo the last insertion | ✅ ⌘⇧Z | ✅ Ctrl+Shift+Z | — ² | — ² |
| Revert a rewrite to verbatim | ✅ ⌘⌥Z | ✅ Ctrl+Alt+Z | — ² | — ² |
| Paste the last transcript again | ✅ ⌘⌃V | ✅ Ctrl+Alt+V | ✅ ³ | ✅ ³ |
| Start/stop tones | ✅ | ✅ | — ⁴ | — ⁴ |
| Pin a microphone | ✅ | ✅ | — ⁵ | — ⁵ |

¹ The gesture is the setting. A phone has one button, and it already does both: a tap toggles, a
hold talks. There is no second input to assign, so a preference would be a control with nothing to
control.

² The transcript goes into a text field the user owns, and both platforms have their own undo for
that. A keyboard deleting characters it did not necessarily insert is a worse bet than the system's.
The verbatim text is in History on every platform, which is what makes the desktop version cheap.

³ Not a shortcut but a list: every transcript is in History and tapping one inserts it. That is the
same job — "put that in again" — with the input a touchscreen has.

⁴ A keyboard already makes its own sounds, and an app in the foreground is being looked at. The
desktop tone exists because the overlay is at the bottom of the screen while you look elsewhere.

⁵ Both systems route audio themselves and switch with the headset, which is the behaviour people
expect on a phone. The desktop problem — the default silently following whatever was plugged in
last — does not arise the same way.

## Screen grounding

| | macOS | Windows | Android | iOS |
|---|---|---|---|---|
| Read the focused field and window | ✅ accessibility tree | ✅ UI Automation | ✅ `AccessibilityService` | ❌ ⁶ |
| Screenshot fallback | ✅ | — ⁷ | — ⁷ | ❌ ⁶ |
| Turn grounding off | ✅ | ✅ | ✅ | ❌ ⁶ |
| Never read these apps | ✅ | ✅ | ✅ | ❌ ⁶ |
| Number check (second, screen-blind request) | ✅ | ✅ | ✅ | ❌ ⁶ |
| Keyterm biasing for recognisers | ✅ | ✅ | ✅ | ❌ ⁶ |
| Inspect what would be sent | ✅ | — ⁸ | — ⁸ | ❌ ⁶ |

⁶ **Not possible.** An iOS app cannot read another app's screen; the sandbox has no equivalent of
the accessibility APIs the other three use, and no screenshot of anything it does not own. This is
the one real capability difference between the clients, and it is the platform's decision rather
than ours. Everything downstream of grounding — the blocklist, the number check, keyterms — is
therefore absent too, because there is nothing for them to act on.

⁷ macOS falls back to a screenshot when an app exposes no readable text — Figma, a GPU-rendered
terminal, a PDF. UI Automation and `AccessibilityService` return text for most of what people
dictate into, so the fallback has not been needed; it is a gap rather than an impossibility.

⁸ A debugging view showing exactly what would be sent for the current window. Genuinely useful, and
genuinely absent on two clients.

## Transcription

| | macOS | Windows | Android | iOS |
|---|---|---|---|---|
| Transcribe a recording from disk | ✅ | ✅ | ✅ | ✅ |
| WAV, MP3, M4A, Opus | ✅ | ✅ | ✅ | ✅ |
| Verbatim, rewrite, summary modes | ✅ | ✅ | ✅ | ✅ |
| Split long recordings on silence | ✅ | ✅ | ✅ | ✅ |
| Fallback backend when the primary stalls | ✅ | ✅ | ✅ | ✅ |
| Compress the upload with Opus | ✅ | ✅ | ✅ | ✅ |
| Pre-upload during recording | ✅ | ✅ | — ⁹ | ✅ |

⁹ A latency optimisation for Gemini's Files API. Worth having; nobody has done it.

## Everything else

| | macOS | Windows | Android | iOS |
|---|---|---|---|---|
| History with search and filters | ✅ | ✅ | ✅ | ✅ |
| Retry a failed dictation | ✅ | ✅ | ✅ | ✅ |
| Retention policy and keep-audio | ✅ | ✅ | ✅ | ✅ |
| Edit the prompt | ✅ | ✅ | ✅ | ✅ |
| Log viewer, level, content toggle | ✅ | ✅ | ✅ | ✅ |
| Performance statistics | ✅ | ✅ | ✅ | ✅ |
| Copy a diagnostic report | ✅ | ✅ | ✅ | ✅ |
| Guided permissions | ✅ | ✅ ¹⁰ | ✅ | ✅ |
| Command line | ✅ `dnt` | ✅ `dnt.exe` | — ¹¹ | — ¹¹ |

¹⁰ Windows has no permission prompt for the microphone at all — access is a Settings toggle — so
what it does instead is open the privacy page when recording is refused.

¹¹ There is no shell to run one in. The equivalent is the app.

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
