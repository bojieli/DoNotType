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

# ---- Cases where grounding is supposed to HELP ---------------------------------------------
#
# Everything above measures whether context can *corrupt* a transcript. Nothing measured whether
# it earns its place, and the answer turned out to matter: probing the real clips with no context
# at all, gemini-3.6-flash already spells VAD, ASR, Scrum, gradient and "retrieval pipeline"
# correctly. Those terms are in its training data, so the screen has nothing to add and the suite
# scored `improved 0` -- not because grounding failed, but because it was never asked anything it
# could answer.
#
# Grounding can only help with a token the model cannot know: a colleague's unusual name, an
# internal codename, a private repo. These are invented for exactly that reason -- each is
# pronounceable, has an obvious wrong spelling a phonetic transcriber would reach for, and appears
# nowhere in any public corpus.
#
# Synthesized deliberately. The warning above -- that `say` measures the easy case -- is about
# substitution, where clean pronunciation removes the ambiguity the failure needs. It does not
# apply here: an unknown name is equally unknown however clearly it is spoken, so what is being
# measured survives synthesis intact.
# The shortest thing anybody dictates, and the case that constrains the speech gate. It used to be
# indistinguishable from the retained mouse-click failure by duration and burst count; Silero gives
# the click 0.131 probability and this word 1.000. If the gate drops this file, it drops "Yes" as an
# answer to a question.
synth short-word       "Yes."

synth novel-name       "Ask Kaelith to review the merge before standup."
synth novel-codename   "The Thessaly rollout is blocked on the Brindlewood cluster."
synth novel-repo       "Clone quillmark dash sync and run the setup script."
echo "Done."
