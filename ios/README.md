# DoNotType for iOS

```bash
brew install xcodegen
cd ios && xcodegen generate && open DoNotType.xcodeproj
```

`project.yml` is the source of truth; the `.xcodeproj` is generated and not committed.

## Why the keyboard does not record

iOS does not let a keyboard extension open a microphone. "Allow Full Access" grants network and a
shared container — **not** the mic; `AVAudioSession.setActive` fails inside the extension with
`AVAudioSessionErrorCodeCannotStartRecording`.

That single restriction determines the whole architecture:

```
containing app                        keyboard extension
  records + transcribes                 reads + inserts
        │                                      ▲
        └── App Group container ───────────────┘
            + Darwin notification
```

The app owns dictation. Transcripts go into the App Group container and to the clipboard, and a
Darwin notification wakes the keyboard so a new transcript appears without a manual refresh.

The personal dictionary uses the same container. Manual entries and one-column CSV import are
managed in the app; the keyboard reads the current list for every insertion. Optional correction
learning stores a one-minute anchor around inserted text. Because corrections require switching to
a keyboard with letter keys, the anchor survives that switch and is checked when DoNotType becomes
active again. If the user does not return, iOS exposes no document context to observe, so this is
the one best-effort part of dictionary parity.

**Full Access is required** for the keyboard, because the App Group container is the only channel
it has. The keyboard says so plainly rather than appearing broken when it is off.

## No screen grounding

macOS has the accessibility API and Android has `AccessibilityService`. iOS has no user-grantable
equivalent — nothing in the sandbox lets one app read another's content. iOS therefore gets the
verbatim-transcription half of the product and not the grounding half.
