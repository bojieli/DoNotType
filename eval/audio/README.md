# Reference audio

The exact audio fixtures are present in this checkout. They are 16 kHz, mono, 16-bit PCM WAVs;
the `real-*` files are user-supplied recordings and are the only valid inputs for the real-speech
benchmark. The WAV payloads remain ignored by git, so verify the SHA-256 values below after copying
the fixtures to another machine. `MANIFEST.md` records the provenance and ground-truth anchors.

| case | file | duration | SHA-256 (prefix) |
|---|---|---:|---|
| `gemini-version` | `gemini-version.wav` | 3.044 s | `f59155640370…` |
| `port-number` | `port-number.wav` | 2.341 s | `8d16563b2b46…` |
| `person-name` | `person-name.wav` | 2.403 s | `7e2db622b503…` |
| `jargon-spelling` | `jargon-spelling.wav` | 2.708 s | `28907de63b18…` |
| `git-command` | `git-command.wav` | 2.895 s | `18a9c97ae505…` |
| `real-version-number` | `real-talk-gemini15.wav` | 22.000 s | `f3f7675222c6…` |
| `real-mandarin` | `real-mandarin.wav` | 22.000 s | `4aca3bc15b67…` |
| `real-codeswitch` | `real-codeswitch.wav` | 20.000 s | `817acab2574d…` |
| `real-acronym` | `real-acronym.wav` | 20.000 s | `73aa2f1a826f…` |
| `real-acronym-chain` | `real-acronym-chain.wav` | 20.000 s | `fcd89387fc11…` |
| `real-jargon` | `real-jargon.wav` | 20.000 s | `4d024fcf7394…` |
| `real-brand` | `real-brand.wav` | 20.000 s | `639f55c192e0…` |
| `benefit-novel-name` / `benefit-caret-channel` | `novel-name.wav` | 2.620 s | `f1aba3279d1a…` |
| `benefit-novel-codename` | `novel-codename.wav` | 2.845 s | `6190253bf677…` |
| `benefit-novel-repo` | `novel-repo.wav` | 2.703 s | `3838c821face…` |

The five short clips are synthesized plumbing controls. They are retained to exercise transport
and scorer paths, but must not be presented as evidence about real-speech substitution. The
15/16-case exact-fixture campaign in `eval/results/local-real-audio-2026-08-10.json` uses the
uploaded WAVs and downloaded, pinned checkpoints only; the known synthetic stand-in hash is
explicitly rejected.

Before recording a new result, run an audio-only transcription or listen to the clip and record its
SHA-256. Do not replace a missing real fixture with generated audio.
