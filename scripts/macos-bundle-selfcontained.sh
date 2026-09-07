#!/usr/bin/env bash
#
# Checks that the built .app carries its own resources, rather than reaching back into the build
# directory that produced it.
#
# This exists because the opposite shipped, in every release this project has cut. SwiftPM's
# generated `Bundle.module` looks beside `Bundle.main.bundleURL` — the `.app` itself — and then
# falls back to an absolute path inside the build tree. `make app` puts the resource bundle under
# `Contents/Resources`, where a signed bundle must keep it, so the first location never matched and
# the fallback always did. On the machine that built it, that fallback exists. On a machine that
# downloaded it, it is somebody else's `/Users/runner/work/...` and the process dies on a
# `fatalError` the first time it needs the Silero model, which is every recording.
#
# Nothing in CI could see it: the build machine is also the test machine. So the check has to
# actively take the build directory away and then ask the bundle a question it can only answer from
# its own contents. `dnt doctor` reports the model, needs no API key and no network, which is what
# makes this runnable on every push.
set -euo pipefail

APP="${1:-.build/DoNotType.app}"
# Absolute, because the check runs the binary from `/` to make sure nothing resolves by relative
# luck — and a relative APP would stop resolving the moment we left the checkout.
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
DNT="$APP/Contents/MacOS/dnt"

[[ -x "$DNT" ]] || {
  echo "✗ no dnt inside $APP — the CLI is supposed to ship in the bundle" >&2
  exit 1
}

# Every sibling resource bundle SwiftPM produced, whatever the configuration or arch triple.
# A while-read loop rather than `mapfile`, which is a bash 4 builtin: macOS ships bash 3.2, so
# `mapfile` works on a developer machine with Homebrew bash on PATH and fails on the CI runner.
bundles=()
while IFS= read -r line; do
  [[ -n "$line" ]] && bundles+=("$line")
done < <(find .build -maxdepth 3 -name "DoNotType_*.bundle" -type d 2>/dev/null || true)

moved=()
restore() {
  for pair in "${moved[@]}"; do
    mv "${pair#*|}" "${pair%|*}"
  done
}
trap restore EXIT

for bundle in "${bundles[@]}"; do
  hidden="$bundle.hidden-by-selfcontained-check"
  mv "$bundle" "$hidden"
  moved+=("$bundle|$hidden")
done

echo "hid ${#moved[@]} build-directory resource bundle(s); asking the app about itself"

# Run from a directory that is not the checkout, so nothing resolves by relative luck either.
output=$(cd / && "$DNT" doctor 2>&1) || {
  echo "$output" >&2
  echo "✗ dnt doctor failed inside the bundle with the build directory hidden" >&2
  exit 1
}

printf '%s\n' "$output" | grep -E "silero VAD|opus encoder" || true

if printf '%s\n' "$output" | grep -q "silero VAD *available"; then
  echo "✓ the bundle carries its own resources"
else
  echo "$output" >&2
  echo >&2
  echo "✗ the app cannot find its Silero model without the build directory." >&2
  echo "  That means a downloaded copy dies on the first recording. The resource bundle has to" >&2
  echo "  be somewhere the binary looks from inside the .app — see CoreResources.swift." >&2
  exit 1
fi
