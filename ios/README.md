# DoNotType for iOS

```bash
brew install xcodegen
cd ios && xcodegen generate && open DoNotType.xcodeproj
```

`project.yml` is the source of truth; the `.xcodeproj` is generated and not committed.

## Voice keyboard architecture

iOS does not let a keyboard extension open a microphone. "Allow Full Access" grants network and a
shared container — **not** the mic; `AVAudioSession.setActive` fails inside the extension with
`AVAudioSessionErrorCodeCannotStartRecording`.

That restriction determines where capture runs, but it does not require a transcript-picker UX.
DoNotType follows the same cold/warm handoff used by voice-first iOS keyboards:

```
keyboard extension                    containing app
  centred mic button ── cold URL ───▶ starts microphone
         │              warm command ─▶ records + transcribes
         ◀──── state + transcript over App Group / Darwin ────┘
         └── inserts through UITextDocumentProxy
```

On a cold first press, the keyboard persists a start request and opens `donottype://dictate`. The
app starts the same recorder/provider pipeline as its main dictation button and tells the user to
swipe back to the original text field. After the user stops, the result returns to the keyboard and
is inserted automatically.

The app keeps its audio input session warm for five minutes after a keyboard dictation. During
that window, a tap or hold on the keyboard mic sends start/stop commands without another app
switch. The outlined mic means cold; the filled mic means warm. iOS displays its microphone privacy
indicator while that warm input session is active. Samples are discarded between dictations, and
the recorder/audio session are released when the window expires.

The keyboard sets `hasDictationKey` because it supplies its own voice button; this prevents iOS
from adding the system dictation key beside it. A manual **Insert latest** action remains as a
recovery path for an interrupted result handoff.

The personal dictionary uses the same container. Manual entries and one-column CSV import are
managed in the app; the keyboard reads the current list for every insertion. Optional correction
learning stores a one-minute anchor around inserted text. Because corrections require switching to
a keyboard with letter keys, the anchor survives that switch and is checked when DoNotType becomes
active again. If the user does not return, iOS exposes no document context to observe, so this is
the one best-effort part of dictionary parity.

**Full Access is required** for the keyboard, because the App Group container is the command,
state, and result channel. The keyboard says so plainly rather than appearing broken when it is
off.

## No screen grounding

macOS has the accessibility API and Android has `AccessibilityService`. iOS has no user-grantable
equivalent — nothing in the sandbox lets one app read another's content. iOS therefore gets the
verbatim-transcription half of the product and not the grounding half.
