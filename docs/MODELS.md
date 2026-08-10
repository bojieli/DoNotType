# Model and provider benchmark

Which models can actually do this job, measured rather than assumed. Re-run on any model bump —
multimodal quality moves between releases and nothing else in this project would notice.

```bash
export OPENROUTER_API_KEY=...   # or GEMINI_API_KEY with PROVIDER=gemini
./eval/benchmark-models.sh                    # the default cross-vendor set
./eval/benchmark-models.sh "model-a model-b"  # specific models
./eval/model-sweep.sh                         # Gemini family, native API
```

## What is measured, and why in this order

Each question only matters if the previous one passed.

1. **Does the audio reach the model?** A provider that accepts an audio block and discards it
   returns a fluent, confident, invented transcript. This is the single worst failure mode here and
   it has been observed in the wild.
2. **Can it transcribe the reference clip with _no_ context?** A model that mis-hears the number
   cannot be scored for substitution at all — its errors are mis-hearing, not overwriting.
3. **Under hostile screen context, how often does it write the on-screen value instead of the
   spoken one?** This is the failure the project exists to prevent.

The reference clip (`eval/audio/real-talk-gemini15.wav`) is 22 seconds of a real recorded talk. The
speaker says "**Gemini 1.5**"; the test context repeats "**Gemini 2.5**" five times. The number is
unstressed and mid-sentence, which makes it a genuinely hard case — deliberately, because an easy
case measures nothing.

## Results — 2026-08-10

### Audio capability

Of 36 models advertising audio input on OpenRouter, these were reachable and tested.

| Model | Audio reaches the model | Notes |
|---|---|---|
| `gemini-3.6-flash` (native) | ✅ 550 tokens | best transcription overall |
| `google/gemini-3.6-flash` | ✅ | same model, via gateway |
| `google/gemini-3.5-flash` | ✅ | |
| `google/gemini-3-flash-preview` | ✅ | |
| `google/gemini-3.1-flash-lite` | ✅ | |
| `google/gemini-2.5-pro` | ✅ | |
| `openai/gpt-audio` | ✅ | see caveat below |
| `openai/gpt-audio-mini` | ✅ 220 tokens | markedly worse transcription |
| `mistralai/voxtral-small-24b-2507` | — | HTTP 404: account provider allowlist excludes Mistral |
| `nvidia/nemotron-3-nano-omni-…` | — | HTTP 404 |
| `meta/muse-spark-1.2` | — | HTTP 404 |
| `gemini-2.5-flash` (native) | — | retired: "no longer available to new users" |

### Transcription quality, no context

The same clip, no screen context. What each model heard where the speaker said "Gemini 1.5":

| Model | Heard | General quality |
|---|---|---|
| `gemini-3.6-flash` (native) | **"Gemini 1.5"** ✅ | "unified source and it continues the thinking" |
| `gemini-3.5-flash` | "Gemini 2.4" ❌ | "unified **sauce** and it continues **syncing**" |
| `gemini-3-flash-preview` | "Gimma 2.0" ❌ | "**verified** source and it continues syncing" |
| `openai/gpt-audio-mini` | "Gemini 2." ❌ | no punctuation at all; "the **L I M** processing speed" |

Only `gemini-3.6-flash` transcribes the number correctly, and its general transcription is visibly
better on the same audio. **`gemini-3.6-flash` is the default for this reason.**

### Substitution under hostile context

`gemini-3.6-flash`, native API, 20 trials:

| | count |
|---|---|
| correct (1.5) | 8 |
| **substituted (2.5)** | **11** |
| no version mentioned | 1 |

**58% substitution.** The control matters as much: with **no context at all** the model still
writes 2.5 in 21% of runs. So grounding roughly **doubles an already non-zero error rate** on this
clip rather than creating the error outright.

Older models cannot be given a substitution number at all — they never produce either the spoken or
the decoy value, so there is nothing to score.

## Provider matters, not just model

The same model ID served by different providers does not behave identically.

| Measurement | Native Gemini | OpenRouter | Sample |
|---|---|---|---|
| Near-miss suite, matched | 15/15 | 12/15 | 15 runs each |
| Reference clip correct, no context | 6/8 | 4/8 | 8 runs each |

The direction is consistent across two independent measurements, but **each is individually weak** —
6/8 versus 4/8 is nowhere near significant on its own. Treat this as "native is probably better,
worth preferring, not proven". Native is the default anyway, because it is first-party, honours
`store: false` directly, and supports the pre-upload path.

## Caveats worth knowing before trusting any of this

**`openai/gpt-audio` does not reliably transcribe.** Given audio and a transcription instruction it
sometimes returns a *conversational reply* instead: "It sounds like you're describing an interesting
interaction between how language models process information…". That is failure mode #2 in
`PROMPT.md` — answering rather than transcribing — and it makes the model unsuitable here regardless
of audio quality.

**`response_format` breaks some models.** `openai/gpt-audio` and `gpt-audio-mini` return a provider
error the moment a JSON schema is attached, while transcribing fine without one. The client now
retries once without the schema and remembers per model; structured output is a convenience here,
not a requirement, since `Transcript.parse` tolerates bare prose.

**Sample sizes are small.** Most cells above are 3–20 runs. Transcription is non-deterministic, so
single-digit differences are noise. The numbers are recorded to make regressions visible, not to
rank models to two decimal places.

**One clip is not a benchmark.** Everything here rests on one 22-second recording chosen because it
is hard. A model that does well on it may do worse elsewhere. Adding more real clips is the highest
-value contribution anyone could make to this file; see
[EVALUATION.md](EVALUATION.md#building-a-corpus).

## Local / open-weight models

A local model removes the API key, network dependency, and data-sharing question. These are the
results from the RTX PRO 6000 Blackwell workstation (`nvidia-smi`: 97,887 MiB VRAM) on 2026-08-10.

The authoritative real-speech fixtures, `eval/audio/real-talk-gemini15.wav` and
`eval/audio/real-mandarin.wav`, are not present in this checkout. The ignored file currently at
`real-talk-gemini15.wav` has the known synthetic TTS hash and is rejected by the benchmark guard.
The real fixtures could not be recovered from the repository or its upstream sources. Consequently,
**none of the cells below is a valid result against the hosted
real-speech baseline**. The model weights are the real downloaded checkpoints (not mock or
synthetic models): Voxtral, Gemma, Qwen, Ultravox, Whisper large-v3, and Voxtral Realtime. The WAVs used here are
synthetic espeak stand-ins, retained only as ignored files to exercise audio transport,
transcription, and context behavior. Do not compare their rates with the Gemini numbers above.

The downloaded snapshots were verified with
[`eval/download-checkpoint.py`](../eval/download-checkpoint.py); these are the immutable Hub
revisions used for the measurements:

| Model | Hub revision | Weight files / bytes |
|---|---|---:|
| `mistralai/Voxtral-Small-24B-2507` | `da5b42409f279fdd92febee0511a6c32828569c1` | 11 / 48,527,546,144 |
| `google/gemma-4-E4B-it` | `ee0ef6023621cff504d758262d4e04895a5af4a2` | 1 / 15,992,595,884 |
| `Qwen/Qwen3-Omni-30B-A3B-Instruct` | `26291f793822fb6be9555850f06dfe95f2d7e695` | 15 / 70,523,299,202 |
| `fixie-ai/ultravox-v0_5-llama-3_1-8b` adapter | `94aa77f70ca548e669ea61f737e159b2fddbb7f7` | adapter + real backbone below |
| `unsloth/Meta-Llama-3.1-8B-Instruct` backbone | `a2856192dd7c25b842431f39c179a6c2c2f627d1` | 4 shards / downloaded |
| `openai/whisper-large-v3-turbo` audio encoder | `41f01f3fe87f28c78e2fbf8b568835947dd65ed9` | downloaded |
| `openai/whisper-large-v3` | `06f233fe06e710322aca913c1bc4249a0d71fce1` | 6 / 18,523,040,177 |
| `mistralai/Voxtral-Mini-4B-Realtime-2602` | `2769294da9567371363522aac9bbcfdd19447add` | 2 / 17,718,909,592 |

No synthetic checkpoint, randomly initialized model, or generated weights were used.

### Measured on this GPU (synthetic stand-ins)

| Model / runtime | Audio processed | No-context reference | Hostile-context reference | Near-miss suite | Latency |
|---|---|---:|---:|---:|---:|
| `mistralai/Voxtral-Small-24B-2507`, Transformers 4.57.6, bf16 | yes (mel features; token usage not exposed), ~46 GiB loaded | 15/15 (`Gemini 1.5`) | 15/15; 0/15 substitutions | 15/15 grounded; 12/15 no-context | ~1.38 s/generation |
| `google/gemma-4-E4B-it`, isolated Transformers 5.15.0.dev0, bf16 | yes (decoded 16 kHz samples; token usage not exposed), ~15.5 GiB loaded | 15/15 (`Gemini 1.5`) | 15/15; 0/15 substitutions | 3/15 grounded; 3/15 no-context | ~0.97 s no-context; ~0.84 s hostile |
| `Qwen/Qwen3-Omni-30B-A3B-Instruct`, vLLM 0.19.0, bf16 | yes (transcript quality; usage did not report audio tokens), ~59.3 GiB loaded | 1/1 judged correct on probe; full synthetic scorer often saw number words | 0/15 substitutions (15/15 judged correct) | 5/15 exact matches (strict synthetic strings) | ~1.36 s no-context; ~2.56 s two-pass |
| `openai/whisper-large-v3`, openai-whisper 20240930, fp16 CUDA | yes; token usage unavailable, ~5.9 GiB allocated | 15/15 (`Gemini 1.5`) | 15/15; 0/15 substitutions | 0/15 grounded with `initial_prompt`; 12/15 no-context | ~0.59 s no-context; ~0.54 s hostile |
| `fixie-ai/ultravox-v0_5-llama-3_1-8b` + real Llama/Whisper, Transformers 4.57.6, bf16 | yes; 12 s opening segment, ~8.1B params | Chicago 15/15 | Chicago 15/15; Seattle 0/15 | not run (architecture has no benchmark fixture) | ~0.68 s no-context; ~0.42 s hostile |

Voxtral and Gemma were run through their native Transformers processors rather than vLLM. Voxtral
used the model's dedicated transcription mode for the reference check and audio-instruct mode for
the context tests. Gemma required an isolated Transformers build because the stable global
Transformers 4.57.6 does not recognize the checkpoint's `gemma4` architecture; passing an audio
array avoided a TorchCodec/FFmpeg loader failure. Qwen used the OpenAI-compatible fallback harness
in [`eval/local-gpu-benchmark.py`](../eval/local-gpu-benchmark.py), which mirrors the Swift
provider's prompt, context ordering, audio block, and JSON schema.

### Additional real-checkpoint smoke test

The newly released `mistralai/Voxtral-Mini-4B-Realtime-2602` checkpoint was downloaded and verified
at Hub revision `2769294da9567371363522aac9bbcfdd19447add` (two weight files, 17,718,909,592
bytes; bf16) and loaded through Transformers 5.15.0.dev0. It processed Mistral's public
real-speech `patrickvonplaten/audio_samples/obama.mp3` sample (3,256,320 samples; 128 × 20,744
mel features). With `max_new_tokens=128`, generation took 2.73 seconds and returned a coherent
Obama farewell-address transcript beginning:

```text
This week, I traveled to Chicago to deliver my final farewell address to the nation, following in
the tradition of presidents before me.
```

This is a real-audio checkpoint smoke test, not the DoNotType benchmark: Realtime's processor
accepts audio only and exposes no screen-context or context-biasing input. The exact
`real-talk-gemini15.wav` file is still required for the substitution experiment.

The same 203.52-second Obama recording was also sent through the previously downloaded priority
weights: Gemma produced a coherent transcript in 2.49 seconds, Voxtral Small in 6.52 seconds,
Qwen through vLLM in 4.98 seconds (3,314 prompt tokens; audio-token usage was not reported), and
Whisper large-v3 in 18.48 seconds. Voxtral Realtime produced the opening transcript in 2.73 seconds.
Ultravox was loaded from its real adapter plus the downloaded
unsloth Llama backbone and Whisper large-v3-turbo encoder; its 12-second opening-segment probe
returned the same Chicago sentence in 0.98 seconds. All six downloaded checkpoints processed real
audio. These are
recognition smoke-test observations only; there is no paired screen context or verified word-level
reference for this sample.

To exercise context handling on genuine speech while the DoNotType fixtures were unavailable, the
four downloaded multimodal checkpoints were each run 15 times with and without a hostile context block. The
recording says **Chicago** in its opening sentence; the context repeated **Seattle** eight times.
Every trial from every model retained Chicago and emitted no Seattle. This is evidence that these
checkpoints process real audio and can resist this particular proper-noun decoy, not a substitute for
the missing Gemini 1.5-versus-2.5 reference experiment. The complete machine-readable record,
including the WAV hash and checkpoint revisions, is in
[`eval/results/local-real-audio-2026-08-10.json`](../eval/results/local-real-audio-2026-08-10.json).

| Model | No context | Hostile context | Mean latency (no / hostile) |
|---|---:|---:|---:|
| `Qwen/Qwen3-Omni-30B-A3B-Instruct` (vLLM) | Chicago 15/15; Seattle 0/15 | Chicago 15/15; Seattle 0/15 | 4.11 s / 4.12 s |
| `google/gemma-4-E4B-it` (Transformers) | Chicago 15/15; Seattle 0/15 | Chicago 15/15; Seattle 0/15 | 2.08 s / 2.04 s |
| `mistralai/Voxtral-Small-24B-2507` (Transformers, 128-token cap) | Chicago 15/15; Seattle 0/15 | Chicago 15/15; Seattle 0/15 | 4.63 s / 4.64 s |
| `openai/whisper-large-v3` (12-second opening segment, HF snapshot, `initial_prompt`) | Chicago 15/15; Seattle 0/15 | Chicago 15/15; Seattle 0/15 | 0.34 s / 0.33 s |
| `fixie-ai/ultravox-v0_5-llama-3_1-8b` (12-second opening segment, chat-template prompt) | Chicago 15/15; Seattle 0/15 | Chicago 15/15; Seattle 0/15 | 0.68 s / 0.42 s |
| `mistralai/Voxtral-Mini-4B-Realtime-2602` (full audio, streaming ASR; 1 probe) | Chicago 1/1; Seattle 0/1 | not supported | 2.73 s / n/a |

Whisper used the first 12 seconds of the same recording because the anchor occurs in its opening
sentence; its segment hash is recorded in the result file. The three priority checkpoints used the
full 203.52-second WAV; Ultravox used the 12-second opening segment because its encoder context is
shorter. These cells are intentionally labeled as a separate real-audio smoke
test: they do not establish the DoNotType substitution rate, because the speech says Chicago, not
the missing Gemini 1.5 reference phrase.

Representative synthetic reference output:

```text
Voxtral: Um, so we're still on Gemini 1.5 Flash for the batch job, you know, and I think
          the unified source continues the thinking. We should keep the current model for now.
Gemma:   Um, so we're still on Gemini 1.5 flash for the batch job, you know, and I think
          the unified source continues the thinking. We should keep the current model for now.
Qwen:    recurring version fragment: "Gemini one point five"
Whisper: Um, so we're still on Gemini 1.5 Flash for the batch job, you know, and I think
         the unified source continues the thinking. We should keep the current model for now.
```

The strict near-miss scorer compares normalized full strings. Synthetic TTS changed punctuation,
capitalization, and wording, so failures are often scorer/stand-in mismatches rather than evidence
of a real-speech regression. For Gemma, the non-Gemini cases illustrate actual model behavior under
this prompt: it copied `8080` for spoken `8081`, omitted `Priya`, and copied `--no-edit`. For
Voxtral, context corrected the synthetic `coffee` → `koffi` spelling case without changing the
version or port. Whisper's `initial_prompt` control was especially clear on this easy synthetic
set: its no-context baseline matched 12/15, while adding the screen text matched 0/15 and caused
9/15 regressions (the other six were already wrong). This reproduces prompt-conditioned leakage as
a control observation, but not on the missing hard real-speech clip.

### Runtime-blocked candidates

| Model | Result |
|---|---|
| `google/gemma-4-E4B-it` (vLLM) | vLLM failed before loading: Transformers 4.57.6 does not recognize `model_type: gemma4`. The isolated Transformers run above is the compatible fallback. |
| `fixie-ai/ultravox-v0_5-llama-3_1-8b` | Its config names the gated `meta-llama/Llama-3.1-8B-Instruct` backbone (HTTP 403). A complete compatible real backbone, `unsloth/Meta-Llama-3.1-8B-Instruct`, was downloaded and wired into a temporary local snapshot; the resulting real-audio smoke test is recorded above. |
| `mistralai/Voxtral-Small-24B-2507` (vLLM) | vLLM 0.19.0 failed while loading current `audio_tower.*` weights into `LlamaForCausalLM`; direct Transformers succeeded. |
| `voxtral-mini-transcribe-26-02` (Voxtral Transcribe 2) | Mistral documents this as an API model, not a public Hub snapshot. The checkpoint helper returned 404 for the corresponding Hub ID and no `MISTRAL_API_KEY` is configured, so the decoder-level context-biasing A/B remains unavailable. |

The installed Voxtral Small processor/transcription request exposes no `context_biasing` parameter.
That decoder-level control belongs to a separate Voxtral Transcribe 2 serving surface, so the
requested A/B biasing experiment could not be run on this checkpoint.

### Why these models remain worth tracking

The mechanism this project needs has a name in the ASR world — *context biasing* or *prompt
conditioning* — and several open models ship it:

| Model | Licence | Relevance |
|---|---|---|
| [Voxtral Transcribe 2](https://mistral.ai/news/voxtral-transcribe-2/) (Mistral) | Apache 2.0 | **Ships context biasing explicitly**, plus diarization and word timestamps. The closest open analogue to what this app does. |
| [Qwen3-Omni](https://huggingface.co/Qwen/Qwen3-Omni-30B-A3B-Instruct) (Alibaba) | Apache 2.0 | Audio-LLM taking arbitrary text alongside audio — so screen context can be passed as-is, exactly as here. Reports open SOTA on 32 of 36 audio benchmarks. |
| [Gemma 4](https://ai.google.dev/gemma/docs/capabilities/audio) (Google) | Apache 2.0 | Native audio from 4B up; small enough to run locally. |
| [Ultravox](https://huggingface.co/fixie-ai/ultravox-v0_2) (Fixie) | open weights | Projects audio into the LLM's token space, so audio and text context share one prompt. |
| Whisper (OpenAI) | MIT | `initial_prompt` is the original context-conditioning hook — and it is *leaky*, known to hallucinate the prompt into output. That is this project's substitution bug, in the model everyone already uses. |

Other open-weight models were not runnable from this setup:

| Model | Result |
|---|---|
| `mistralai/voxtral-small-24b-2507` via OpenRouter | HTTP 404 — the OpenRouter **account's provider allowlist** excludes Mistral (the local Transformers run above bypassed this) |
| `nvidia/nemotron-3-nano-omni-…:free` | HTTP 404 — same cause |
| `xiaomi/mimo-v2.5` | **accepted the audio and billed 0 audio tokens** — caught by the silent-drop guard |
| `thinkingmachines/inkling-small` | HTTP 502 from the upstream: audio payload rejected |

The third row is the notable one. `mimo-v2.5` is advertised as audio-capable, accepts an
`input_audio` block without complaint, and processes none of it. Without the guard it would have
returned a confident, entirely invented transcript — the second time that exact failure has been
caught by that check, on a different provider.

To test the remaining blocked models, widen the provider allowlist in OpenRouter's account
settings or provide a complete local backbone. See **[GPU-TESTING.md](GPU-TESTING.md)** for the
serving and measurement procedure. `--provider local` points the client at a local
`/v1/chat/completions` endpoint, so no new client code is needed.

## Recommendation

Use **`gemini-3.6-flash` on the native Gemini API**. It is the only configuration measured to
transcribe the reference clip correctly without help, and the only one supporting the pre-upload
path. OpenRouter is a working fallback and useful for models Google does not serve directly.

The open-weight path is the one worth watching. The local Voxtral Small and Gemma measurements
above are encouraging transport and runtime checks, but they are not evidence against the hosted
baseline until the real reference WAV is supplied. Voxtral Transcribe 2's context biasing is the
same idea this project implements by prompt, done inside the decoder where a prior can be weighted
rather than merely requested — and it remains the most promising follow-up experiment. It needs the
Transcribe 2 serving surface (the Small checkpoint tested here does not expose that parameter).
