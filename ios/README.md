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
app starts the same recorder/provider pipeline as its main dictation button, then reopens the host
application whose bundle identifier the extension captured before the switch. Known system apps
use their registered URL and other hosts use a bundle-targeted Launch Services request; the manual
bottom-edge gesture remains a fallback because iOS has no public return-to-caller API. After the
user stops, the result returns to the visibly attached keyboard and is inserted automatically. A
Darwin update can arrive while the keyboard controller is hidden; that controller must leave the
result pending rather than clearing it after an insertion attempt through a stale
`UITextDocumentProxy`.

While waiting or transcribing, a separate Cancel control appears in the keyboard's top-right corner;
the primary Speak control never changes into a destructive action. Cancellation returns the shared
phase to idle, cancels the live pipeline and provider task, and checks task cancellation again
before history or insertion so a late response cannot type discarded text. The containing app
exposes the same action beneath its transcribing state.

The extension uses a compact 155-point surface: a full-width call-to-action, a geometrically
centered 170×58-point pill-shaped Speak control, then a utility row with Settings, the current
Dictate/Rewrite mode, Return, Undo, and Backspace. Tapping the mode button switches it; the choice
remains changeable while recording and is fixed when transcription begins.
Settings opens the containing app directly on its configuration screen; Return and Backspace
operate directly on the active `UITextDocumentProxy`, like transcript insertion. The system-owned
globe remains outside the custom surface, so the extension does not duplicate it.

The app keeps its audio input session warm after a keyboard dictation. Settings offers five
minutes, twelve hours, or until DoNotType closes; this makes the battery/privacy trade-off explicit
instead of silently choosing it. During that window, a tap or hold on the keyboard mic sends
start/stop commands without another app switch. The outlined mic means cold; the filled mic means
warm. iOS displays its microphone privacy indicator while that warm input session is active.
Samples are discarded between dictations, and timed sessions release the recorder/audio session
when their window expires.

A Live Activity mirrors Listening, Transcribing, and Ready on the Lock Screen and Dynamic Island.
It ends with the warm microphone session and does not provide execution time; background audio is
still the honest mechanism that owns capture. DoNotType does not open a hidden Picture-in-Picture
window to stay alive.

The keyboard sets `hasDictationKey` through UIKit because it supplies its own voice button; this
prevents iOS from adding the system dictation key beside it. Results remain pending in the App Group
until a visible keyboard can insert them automatically.

The personal dictionary uses the same container. Manual entries and one-column CSV import are
managed in the app; the keyboard reads the current list for every insertion. Optional correction
learning stores a one-minute anchor around inserted text. Because corrections require switching to
a keyboard with letter keys, the anchor survives that switch and is checked when DoNotType becomes
active again. If the user does not return, iOS exposes no document context to observe, so this is
the one best-effort part of dictionary parity.

Before starting, the keyboard also snapshots the public input context: text around the cursor,
selected text, keyboard/return types, and the document identifier. In Rewrite mode, a selection
turns speech into an edit instruction and only that selection is replaced. If iOS restores the
cursor at either edge, the keyboard verifies both surrounding anchors before replacing it; if the
field changed, the transcript stays on the clipboard and no document text is touched. A dedicated
Undo key restores the prior selection or removes the last insertion while its anchors still match.

**Full Access is required** for the keyboard, because the App Group container is the command,
state, and result channel. The keyboard says so plainly rather than appearing broken when it is
off.

## No screen grounding

macOS has the accessibility API and Android has `AccessibilityService`. iOS has no user-grantable
equivalent — nothing in the sandbox lets one app read another's content. iOS therefore gets the
verbatim-transcription half of the product and not the grounding half.
