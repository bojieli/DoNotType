# Testing open-weight models on a local GPU

This document describes how to run DoNotType against a locally hosted open-weight model and produce
numbers comparable to the hosted results in [MODELS.md](MODELS.md): candidate selection, checkpoint
download and verification, serving, DoNotType wiring, the measurement sequence, and the reporting
format.

## Scope and status

**Scope note (2026-08-10).** The requested non-Mistral GPU campaign is complete. The uploaded real
WAV fixtures were tested with six downloaded, pinned checkpoints; the exact results are in
[`eval/results/local-real-audio-2026-08-10.json`](../eval/results/local-real-audio-2026-08-10.json).
Mistral/Voxtral Transcribe 2 work is intentionally excluded by user direction and is not a blocker
for the results below. The older Voxtral commands and observations in this document are retained as
historical context only; do not run additional Mistral experiments for this scope.

## Rationale

The failure this project is stuck on — screen context overwriting a spoken version number, ~36% of
runs against a ~21% no-context baseline — may not be fixable by instruction at all. Whisper's
`initial_prompt` leaks in exactly the same way, which suggests prompt-conditioned ASR has this
property generally. Voxtral Transcribe 2 performs context biasing *inside the decoder*, where a
prior can be **weighted** rather than merely requested. That is a different mechanism, it is the
most promising lead available, and it has not been measured against this workload.

## Quick start

```bash
# on the GPU box
pip install vllm
vllm serve mistralai/Voxtral-Small-24B-2507 --port 8000

# on the client machine
export DNT_LOCAL_BASE_URL=http://<gpu-host>:8000/v1/chat/completions
swift run dnt-eval probe  --provider local --model mistralai/Voxtral-Small-24B-2507 \
                          --audio eval/audio/real-talk-gemini15.wav
swift run dnt-eval ablate --provider local --model mistralai/Voxtral-Small-24B-2507 --trials 15
```

The app already speaks `/v1/chat/completions`, so no new client code is needed. `--provider local`
exists purely to point that client at the local machine.

## Candidate models

Candidates in priority order:

| Priority | Model | VRAM (bf16) | Why |
|---|---|---|---|
| **1** | `mistralai/Voxtral-Small-24B-2507` | ~48 GB | Closest cached Mistral audio model to the Transcribe 2 context-biasing lead. |
| 2 | `Qwen/Qwen3-Omni-30B-A3B-Instruct` | ~60 GB (MoE, 3B active) | Takes arbitrary text alongside audio, exactly like the hosted path. Open SOTA on 32/36 audio benchmarks. |
| 3 | `google/gemma-4-E4B-it` | ~10 GB | Small enough for a single consumer card; establishes the floor. |
| 4 | `fixie-ai/ultravox-v0_5-llama-3_1-8b` | ~18 GB | Projects audio into the token space; a third architecture for comparison. |
| 5 | `openai/whisper-large-v3` | ~10 GB | Not an LLM — the control. Its `initial_prompt` is the original context hook and is known to leak. |
| control | `mistralai/Voxtral-Mini-4B-Realtime-2602` | ~18 GB | Downloaded streaming ASR control; audio-only, so it cannot take screen context or run the substitution A/B. |
| control | `Qwen/Qwen3-ASR-0.6B-hf` | ~2 GB | Downloaded compact ASR control; its explicit hotword/prompt field permits a proper-noun context smoke test but it is not a general audio LLM. |
| control | `openbmb/MiniCPM-o-4_5` | ~19 GB | Downloaded audio+LLM control; accepts text and audio in one chat turn, but its broader omni stack is outside the primary five-model comparison. |

Quantised builds (AWQ/GPTQ/GGUF) cut these substantially for card-limited setups. Note the quant in
the results — it is a confound worth recording.

If VRAM is tight, start with **Gemma 4 E4B**. A cheap negative result is still a result, and the
harness is identical.

## Serving

Download and verify the actual checkpoint before starting a server. `snapshot_download` caches the
immutable Hub revision and the helper refuses a snapshot that has no model weights; it never
creates or falls back to a synthetic model:

```bash
python3 eval/download-checkpoint.py mistralai/Voxtral-Small-24B-2507
# {"model_type": "voxtral", "path": "...", "revision": "...", "weight_bytes": ..., "weight_files": 11}
```

Use the printed snapshot path with a direct Transformers runner, or use the model ID with vLLM;
vLLM loads the same Hub checkpoint from its cache. Record the resolved revision in results so that
a later model update cannot be mistaken for a reproduction.

### vLLM (recommended — closest to the hosted API shape)

```bash
pip install "vllm>=0.9"

vllm serve mistralai/Voxtral-Small-24B-2507 \
  --port 8000 \
  --host 0.0.0.0 \
  --max-model-len 32768 \
  --gpu-memory-utilization 0.90
# multi-GPU: add --tensor-parallel-size 2
```

The downloaded Realtime control uses a different streaming endpoint and does not accept the
screen-context input used by DoNotType:

```bash
vllm serve mistralai/Voxtral-Mini-4B-Realtime-2602 --port 8000
```

Its real-checkpoint audio-only probe is recorded separately; do not interpret it as a context
substitution result.

Confirm the server is up and the model name it reports:

```bash
curl -s http://localhost:8000/v1/models | jq -r '.data[].id'
```

Use that exact string as `--model`.

### llama.cpp (GGUF, lower VRAM)

```bash
llama-server -m ./voxtral-small-q4_k_m.gguf --port 8000 --host 0.0.0.0
```

`llama-server` exposes the same OpenAI-compatible route, so nothing else changes.

### Whisper (the control — different shape)

Whisper is not an OpenAI-compatible chat server. Either front it with
[`faster-whisper-server`](https://github.com/fedirz/faster-whisper-server), or run it directly and
compare by hand:

```python
import whisper
model = whisper.load_model("large-v3")
# initial_prompt is the context hook. This is the leak being tested.
print(model.transcribe("real-talk-gemini15.wav",
                       initial_prompt="Gemini 2.5 Flash is the current model.")["text"])
```

If "2.5" appears in the output, the leak reproduced.

## Connecting DoNotType

Three environment variables, all optional except the first:

```bash
export DNT_LOCAL_BASE_URL=http://<gpu-host>:8000/v1/chat/completions
export DNT_LOCAL_MODEL=mistralai/Voxtral-Small-24B-2507   # default for --provider local
export DNT_LOCAL_API_KEY=whatever                        # only if the server requires auth
```

Then, from the repo root on the client machine:

```bash
swift build -c release
swift run dnt-eval probe --provider local --audio eval/audio/real-talk-gemini15.wav
```

Read the `audioTok` line first. If it says `0`, the run aborts with `audioSilentlyDropped` — the
server accepted the audio block and processed none of it, so any transcript would be invented. That
check has already caught two hosted providers doing exactly this. If it says "not reported", the
server does not return usage; the guard gives it the benefit of the doubt, so sanity-check the
transcript by ear once before trusting the numbers.

The macOS app can use the same server: Settings → Provider → **local**.

## Measurements

Three commands, in this order. Each only matters if the previous one passed.

```bash
# 1. Does the audio reach the model, and can it transcribe at all?
swift run dnt-eval probe --provider local --audio eval/audio/real-talk-gemini15.wav

# 2. The full comparison: no context / with context / rewrite variants, with latency
swift run dnt-eval ablate --provider local --trials 15

# 3. The near-miss suite, three runs per case
swift run dnt-eval suite eval/nearmiss --provider local --repeat-count 3
```

The reference clip is 22 s of a real talk. The speaker says **"Gemini 1.5"**; the test context
repeats **"Gemini 2.5"** five times. The number is unstressed and mid-sentence — deliberately hard,
because an easy case measures nothing.

### Historical hosted baselines

`gemini-3.6-flash`, native API.

These are historical handoff targets on a model the app no longer defaults to. The current
one-request-versus-two numbers, measured on `gemini-3.5-flash`, are in
[EVALUATION.md](EVALUATION.md#rewrite-one-request-against-two) — the latency ordering reverses
there, and the app ships the single request. The reference WAV is supplied and hash-verified; never
compare these rates with the synthetic stand-in or the public real-audio smoke clips.

| Condition | Substitution | Mean latency |
|---|---|---|
| no context at all | 21% (3/14) | 5.7 s |
| **verbatim + context** | **36% (4/11)** | 5.5 s |
| single-pass formalise | 38% (5/13) | 15.7 s |
| two-pass formalise | 75% (9/12) | 7.5 s |

Baseline transcription quality, no context: **6/8** correct on the reference clip.

The current local runs do not establish a useful substitution rate when a checkpoint fails the
no-context `Gemini 1.5` recognition gate. A model must first recover the spoken value before a
context substitution comparison is meaningful; the uploaded campaign records that gate explicitly.

## Voxtral context biasing

This was the experiment that motivated the original document. The Transcribe 2 serving surface
exposes context biasing as a first-class input rather than as prose in the prompt, so the intended
comparison is:

- **A.** Screen context passed as prompt text, exactly as DoNotType does today (`dnt-eval ablate`
  handles this).
- **B.** The same screen text passed through Voxtral's context-biasing parameter instead.

If B substitutes less than A at equal baseline accuracy, the answer is decoder-level biasing and
the project's whole approach should change. The cached `Voxtral-Small-24B-2507` checkpoint tested
here does **not** expose that parameter in either its Transformers processor or the Mistral
transcription request, so B was not run. Transcribe 2/Mistral is intentionally out of scope for the
current campaign; no API credential or Hub checkpoint was requested. The installed `mistralai` SDK
surface and the unavailable model are recorded only as historical provenance.

### Decimal-number ordering control (SEAME clip)

The downloaded Small checkpoint did permit a related real-speech control: on the public SEAME
decimal clip, the same hostile text was tested both **after** the audio block and in DoNotType's
production **text-before-audio** order. This is an ordering observation, not the decoder-level
biasing experiment above, and is recorded under `additional_decimal_number_smoke` in the result
JSON.

- **Voxtral Small:** audio-before-text retained the spoken `2.5` in 15/15 trials; the production
  order copied the hostile `3.5` in 15/15.
- **Qwen3-Omni (paired control):** retained `2.5` and omitted the decoy in all 15 hostile trials in
  both orders.
- **MiniCPM-o:** changed its baseline rendering under audio-first ordering but still omitted the
  hostile decoy.
- **Gemma 4:** the inverse — audio-first improved its baseline to exact `2.5`, then copied hostile
  `3.5` in all 15 trials, while text-first produced near variants without the decoy.
- **Ultravox:** matched the same ordering direction under explicit neutral delimiters — copied
  hostile `3.5` in all 15 production text-before-audio trials but retained `2.5` and omitted the
  decoy in all 15 audio-before-text controls.

The Voxtral flip is therefore not a generic property of every audio LLM, but it is also not unique
to Voxtral.

### Proper-noun ordering control (Barcelona clip)

A second order-neutral public-real control used the Barcelona weather clip (spoken `Barcelona`,
hostile `Madrid`). These are proper-noun controls, not scores for the uploaded DoNotType fixtures.

- **Voxtral:** retained the anchor and rejected the decoy in all 15 trials in both orders, while
  changing output language from Spanish text-first to German audio-first.
- **Ultravox:** retained the anchor and rejected the decoy in all 15 trials in both orders under
  explicit neutral delimiters.
- **Qwen3-Omni and MiniCPM-o:** also retained `Barcelona` and rejected `Madrid` in all 15 trials in
  both orders, providing order-insensitive controls under the same public-real setup.
- **Gemma:** also retained the anchor and rejected the decoy in all 15 trials in both orders when
  rerun from the 16 kHz WAV; its older direct-MP3 row is excluded because the no-context decode was
  unusable.

## Reporting results

Record, per model:

```
model:            mistralai/Voxtral-Small-24B-2507
quantisation:     bf16 | awq-4bit | q4_k_m
hardware:         2× A100 80GB
audio processed:  yes (N audio tokens) | no | not reported
baseline:         X/8 correct on the reference clip, no context
substitution:     N/M with hostile context  (dnt-eval ablate output)
mean latency:     Xs
transcript sample: "..."
```

The transcript sample matters as much as the rate: `gemini-3.5-flash` heard "unified **sauce**" and
`gpt-audio-mini` produced no punctuation at all. A model can score acceptably on the version number
and still be unusable.

Results belong in [MODELS.md](MODELS.md) under a new "Local / open-weight" section. Raw output
pasted into an issue is fine — the table can be written from it.

The uploaded-fixture handoff is now complete for every in-scope downloadable candidate/control. The
exact reference and suite records are in
[`eval/results/local-real-audio-2026-08-10.json`](../eval/results/local-real-audio-2026-08-10.json):
Voxtral Small, Qwen3-Omni, Gemma 4, Whisper large-v3, Ultravox, Qwen3-ASR, and MiniCPM-o 4.5 each
have a pinned revision, raw probe, ablation rows appropriate to their architecture, and per-case
counts. Voxtral Realtime has a three-trial uploaded audio-only probe and explicitly cannot accept
screen context or run the A/B.

## Pitfalls

**Audio format.** The app records 16 kHz mono WAV and the eval clips are the same. Some servers
want a specific sample rate; resample rather than assuming (`ffmpeg -ac 1 -ar 16000`).

**Real-speech fixtures are supplied under `eval/audio/`.** The uploaded `real-talk-gemini15.wav`
and companion recordings are verified 16 kHz mono PCM and their SHA-256 hashes are recorded in
`eval/audio/README.md` and the result JSON. The short `say`-generated clips remain transport/scorer
smoke tests only. The real cases use `mustContain`/`mustNotContain` fragment assertions, so wording
variation does not mask a version-number or language regression. The Python fallback recognizes the
known synthetic stand-in by SHA-256 and blocks it by default; pass `--allow-synthetic` only for an
explicitly labelled transport smoke test. The completed direct-checkpoint campaign is summarized in
[`docs/MODELS.md`](MODELS.md#uploaded-exact-fixture-campaign-real-wavs-downloaded-checkpoints).

**Swift is optional on a GPU host.** The production harness is Swift, but a machine used only for
model serving may not have a Swift toolchain. In that case, use
[`eval/local-gpu-benchmark.py`](../eval/local-gpu-benchmark.py), which sends the same OpenAI-
compatible request shape and reports the same probe/ablation/suite measurements. Swift build and
test results should be recorded as unavailable rather than inferred from the Python fallback.

**`response_format`.** The client sends a JSON schema and retries once without it on a 400. Local
servers vary in support — the retry handles it, but the first request per model is wasted, and the
fallback is remembered per model, not persisted across runs.

**`reasoning`.** Not sent on `--provider local`; open models generally reject the unknown field.

**One clip is not a benchmark.** Everything here rests on one 22-second recording. Add more with
`./eval/extract-real-audio.sh <dir> 22`, and verify each by ear before trusting a failure against
it — one extracted clip turned out to be near-silent and produced a confident hallucination that
looked like a real finding for an hour.

**Two runs disagree.** Transcription is non-deterministic. `--trials 15` is the floor for a number
worth acting on; below about 10 the intervals are too wide to distinguish anything.

## See also

- [MODELS.md](MODELS.md) — hosted results and the completed uploaded-fixture campaign.
- [`eval/results/local-real-audio-2026-08-10.json`](../eval/results/local-real-audio-2026-08-10.json)
  — pinned revisions, raw probes, and per-case counts for the completed local campaign.
