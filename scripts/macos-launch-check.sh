#!/usr/bin/env bash
#
# Launches the real macOS app and checks it is still alive and did something.
#
# Every other platform has a test that runs the shipped app: iOS in a simulator, Android in an
# emulator, Windows on a runner. macOS — the platform this is primarily developed on — had none, so
# it was the only one where "it builds" was the whole story. That is exactly the gap that let the
# Windows app compile for months while having never been started, and the iOS bundle ship without a
# CFBundleIdentifier.
#
# A menu-bar agent cannot be driven by XCUITest the way a windowed app can: LSUIElement means no
# Dock tile, and the status item lives in a system-owned menu bar that a UI test cannot reach
# without Accessibility permission that CI will never grant. So this asserts the things that can be
# checked from outside the process, which are also the ones that have actually broken:
#
#   1. The bundle is well formed — identifier, executable, and the contract file inside it.
#   2. It starts and stays up. Catches a crash in AppDelegate, a missing resource, a plist key.
#   3. It got far enough to write a log line. That single line proves settings loaded, logging
#      started and the first request-shaped work happened, which is most of startup.
#
# It deliberately does not require Accessibility or a microphone. Without them the app opens its
# setup window instead of installing the hotkey, and staying alive in that state is still the thing
# being checked.

set -euo pipefail

APP="${1:-.build/DoNotType.app}"
SECONDS_TO_WATCH="${SECONDS_TO_WATCH:-20}"
SUPPORT="$HOME/Library/Application Support/DoNotType"
LOG="$SUPPORT/logs/donottype.log"
SHOTS="${SHOTS:-shots}"

fail() {
  echo "✗ $1" >&2
  exit 1
}

cleanup() {
  # Always, even on failure: leaving a menu-bar app running on a developer machine after a test is
  # rude, and on a runner it holds the session open.
  pkill -x DoNotType 2>/dev/null || true
}
trap cleanup EXIT

[ -d "$APP" ] || fail "no app bundle at $APP — run 'make app' first"

echo "── bundle"
PLIST="$APP/Contents/Info.plist"
for key in CFBundleIdentifier CFBundleExecutable; do
  value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null || true)
  [ -n "$value" ] || fail "$key is missing from Info.plist — the bundle cannot be installed"
  echo "  $key = $value"
done

EXECUTABLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST")
[ -x "$APP/Contents/MacOS/$EXECUTABLE" ] || fail "CFBundleExecutable names a file that is not there"

# The contract ships inside the bundle so the app does not depend on the source tree. If this is
# missing the app starts and then cannot transcribe anything, which is a worse failure than not
# starting at all.
[ -f "$APP/Contents/Resources/PROMPT.md" ] || fail "PROMPT.md is not in the bundle"
grep -q "BEGIN SYSTEM" "$APP/Contents/Resources/PROMPT.md" || fail "the bundled PROMPT.md is not the contract"

# The CLI rides along in the bundle, and an installed copy resolves PROMPT.md relative to itself.
if [ -x "$APP/Contents/MacOS/dnt" ]; then
  "$APP/Contents/MacOS/dnt" prompt validate >/dev/null || fail "the bundled CLI cannot read the bundled prompt"
  echo "  bundled CLI validates the bundled prompt"
fi

echo "── launch"
# Note the log's size beforehand rather than deleting it: this may be a developer's machine, and
# their history and log are not ours to clear.
BEFORE=0
[ -f "$LOG" ] && BEFORE=$(wc -c <"$LOG" | tr -d ' ')

pkill -x DoNotType 2>/dev/null || true
sleep 1
open "$APP"

for _ in $(seq 1 "$SECONDS_TO_WATCH"); do
  sleep 1
  pgrep -x DoNotType >/dev/null || fail "the app exited within $SECONDS_TO_WATCH seconds of starting"
done
echo "  still running after ${SECONDS_TO_WATCH}s"

mkdir -p "$SHOTS"
# Best effort: a runner without screen-recording permission gets an empty or black image, which is
# not worth failing over. The point is the artifact when something did go wrong.
screencapture -x "$SHOTS/desktop.png" 2>/dev/null || true

echo "── evidence"
[ -f "$LOG" ] || fail "no log file at $LOG — logging never started, so neither did much else"
AFTER=$(wc -c <"$LOG" | tr -d ' ')
[ "$AFTER" -gt "$BEFORE" ] || fail "the log did not grow — the app started but got nowhere"

# The startup line carries the level, the backend and the model, so its presence also means
# settings were read and the provider was resolved.
tail -c "$((AFTER - BEFORE))" "$LOG" | grep -q "app .*started" \
  || fail "the app did not log its own startup"
echo "  logged:"
tail -c "$((AFTER - BEFORE))" "$LOG" | sed 's/^/    /' | head -5

echo "✓ the macOS app starts, stays up, and reports what it is configured with"
