#!/usr/bin/env bash
#
# Writes one version number into every place a platform keeps one.
#
# Four platforms means four version fields, and a release that stamps some of them produces an
# Android build reporting 0.1.0 next to a macOS build reporting 0.4.0 — which turns every bug report
# into a question about which build it came from. The tag is the single source; this puts it
# everywhere before anything is built or signed.
#
# Run from the repository root:
#     ./scripts/stamp-version.sh 0.2.0
#
# It is idempotent and safe to run on a dirty tree; CI runs it on a fresh checkout and never commits
# the result, so the committed files keep whatever the last release set.

set -euo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>   # e.g. 0.2.0" >&2; exit 2; }

# Rejects a tag like `v1.2` or `1.2.3-beta` early rather than after three builds: CFBundleVersion
# and Android's versionName both want a dotted numeric string, and a malformed one fails late.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "✗ '$VERSION' is not x.y.z" >&2
  exit 2
fi

say() { printf '  %-46s %s\n' "$1" "$2"; }

echo "stamping $VERSION"

# ---- macOS: the app bundle's plist ------------------------------------------------------------
# CFBundleVersion is the build number and must increase for an update to be recognised; deriving it
# from the version keeps it monotonic without a separate counter to forget.
BUILD=$(echo "$VERSION" | awk -F. '{ printf "%d", $1 * 10000 + $2 * 100 + $3 }')

# Through Python rather than PlistBuddy, which exists only on macOS. Each release job stamps its
# own checkout because they run on different runners, so the Linux and Windows ones need this too.
python3 - "$VERSION" "$BUILD" <<'PLIST'
import plistlib, sys
version, build = sys.argv[1], sys.argv[2]
with open("Resources/Info.plist", "rb") as handle:
    plist = plistlib.load(handle)
plist["CFBundleShortVersionString"] = version
plist["CFBundleVersion"] = build
with open("Resources/Info.plist", "wb") as handle:
    plistlib.dump(plist, handle)
PLIST
say "Resources/Info.plist" "$VERSION ($BUILD)"

# ---- iOS: the generated project ----------------------------------------------------------------
python3 - "$VERSION" "$BUILD" <<'PY'
import re, sys
version, build = sys.argv[1], sys.argv[2]
path = "ios/project.yml"
text = open(path).read()
text = re.sub(r'MARKETING_VERSION: "[^"]*"', f'MARKETING_VERSION: "{version}"', text)
text = re.sub(r'CURRENT_PROJECT_VERSION: "[^"]*"', f'CURRENT_PROJECT_VERSION: "{build}"', text)
open(path, "w").write(text)
PY
say "ios/project.yml" "$VERSION ($BUILD)"

# ---- Android: versionName, and a versionCode that only ever goes up -----------------------------
python3 - "$VERSION" "$BUILD" <<'PY'
import re, sys
version, build = sys.argv[1], sys.argv[2]
path = "android/app/build.gradle.kts"
text = open(path).read()
text = re.sub(r'versionName = "[^"]*"', f'versionName = "{version}"', text)
text = re.sub(r'versionCode = \d+', f'versionCode = {build}', text)
open(path, "w").write(text)
PY
say "android/app/build.gradle.kts" "$VERSION ($BUILD)"

# ---- The two CLIs report it too ----------------------------------------------------------------
# `dnt --version` is the first thing anyone pastes into a bug report, and a hardcoded string there
# is a version number that is wrong by definition after the first release.
python3 - "$VERSION" <<'PY'
import re, sys
version = sys.argv[1]
for path, pattern, replacement in [
    ("Sources/dnt/Dnt.swift", r'version: "[^"]*"', f'version: "{version}"'),
    ("windows/DoNotType.Cli/Program.cs", r'dnt \d+\.\d+\.\d+', f"dnt {version}"),
    ("windows/DoNotType.Cli/InspectionCommands.cs", r'dnt \d+\.\d+\.\d+', f"dnt {version}"),
]:
    text = open(path).read()
    # Counts matches rather than comparing before and after: stamping the version that is already
    # there is a no-op, not a failure, and treating it as one made the release fail on the first
    # tag cut at the committed version.
    updated, matches = re.subn(pattern, replacement, text)
    if matches == 0:
        raise SystemExit(f"✗ nothing to stamp in {path} — the pattern moved")
    open(path, "w").write(updated)
PY
say "Sources/dnt/Dnt.swift" "$VERSION"
say "windows/DoNotType.Cli" "$VERSION"

echo "✓ every platform now reports $VERSION"
