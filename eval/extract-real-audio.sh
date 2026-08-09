#!/usr/bin/env bash
# Extracts real speech clips for the eval corpus.
#
# Why this exists: the synthesized suite measures almost nothing. `say` enunciates far more
# clearly than a person, and the model already knows well-known terms — a control saying
# "cuber netties" came back as "Kubernetes" with no context at all. Substitution bites when the
# audio is genuinely ambiguous, which only real speech produces.
#
# Usage:  ./extract-real-audio.sh [source-dir] [clip-seconds]
# Output: eval/audio/real-<name>-<offset>.wav, 16 kHz mono, matching what the apps record.
set -euo pipefail

SOURCE="${1:-$HOME/Movies}"
CLIP="${2:-25}"
OUT="$(cd "$(dirname "$0")" && pwd)/audio"
mkdir -p "$OUT"

command -v ffmpeg >/dev/null || { echo "ffmpeg is required"; exit 1; }

extract() {
    local file="$1" offset="$2" label="$3"
    local target="$OUT/real-${label}-${offset}s.wav"
    # -ac 1 -ar 16000 matches the capture format on every platform, so the eval measures the same
    # audio the apps actually send rather than a higher-fidelity stand-in.
    ffmpeg -nostdin -v error -y -ss "$offset" -t "$CLIP" -i "$file" \
        -ac 1 -ar 16000 -c:a pcm_s16le "$target"
    printf '  %-44s %s\n' "$(basename "$target")" "$(du -h "$target" | cut -f1)"
}

echo "Extracting ${CLIP}s clips from $SOURCE"
count=0
while IFS= read -r file; do
    duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null || echo 0)
    duration=${duration%%.*}
    [ "${duration:-0}" -lt 120 ] && continue

    label=$(basename "$file" | sed 's/\.[^.]*$//' | tr -c 'a-zA-Z0-9' '-' | tr -s '-' | sed 's/^-//;s/-$//' | cut -c1-24)

    # Three points through each recording, avoiding the intro and the outro where speech is
    # thinnest.
    for fraction in 25 50 75; do
        extract "$file" "$(( duration * fraction / 100 ))" "$label"
        count=$((count + 1))
    done
done < <(find "$SOURCE" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.mp3' \) | sort | head -"${MAX_FILES:-4}")

echo "Extracted $count clips into $OUT"
echo
echo "These have no ground truth yet. Transcribe each one, check it by ear, and write the"
echo "verified text into a case file under eval/nearmiss/ before treating any number as real."
