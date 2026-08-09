#!/usr/bin/env bash
# Regenerates the synthesized audio for the near-miss suite.
#
# These are SMOKE TESTS, not the real suite. `say` pronounces "three point five" far more
# cleanly than a person does, which exercises the easy case. Substitution bites when the audio
# is slightly ambiguous — so record the cases that matter with your own voice and drop the
# .wav next to these, keeping the same filename.
set -euo pipefail
cd "$(dirname "$0")/audio"

VOICE="${VOICE:-Samantha}"

synth() {
    local name="$1" text="$2"
    say -v "$VOICE" -o "/tmp/dnt-$name.aiff" "$text"
    afconvert -f WAVE -d LEI16@16000 -c 1 "/tmp/dnt-$name.aiff" "$name.wav"
    rm -f "/tmp/dnt-$name.aiff"
    printf '  %-28s %s\n' "$name.wav" "$text"
}

echo "Synthesizing with voice '$VOICE':"
synth gemini-version   "We should switch to Gemini three point five Flash for this."
synth port-number      "Run the dev server on port eighty eighty one."
synth person-name      "Can you send the draft to Priya before Friday?"
synth jargon-spelling  "We load the native library through koffee at startup."
synth git-command      "Let's just do git commit dash dash amend and move on."
echo "Done."
