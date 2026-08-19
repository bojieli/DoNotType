#!/usr/bin/env bash
# Cross-vendor benchmark for audio-capable models.
#
# Answers three questions per model, in order, because each only matters if the previous one
# passed:
#
#   1. Does it actually process the audio? A provider that accepts an audio block and discards it
#      returns a fluent, confident, invented transcript — the single worst failure mode here.
#   2. Can it transcribe the reference clip correctly with NO context? A model that mis-hears the
#      number cannot be scored for substitution at all.
#   3. With hostile screen context, how often does it write the on-screen value instead of the
#      spoken one?
#
# Results are committed to docs/MODELS.md. Re-run on any model bump: multimodal quality moves
# between releases and nothing else here would notice.
set -u
cd "$(dirname "$0")/.." || exit

PROVIDER="${PROVIDER:-openrouter}"
TRIALS="${TRIALS:-8}"
CLIP="eval/audio/real-talk-gemini15.wav"
SPOKEN="1.5"
DECOY="2.5"
CONTEXT="Gemini 2.5 Flash is the current model. See the Gemini 2.5 guide. Gemini 2.5 Flash pricing is lower. Upgrade to Gemini 2.5 today. Gemini 2.5 Flash benchmarks beat every prior release."

# Defaults span vendors rather than one family: the point is to find out whether anything else is
# competitive, not to rank Gemini against itself.
MODELS="${*:-}"
if [ -z "$MODELS" ]; then
  MODELS="google/gemini-3.6-flash
google/gemini-3.5-flash
google/gemini-3-flash-preview
google/gemini-3.1-flash-lite
google/gemini-2.5-flash
google/gemini-2.5-pro
openai/gpt-audio
openai/gpt-audio-mini
mistralai/voxtral-small-24b-2507
nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free
meta/muse-spark-1.2"
fi

[ -f "$CLIP" ] || { echo "missing $CLIP — run eval/extract-real-audio.sh first"; exit 1; }
swift build -c release >/dev/null 2>&1 || { echo "build failed"; exit 1; }

printf '%-52s %-9s %-9s %-8s %s\n' MODEL AUDIO BASELINE SUBST NOTE
printf '%.0s─' {1..100}; echo

while IFS= read -r model; do
  [ -z "$model" ] && continue

  # ---- 1. capability: is the audio processed at all? ----
  probe=$(swift run -c release dnt-eval probe --provider "$PROVIDER" --model "$model" \
          --audio "$CLIP" 2>&1)
  if echo "$probe" | grep -qi "error\|Error"; then
    note=$(echo "$probe" | grep -io "http [0-9]*\|not found\|unsupported\|no endpoints" | head -1)
    printf '%-52s %-9s %-9s %-8s %s\n' "$model" "—" "—" "—" "${note:-unavailable}"
    continue
  fi
  output=$(echo "$probe" | sed -n 's/^output *//p')
  tokens=$(echo "$probe" | sed -n 's/^audioTok *//p')

  if [ -z "$output" ]; then
    printf '%-52s %-9s %-9s %-8s %s\n' "$model" "no output" "—" "—" "returned nothing"
    continue
  fi
  if [ "$tokens" = "0" ]; then
    printf '%-52s %-9s %-9s %-8s %s\n' "$model" "DROPPED" "—" "—" "billed 0 audio tokens — transcript invented"
    continue
  fi

  # ---- 2. baseline: correct with no context? ----
  base_ok=0
  for _ in $(seq 1 3); do
    out=$(swift run -c release dnt-eval probe --provider "$PROVIDER" --model "$model" \
          --audio "$CLIP" 2>/dev/null | sed -n 's/^output *//p')
    echo "$out" | grep -q "$SPOKEN" && base_ok=$((base_ok + 1))
  done

  if [ "$base_ok" -eq 0 ]; then
    printf '%-52s %-9s %-9s %-8s %s\n' "$model" "ok" "0/3" "n/a" "mis-hears the number; cannot be scored"
    continue
  fi

  # ---- 3. substitution under hostile context ----
  subst=0; judged=0
  for _ in $(seq 1 "$TRIALS"); do
    out=$(swift run -c release dnt-eval once --provider "$PROVIDER" --model "$model" \
          --audio "$CLIP" --app Safari --window-title "Docs" --visible-text "$CONTEXT" 2>/dev/null \
          | sed -n 's/^context ON *//p')
    if echo "$out" | grep -q "$DECOY"; then subst=$((subst + 1)); judged=$((judged + 1))
    elif echo "$out" | grep -q "$SPOKEN"; then judged=$((judged + 1)); fi
  done

  rate="n/a"
  [ "$judged" -gt 0 ] && rate="$((subst * 100 / judged))%"
  printf '%-52s %-9s %-9s %-8s %s\n' "$model" "ok" "$base_ok/3" "$rate" "$subst/$judged judged"
done <<< "$MODELS"

echo
echo "AUDIO    — whether the recording reached the model at all"
echo "BASELINE — correct transcriptions of the spoken value with NO context (3 runs)"
echo "SUBST    — how often hostile screen context overwrote the spoken value (lower is better)"
