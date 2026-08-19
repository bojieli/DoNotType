#!/usr/bin/env bash
# Speech recognition backends against a model provider, on the same suite and the same clips.
#
# Deepgram and xAI are not language models, so the questions that matter differ from
# benchmark-models.sh. A recogniser cannot substitute a version number it read on screen, because
# it never saw the screen — so the interesting comparison is not "does grounding corrupt this"
# but "what does giving up grounding cost, and what does it buy".
#
# Four configurations, because two independent choices turned out to matter more than the choice
# of backend:
#
#   1. language: detection versus nova-3's `multi`. Detection misclassifies and returns HTTP 200
#      with an empty transcript, which is the worst way to fail.
#   2. keyterm biasing: off by default, since it is the vocabulary prior this project argues
#      against. Measured here rather than assumed either way.
#
# Results are recorded in docs/EVALUATION.md and eval/results/.
set -u
cd "$(dirname "$0")/.." || exit

REPEAT="${REPEAT:-3}"
CASES="${CASES:-eval/nearmiss}"
BASELINE_PROVIDER="${BASELINE_PROVIDER:-openrouter}"

: "${DEEPGRAM_API_KEY:?set DEEPGRAM_API_KEY}"

swift build -c release >/dev/null 2>&1 || { echo "build failed"; exit 1; }

run() {
  local label="$1"; shift
  echo "───────────────────────────────────────────────"
  echo "## $label"
  swift run -c release dnt-eval suite "$CASES" --repeat-count "$REPEAT" "$@" 2>&1 \
    | grep -E "^(runs|improved|neutral-|REGRESSED|ERROR)"
}

echo "near-miss suite · $REPEAT passes per case"
echo

# `detect_language` is deliberately not reachable here any more: nova-3 now defaults to `multi`
# because detection scored 12/42 against 18/42 and failed by returning empty transcripts. The
# superseded numbers are kept in docs/EVALUATION.md rather than re-measured on every run.
run "deepgram · multi · no keyterms" --provider deepgram
run "deepgram · multi · keyterms" --provider deepgram --keyterms

if [ -n "${MISTRAL_API_KEY:-}" ]; then
  # The only recognition backend that transcribes Mandarin and English without being told which
  # is coming, so it is the one that completes all 16 cases rather than erroring on two.
  run "mistral · voxtral-mini · no biasing channel" --provider mistral
fi

if [ -n "${OPENROUTER_API_KEY:-}${GEMINI_API_KEY:-}" ]; then
  run "$BASELINE_PROVIDER · model provider baseline" --provider "$BASELINE_PROVIDER"
fi

echo
echo "───────────────────────────────────────────────"
echo "## latency, reference clip, 15 trials"
for args in "--provider deepgram" "--provider deepgram --keyterms" "--provider mistral" "--provider $BASELINE_PROVIDER"; do
  # shellcheck disable=SC2086
  swift run -c release dnt-eval ablate $args --conditions verbatim --trials 15 2>&1 \
    | grep -E "^verbatim +[0-9]" | sed "s|^|$(printf '%-34s' "$args")|"
done

echo
echo "Deepgram cannot transcribe Mandarin under any autodetecting setting; set"
echo "DNT_DEEPGRAM_LANGUAGE=zh for Chinese speech. Those cases error rather than"
echo "returning wrong text, so they are excluded from the matched counts above."
