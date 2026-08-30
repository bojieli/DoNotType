# Manual release checks

Almost everything in this project is tested automatically. Eight things are not, and the first four
are what a user meets first. This document is the checklist of those checks, run by a person, once
per release. Fifteen minutes for all four platforms.

The gap is not laziness. **Microphone capture** needs a microphone and a person making a noise into
it. **Text injection** needs a focused window belonging to another application and a permission CI
will never be granted. **A real transcription** needs a paid key. And **whether the words are
right** needs someone who knows what was said. No runner has any of those.

Record the results in the release's draft notes: a release that says "dictation verified on macOS
and Windows, Android untested this cycle" is worth more than one that says nothing and leaves a
reader to assume the best.

## Prerequisites

```bash
dnt doctor --probe
```

One live request. If the key is wrong or the model is unavailable, find out here rather than halfway
through the checklist with a sentence already spoken.

## 1. Round trip

The whole product in one gesture. On each platform, with a text field focused in some *other*
application:

| Platform | Action |
|---|---|
| macOS | hold Right ⌘, say a sentence, release |
| Windows | hold Right Ctrl, say a sentence, release |
| Android | switch to the DoNotType keyboard, hold the talk button, speak, release |
| iOS | switch to DoNotType keyboard, tap the outlined mic, swipe back, speak, then tap to stop |

Say something with a number and a proper noun in it — *"tell Kaelith the 3.5 release ships Friday"* —
because that is the sentence shape this project exists to get right.

**Passes if** the words appear where the cursor was, they are the words you said, and the number is
the number you said.

On Android, dictate a second sentence from the app itself: open DoNotType, which now opens on its
dictation screen, and tap its record button. The words go to the clipboard and to Latest rather than
into another app's field, because an app in the foreground has no field to type into. Both surfaces
run the same recorder and the same transcription, so this is checking the screen rather than the
pipeline: the meter appears, the button turns red, and the transcript arrives under "Latest".

Then, still on the keyboard, use the other two keys. Return in a search box should search rather
than insert a blank line, and its label should say which — "Go" in Chrome's omnibox, "Search" in a
search field, the arrow glyph in a message box that wants a newline. Tap backspace once for one
deletion; hold it and the deletions should run on, stopping the moment you lift.

On iOS, immediately dictate a second sentence while the keyboard mic is filled. It must start and
stop without opening the app again. Also hold the filled mic, speak, and release; release must stop
capture. After five idle minutes the mic should become outlined and the next press should repeat
the one-time app handoff.

**Watch for** the first word being clipped (capture started late), a trailing word missing (capture
stopped early), text landing in the wrong window (injection raced the focus), or the number being
"corrected" to something on screen (the failure this project is about — if you see it, it belongs in
`eval/nearmiss/` as a case).

### Finishing with Return/Enter

On macOS and Windows, try each post-insertion choice in turn. Start recording in a disposable chat
or test field, speak, and press Return/Enter instead of releasing or tapping the recording key.

- Insert only should finish recording, transcribe, and insert without submitting.
- Plain Return/Enter should insert the transcript and submit it once.
- `⌘ Return` / `Ctrl+Enter` should insert first and emit that exact chord once.
- Hold Escape and Return/Enter briefly during their active cases. The target must receive neither
  the physical key-down, its repeats, nor its key-up; only a configured later submit is delivered.
- Move to another field immediately after insertion: the overlay should say it was not sent, and no
  Return/Enter should reach the newly focused field.
- With recording and transcription both idle, test Return/Enter in another application. All three
  settings must leave it untouched.

**Passes if** only the recording-time key is captured, a successful path submits exactly once, and
focus movement, cancellation, transcription failure, or manual-paste fallback never submits.

## 2. Permissions from cold

On a machine that has never run it, or after revoking:

- macOS — System Settings › Privacy & Security › Accessibility and Microphone, both off
- Android — revoke microphone in App info
- iOS — revoke microphone, and turn Full Access off for the keyboard

**Passes if** the app explains what it needs and why *before* asking, and the first dictation after
granting works without a restart. macOS revokes Accessibility whenever the signature changes, so an
updated build must ask again rather than silently failing to hear anything.

## 3. Failure modes

Two of these have hardware in them, so they are here rather than in the automated suite:

- **Offline.** Turn off the network, dictate. The dictation should be *queued*, not lost, and say
  so. Reconnect: it should send itself.
- **A wrong key.** Change one character of the key, dictate. The message should say the key is
  wrong, not "The operation couldn't be completed".
- **Silence.** Hold the key, say nothing, release. Nothing should be typed and no history row
  written.

## 4. Silence must produce nothing

The one failure that needs no interpretation. Run it against whichever backend the release
recommends, and against a recogniser, because those never receive `prompt/system.md` at all:

```bash
dnt-eval silence --provider gemini
dnt-eval silence --provider deepgram
```

**Passes if** every recording returns an empty transcript. The command exits non-zero otherwise and
prints what was invented.

This is belt and braces: the app never sends these recordings, because `SpeechActivity` stops them
first. What this checks is the assumption underneath that gate — and if a backend invents a sentence
for silence here, it is worth knowing which one, since the gate is the only thing standing between
that behaviour and somebody's document.

## 5. Offline file transcription

The other half of the product, and the only one of the four you can check without speaking:

```bash
dnt transcribe eval/audio/formats/speech.mp3
dnt transcribe eval/audio/formats/speech.opus --mode summary:bullets
```

**Passes if** both produce the same words, and the summary run also leaves the verbatim transcript
reachable — `--output` writes it to `.verbatim.txt`.

Do the same through the GUI on one platform, by dropping a file on the macOS window or picking one
on the others. The pickers and the drop handlers are the parts no test reaches.

## 6. Level meter

Thirty seconds per client, and all four draw one: the pill on macOS and Windows, the strip above the
keyboard *and* the row under the app's record button on Android, the row under the record button on
iOS. The scale itself is asserted against the fixtures in `AudioLevelMeter`, in Swift, C# and
Kotlin; what no runner can check is whether the bars on screen are *yours*.

Hold the key — or the button — and watch the meter rather than the screen:

- **Talk normally.** The bars should follow the syllables and walk leftwards, tall where you were
  loud. A voice at a comfortable level should use roughly the top third of the meter and keep
  moving inside it — not sit flat against the ceiling, which is what the old meter did and the whole
  reason this check exists.
- **Stop talking, keep holding.** The meter should go flat and *keep scrolling*. Frozen means the
  levels stopped arriving; still waving means something is animating that is not the microphone.
- **Say one word loudly, close to the mic.** The bars should reach the top. Amber is a separate
  claim — that samples are being clamped — so on a sanely-set input it may take real shouting, and
  it not appearing at all is a pass rather than a fault.

**Passes if** all three do what they say, and the meter tracks your voice closely enough that the
bar for a word is drawn while you are still saying the next one.

On Android, run the three above twice — once on the keyboard bar and once on the app's dictation
screen. They draw from one implementation now, so what is being checked is that both are still
wired to a live microphone rather than that they agree on the scale. Two surfaces drawing different
bars for the same voice would be two verdicts on whether the microphone is working, which is the
one thing this meter exists to answer. The app's screen adds one claim of its own: the ring around
the record button should pulse with the newest bar, so a glance at the button is enough without
reading the meter.

**Watch for** a meter that advances in blocks rather than one bar at a time (capture buffers too
long — this is what half-second buffers looked like on Windows), and amber at a normal speaking
voice, which is a real finding rather than a bug: the input gain is set high enough to be damaging
the recording before any backend sees it. Say which it was in the notes.

## 7. Settings opens with the caret nowhere

Ten seconds per desktop client, and it is here rather than in a test because the settings window's
own accessibility tree is not readable from outside it: System Events reports a SwiftUI window with
zero children, so nothing outside the app can ask which field has the caret. What *can* be checked
from outside is the consequence, which is what this does.

On macOS and Windows, open Settings and — without clicking anything — type `zzz`.

**Passes if** nothing changes: no characters in the Model box, and on Windows no jump in the Service
dropdown. Then click into the Model field, close the window, and open it again. Type `zzz` a second
time. Still nothing: a reopened window does not restore the caret to where it was left, which is the
half of this that survived the first fix on macOS and needed AppKit to be told directly.

Then check the placement that *is* wanted. With no API key configured, opening the macOS panel puts
the caret in the API key field — that one has a reason, and the fix above must not have taken it
away.

Android and iOS need no check here: Android's `screenScaffold` takes the initial focus itself for
unrelated scrolling reasons, and SwiftUI on iOS focuses nothing on its own.

## Recording the result

Paste this into the release notes, filled in:

```
Manual checks for vX.Y.Z
  round trip      macOS ✓   Windows ✓   Android ✓ (keyboard + app)   iOS ✓
  keyboard keys   Android ✓ (return labelled, backspace repeats)   iOS ✓
  permissions     macOS ✓   Android ✓   iOS ✓
  failure modes   macOS ✓
  silence         gemini ✓   deepgram ✓
  file transcription  macOS ✓   Windows ✓
  level meter     macOS ✓   Windows ✓   Android ✓ (both surfaces)   iOS ✓
  settings focus  macOS ✓ (fresh + reopened)   Windows ✓
  not checked     Android permissions — no device this cycle
```

"Not checked" is a legitimate entry and a useful one. What is not legitimate is silence, which reads
as "all fine" and is how the Windows app went months compiling and never starting.
