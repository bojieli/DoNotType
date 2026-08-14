# Format fixtures

The same 1.5 seconds of speech, in the four formats every client is expected to read. Cut from
`../git-command.wav` with ffmpeg:

```bash
ffmpeg -i ../git-command.wav -t 1.5 -ar 16000 -ac 1 speech.wav
ffmpeg -i speech.wav -c:a libmp3lame -b:a 32k speech.mp3
ffmpeg -i speech.wav -c:a aac         -b:a 32k speech.m4a
ffmpeg -i speech.wav -c:a libopus     -b:a 16k speech.opus
```

**Speech rather than silence, deliberately.** A decoder that drops every sample still returns the
right *length* of silence, so a silent fixture cannot tell a working decoder from one that produced
nothing at all. These carry a signal, and the tests assert the decoded audio is audible — a peak
well above zero — as well as the right length.

Shared by all four platforms' tests rather than copied into each, for the same reason `PROMPT.md`
is: four copies are four chances for one of them to drift.

Lengths differ slightly by design. MP3 and AAC are block codecs and pad the tail; Opus declares a
pre-skip and runs at 48 kHz internally. Anything asserting an exact frame count here would be
asserting a property of the encoder rather than of the decoder, so the tests allow a tolerance.
