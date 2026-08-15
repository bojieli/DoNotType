# The checks a machine cannot do

Almost everything in this project is tested automatically. Five things are not, and the first four
are what a user meets first.

The gap is not laziness. **Microphone capture** needs a microphone and a person making a noise into
it. **Text injection** needs a focused window belonging to another application and a permission CI
will never be granted. **A real transcription** needs a paid key. And **whether the words are
right** needs someone who knows what was said. No runner has any of those.

So they are a checklist, run by a person, once per release. Fifteen minutes for all four platforms.
Record the results in the release's draft notes: a release that says "dictation verified on macOS
and Windows, Android untested this cycle" is worth more than one that says nothing and leaves a
reader to assume the best.

## Before you start

```bash
dnt doctor --probe
```

One live request. If the key is wrong or the model is unavailable, find out here rather than halfway
through the checklist with a sentence already spoken.

---

## 1. The round trip

The whole product in one gesture. On each platform, with a text field focused in some *other*
application:

| | |
|---|---|
| macOS | hold Right ⌘, say a sentence, release |
| Windows | hold Right Ctrl, say a sentence, release |
| Android | switch to the DoNotType keyboard, hold the mic key, speak, release |
| iOS | open the app, hold the button, speak, release, then insert from the keyboard |

Say something with a number and a proper noun in it — *"tell Kaelith the 3.5 release ships Friday"* —
because that is the sentence shape this project exists to get right.

**Passes if** the words appear where the cursor was, they are the words you said, and the number is
the number you said.

**Watch for** the first word being clipped (capture started late), a trailing word missing (capture
stopped early), text landing in the wrong window (injection raced the focus), or the number being
"corrected" to something on screen (the failure this project is about — if you see it, it belongs in
`eval/nearmiss/` as a case).

## 2. Permissions, from cold

On a machine that has never run it, or after revoking:

- macOS — System Settings › Privacy & Security › Accessibility and Microphone, both off
- Android — revoke microphone in App info
- iOS — revoke microphone, and turn Full Access off for the keyboard

**Passes if** the app explains what it needs and why *before* asking, and the first dictation after
granting works without a restart. macOS revokes Accessibility whenever the signature changes, so an
updated build must ask again rather than silently failing to hear anything.

## 3. What happens when it goes wrong

Two of these have hardware in them, so they are here rather than in the automated suite:

- **Offline.** Turn off the network, dictate. The dictation should be *queued*, not lost, and say
  so. Reconnect: it should send itself.
- **A wrong key.** Change one character of the key, dictate. The message should say the key is
  wrong, not "The operation couldn't be completed".
- **Silence.** Hold the key, say nothing, release. Nothing should be typed and no history row
  written.

## 4. Silence, which must produce nothing

The one failure that needs no interpretation. Run it against whichever backend the release
recommends, and against a recogniser, because those never receive `PROMPT.md` at all:

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

## 5. A recording, offline

The other half of the product, and the only one of the four you can check without speaking:

```bash
dnt transcribe eval/audio/formats/speech.mp3
dnt transcribe eval/audio/formats/speech.opus --mode summary:bullets
```

**Passes if** both produce the same words, and the summary run also leaves the verbatim transcript
reachable — `--output` writes it to `.verbatim.txt`.

Do the same through the GUI on one platform, by dropping a file on the macOS window or picking one
on the others. The pickers and the drop handlers are the parts no test reaches.

---

## Recording the result

Paste this into the release notes, filled in:

```
Manual checks for vX.Y.Z
  round trip      macOS ✓   Windows ✓   Android ✓   iOS ✓
  permissions     macOS ✓   Android ✓   iOS ✓
  failure modes   macOS ✓
  silence         gemini ✓   deepgram ✓
  file transcription  macOS ✓   Windows ✓
  not checked     Android permissions — no device this cycle
```

"Not checked" is a legitimate entry and a useful one. What is not legitimate is silence, which reads
as "all fine" and is how the Windows app went months compiling and never starting.
