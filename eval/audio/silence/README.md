# Recordings with nothing in them

Six files that a dictation tool must never produce words from, and the reason a gate exists at all.

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

All are 16 kHz mono 16-bit, the format everything downstream assumes. Rebuild them with
`make-silence.py` in this directory; the generator is seeded, so the files are reproducible.

## What they measure

`SpeechActivity` keys on *modulation* rather than loudness — speech has syllables and pauses, a fan
does not — and counts how much audio sits clearly above the recording's own noise floor:

| audio | detected as speech |
|---|---|
| digital silence | 0 ms |
| room tone | 0 ms |
| steady noise | 0 ms |
| hum | 0 ms |
| click | 20 ms |
| **real speech** | **1160 ms** |
| real speech at −32 dB | 1160 ms |
| real speech at −46 dB | 800 ms |
| real speech at −52 dB | 240 ms |

The threshold is 200 ms. That is ten times the loudest thing here that is not speech, and a quarter
of speech attenuated until it is barely audible.

**The asymmetry is deliberate.** A stray "Thank you." typed into a document is annoying; dropping a
sentence somebody actually said is unforgivable. Where the two risks trade off, the gate errs
towards sending — which is why the `hum` case is in the table above. It is *louder* than quiet
speech and still correctly rejected, because level was never the signal.

## Using them

The same six files are read by the Swift, C# and Kotlin test suites, so all four clients are held to
the same numbers.

They are also the audio for the `silence` evaluation cases, which ask a real provider to transcribe
them and assert that what comes back is empty. That is the half no unit test can do: the gate stops
the audio reaching the model, and the eval measures what the model would have done with it.

```bash
dnt-eval silence --provider gemini
dnt-eval silence --provider deepgram   # the interesting one: it never sees the contract
```
