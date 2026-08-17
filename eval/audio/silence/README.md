# Recordings with nothing in them

Seven files that a dictation tool must never produce words from, and the reason a gate exists at all.

## Why these matter more than they look

A speech model handed silence does not reliably return silence. Asked to transcribe three seconds
of room tone it will often produce a plausible sentence — the well-documented case is a stock
phrase like "Thank you." or a subtitle credit — and a dictation tool that types that into somebody's
document has invented words they never said.

`prompt/system.md` rule 7 asks for an empty transcript in exactly this case, and that rule is not enough on
its own for two reasons:

1. **It only reaches model providers.** Deepgram, xAI and Mistral Voxtral are speech recognition
   endpoints with no system instruction, so the rule is never sent to them at all. Whisper-family
   recognisers are the best documented for this behaviour, which makes the gap the wrong way round.
2. **An instruction is a request, not a guarantee**, even where it is delivered.

So the audio is checked before the request, by `SpeechActivity`, and these are what it is checked
against. A backend cannot hallucinate audio it never received.

## The files

| file | what it is | why it is here |
|---|---|---|
| `digital-silence.wav` | 3 s of zero samples | the floor case; a muted microphone |
| `room-tone.wav` | 3 s of quiet broadband noise | an open microphone in a quiet room |
| `steady-noise.wav` | 3 s of louder broadband noise | a fan, air conditioning, a car |
| `hum.wav` | 3 s of 50 Hz tone | mains buzz — *louder than quiet speech*, and still not speech |
| `click.wav` | one 8 ms transient | a key press or a desk knock; huge dynamic range, no duration |
| `too-short.wav` | 0.33 s of quiet noise | a tap on the hotkey rather than a hold |
| `mouse-click-quiet-room.wav` | 0.76 s, one real mouse click | **the one that got through** — see below |

All are 16 kHz mono 16-bit, the format everything downstream assumes. Rebuild them with
`make-silence.py` in this directory; the generator is seeded, so the files are reproducible.

## What they measure

`SpeechActivity` runs the official Silero VAD v6.2.1 ONNX model locally. Each client uses the same
checked-in model bytes, 512-sample windows, 64 samples of carried context and recurrent state.
Segment finalisation uses Silero's defaults: 0.5 to begin speech, 0.35 to end it, 100 ms of silence
to close a segment and a minimum speech duration greater than 250 ms.

| audio | highest Silero probability | finalised speech |
|---|---:|---:|
| digital silence | 0.009 | 0 ms |
| room tone | 0.120 | 0 ms |
| steady noise | 0.032 | 0 ms |
| 50 Hz hum | 0.012 | 0 ms |
| keyboard click | 0.009 | 0 ms |
| **mouse click, quiet room** | **0.131** | **0 ms** |
| **one-word “Yes” fixture** | **1.000** | **481 ms** |
| **real speech** | **1.000** | **1,500 ms** |
| real speech at −32 dB | 1.000 | 1,404 ms |
| real speech at −46 dB | 0.993 | 1,020 ms |
| real speech at −52 dB | 0.832 | 700 ms |

The `hum` fixture is louder than the quiet-speech cases, which is why an absolute volume gate would
be wrong. Silero distinguishes their speech structure without deriving a threshold from the
recording itself.

## Using them

The same seven files are read by the Swift, C# and Kotlin test suites, so all four clients are held to
the same numbers.

They are also the audio for the `silence` evaluation cases, which ask a real provider to transcribe
them and assert that what comes back is empty. That is the half no unit test can do: the gate stops
the audio reaching the model, and the eval measures what the model would have done with it.

```bash
dnt-eval silence --provider gemini
dnt-eval silence --provider deepgram   # the interesting one: it never sees the contract
```

## The one that got through

`mouse-click-quiet-room.wav` is not synthesised. It is a real recording this app stored, and it
defeated the original recording-relative gate: 380 ms above the floor, comfortably past its 200 ms
threshold, because the room was quiet enough (−63 dB) that a −37 dB click sat 26 dB above it. In a
silent room *any* sound clears a relative margin.

The model was then handed it along with 10,000 characters of screen context and answered with 876
characters of fluent prose about what the screen appeared to be discussing. Nine words of that
appeared on screen; the rest was invented. That is the failure this whole corpus exists to prevent,
happening in production.

The hand-built detector needed a special spectral rule to separate it from a real one-word answer.
Silero makes that distinction directly:

| | this click | “Yes.” |
|---|---:|---:|
| old detector | 380 ms | 320 ms |
| highest Silero probability | 0.131 | 1.000 |
| Silero-finalised speech | 0 ms | 481 ms |

A change that sends the click has reintroduced the bug; a change that rejects
`../short-word.wav` has broken one-word answers. Both therefore run through the real ONNX model in
every platform's unit suite.
