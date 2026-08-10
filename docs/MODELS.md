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

## Open-weight models

Worth tracking, because a local model would remove the API key, the network dependency and the
privacy question in one move. The capability now exists in the open — what is missing here is
access, not models.

**Context-conditioned transcription is a solved idea in open weights.** The mechanism this project
needs has a name in the ASR world — *context biasing* or *prompt conditioning* — and several open
models ship it:

| Model | Licence | Relevance |
|---|---|---|
| [Voxtral Transcribe 2](https://mistral.ai/news/voxtral-transcribe-2/) (Mistral) | Apache 2.0 | **Ships context biasing explicitly**, plus diarization and word timestamps. The closest open analogue to what this app does. |
| [Qwen3-Omni](https://huggingface.co/Qwen/Qwen3-Omni-30B-A3B-Instruct) (Alibaba) | Apache 2.0 | Audio-LLM taking arbitrary text alongside audio — so screen context can be passed as-is, exactly as here. Reports open SOTA on 32 of 36 audio benchmarks. |
| [Gemma 4](https://ai.google.dev/gemma/docs/capabilities/audio) (Google) | Apache 2.0 | Native audio from 4B up; small enough to run locally. |
| [Ultravox](https://huggingface.co/fixie-ai/ultravox-v0_2) (Fixie) | open weights | Projects audio into the LLM's token space, so audio and text context share one prompt. |
| Whisper (OpenAI) | MIT | `initial_prompt` is the original context-conditioning hook — and it is *leaky*, known to hallucinate the prompt into output. That is this project's substitution bug, in the model everyone already uses. |

**None were testable from this setup**, and the reasons are worth separating:

| Model | Result |
|---|---|
| `mistralai/voxtral-small-24b-2507` | HTTP 404 — the OpenRouter **account's provider allowlist** excludes Mistral |
| `nvidia/nemotron-3-nano-omni-…:free` | HTTP 404 — same cause |
| `xiaomi/mimo-v2.5` | **accepted the audio and billed 0 audio tokens** — caught by the silent-drop guard |
| `thinkingmachines/inkling-small` | HTTP 502 from the upstream: audio payload rejected |

The third row is the notable one. `mimo-v2.5` is advertised as audio-capable, accepts an
`input_audio` block without complaint, and processes none of it. Without the guard it would have
returned a confident, entirely invented transcript — the second time that exact failure has been
caught by that check, on a different provider.

To test the blocked models, widen the provider allowlist in OpenRouter's account settings, or run
them locally — see **[GPU-TESTING.md](GPU-TESTING.md)**, which covers serving each candidate and
what to measure. `--provider local` points the client at your own `/v1/chat/completions` endpoint,
so no new code is needed.

## Recommendation

Use **`gemini-3.6-flash` on the native Gemini API**. It is the only configuration measured to
transcribe the reference clip correctly without help, and the only one supporting the pre-upload
path. OpenRouter is a working fallback and useful for models Google does not serve directly.

The open-weight path is the one worth watching. Voxtral Transcribe 2's context biasing is the same
idea this project implements by prompt, done inside the decoder where a prior can be weighted
rather than merely requested — which may be a better answer to the substitution problem than any
amount of instruction. Testing it needs a widened OpenRouter allowlist or a local runtime.
