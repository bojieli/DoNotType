#!/usr/bin/env bash
# Substitution rate across model versions, on the same clip and the same hostile context.
#
# Worth running whenever a model is bumped: multimodal behaviour regresses between releases, and
# the failure this measures is invisible without a controlled comparison.
set -u
cd "$(dirname "$0")/.."
: "${GEMINI_API_KEY:?set GEMINI_API_KEY}"

MODELS="${1:-gemini-3.6-flash gemini-3.5-flash gemini-3-flash-preview gemini-2.5-flash}"
TRIALS="${2:-15}"

echo "clip: real-talk-gemini15.wav (speaker says 1.5) · screen says 2.5 · $TRIALS trials each"
echo
printf '%-26s %8s %8s %6s   %s\n' MODEL SUBST CORRECT RATE NOTE
for model in $MODELS; do
  out=$(swift run dnt-eval ablate --model "$model" --trials "$TRIALS" \
        --conditions verbatim 2>&1 | grep "^verbatim:")
  if [ -z "$out" ]; then
    printf '%-26s %8s %8s %6s   %s\n' "$model" - - - "unavailable or errored"
    continue
  fi
  subst=$(echo "$out" | sed -E 's/.*substituted ([0-9]+)\/([0-9]+).*/\1/')
  judged=$(echo "$out" | sed -E 's/.*substituted ([0-9]+)\/([0-9]+).*/\2/')
  rate=$(echo "$out" | grep -o '([0-9]*%)' | tr -d '()')
  printf '%-26s %8s %8s %6s\n' "$model" "$subst" "$((judged - subst))" "$rate"
done
echo
echo "Lower is better. A model that substitutes is overwriting what the speaker said."
