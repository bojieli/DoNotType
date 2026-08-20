#!/usr/bin/env bash
#
# Writes one version number into every place a platform keeps one.
#
# Four platforms means four version fields, and a release that stamps some of them produces an
# Android build reporting 0.1.0 next to a macOS build reporting 0.4.0 — which turns every bug report
# into a question about which build it came from. VERSION is the committed local/default source;
# a release workflow may pass its tag-derived value explicitly. This puts the chosen value
# everywhere before anything is built or signed.
#
# Run from the repository root:
#     ./scripts/stamp-version.sh       # use VERSION
#     ./scripts/stamp-version.sh 0.2.0 # explicit release/tag value
#
# It is idempotent and safe to run on a dirty tree; CI runs it on a fresh checkout and never commits
# the result, so the committed files keep whatever the last release set.

set -euo pipefail

VERSION_FILE="${VERSION_FILE:-VERSION}"
if [[ "$#" -gt 1 ]]; then
  echo "usage: $0 [version]   # e.g. 0.2.0" >&2
  exit 2
fi
if [[ "$#" -eq 1 ]]; then
  VERSION="$1"
else
  [[ -f "$VERSION_FILE" ]] || {
    echo "✗ no version supplied and $VERSION_FILE is missing" >&2
    echo "  Add a canonical x.y.z version to $VERSION_FILE or pass one explicitly." >&2
    exit 2
  }
  VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
  [[ -n "$VERSION" ]] || {
    echo "✗ $VERSION_FILE is empty" >&2
    exit 2
  }
fi

# Rejects a tag like `v1.2`, `1.2.3-beta`, or `01.2.3` early rather than after three builds:
# CFBundleVersion and Android's versionName both want a dotted numeric string, and a malformed one
# fails late. Leading zeroes are rejected so every version has one canonical spelling.
#
# The message names the grammar and the reason, because this runs once per platform in the release
# workflow: a rejected `--version` input fails four jobs on three operating systems within a minute
# of each other, and "all platforms red, publish skipped" reads exactly like absent signing
# secrets. Saying what is accepted here is what stops that from being diagnosed as an outage.
if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "✗ '$VERSION' is not a version this project can stamp." >&2
  echo "  Expected three dot-separated numbers and nothing else: 0.2.0, 1.0.0, 12.4.31." >&2
  case "$VERSION" in
    v*)
      echo "  Drop the leading 'v': the tag is v${VERSION#v}, the version is ${VERSION#v}." >&2
      ;;
    *-*|*+*)
      echo "  A pre-release or build suffix cannot be carried. Apple's CFBundleVersion and" >&2
      echo "  Android's versionCode are integers computed from these three numbers, and there" >&2
      echo "  is nowhere in either to put '${VERSION#*[-+]}'. Ship a normal version and mark" >&2
      echo "  the GitHub release itself as a pre-release, which is a publishing choice rather" >&2
      echo "  than part of the number every client reports." >&2
      ;;
    *.*.*.*)
      echo "  Four components is one too many; the build number is derived, not supplied." >&2
      ;;
    0*|*.0[0-9]*)
      echo "  Leading zeroes are rejected so each version has exactly one spelling." >&2
      ;;
  esac
  exit 2
fi

say() { printf '  %-46s %s\n' "$1" "$2"; }

echo "stamping $VERSION"

# ---- macOS: the app bundle's plist ------------------------------------------------------------
# CFBundleVersion is the build number and must increase for an update to be recognised; deriving it
# from the version keeps it monotonic without a separate counter to forget. Two decimal places are
# reserved for minor and patch, so reject components that would collide (1.2.100 and 1.3.0 used to
# produce the same build number). Android caps versionCode at 2,100,000,000.
BUILD=$(python3 - "$VERSION" <<'PY'
import sys

major, minor, patch = map(int, sys.argv[1].split("."))
if minor > 99 or patch > 99:
    raise SystemExit("✗ minor and patch versions must each be between 0 and 99")
build = major * 10_000 + minor * 100 + patch
if build > 2_100_000_000:
    raise SystemExit("✗ version exceeds Android's maximum versionCode")
print(build)
PY
)

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
text, marketing_matches = re.subn(
    r'MARKETING_VERSION: "[^"]*"', f'MARKETING_VERSION: "{version}"', text)
text, build_matches = re.subn(
    r'CURRENT_PROJECT_VERSION: "[^"]*"', f'CURRENT_PROJECT_VERSION: "{build}"', text)
if marketing_matches != 1 or build_matches != 1:
    raise SystemExit(f"✗ expected one version pair in {path}, found "
                     f"{marketing_matches} marketing and {build_matches} build fields")
open(path, "w").write(text)
PY
say "ios/project.yml" "$VERSION ($BUILD)"

# ---- Android: versionName, and a versionCode that only ever goes up -----------------------------
python3 - "$VERSION" "$BUILD" <<'PY'
import re, sys
version, build = sys.argv[1], sys.argv[2]
path = "android/app/build.gradle.kts"
text = open(path).read()
text, name_matches = re.subn(r'versionName = "[^"]*"', f'versionName = "{version}"', text)
text, code_matches = re.subn(r'versionCode = \d+', f'versionCode = {build}', text)
if name_matches != 1 or code_matches != 1:
    raise SystemExit(f"✗ expected one version pair in {path}, found "
                     f"{name_matches} name and {code_matches} code fields")
open(path, "w").write(text)
PY
say "android/app/build.gradle.kts" "$VERSION ($BUILD)"

# ---- Windows: a version for dev builds ----------------------------------------------------------
# Release passes -p:Version to dotnet publish; this committed value is what a plain `dotnet build`
# reports, so the About tab is never blank outside CI.
python3 - "$VERSION" <<'PY'
import re, sys
version = sys.argv[1]
path = "windows/Directory.Build.props"
text = open(path).read()
updated, matches = re.subn(r"<Version>[^<]*</Version>", f"<Version>{version}</Version>", text)
if matches != 1:
    raise SystemExit(f"✗ expected one version in {path}, found {matches}")
open(path, "w").write(updated)
PY
say "windows/Directory.Build.props" "$VERSION"

# ---- The two CLIs report it too ----------------------------------------------------------------
# `dnt --version` is the first thing anyone pastes into a bug report, and a hardcoded string there
# is a version number that is wrong by definition after the first release. The commit and build
# date ride along so a pasted version line identifies the exact build.
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date -u +%Y-%m-%d)
python3 - "$VERSION" "$COMMIT" "$BUILD_DATE" <<'PY'
import re, sys
version, commit, build_date = sys.argv[1], sys.argv[2], sys.argv[3]
suffix = f" ({commit}, {build_date})"
# Every literal is spelled `dnt <version>` because `dnt --version` prints the same line on macOS
# and Windows, so one pattern stamps them all and a platform cannot be given its own spelling by
# accident. The optional suffix group keeps re-stamping idempotent: a previously stamped
# " (abc1234, …)" is replaced rather than accumulating.
pattern = r'dnt \d+\.\d+\.\d+( \([0-9a-z]+, \d{4}-\d{2}-\d{2}\))?'
replacement = f"dnt {version}{suffix}"
for path in [
    "Sources/dnt/Dnt.swift",
    "windows/DoNotType.Cli/Program.cs",
    "windows/DoNotType.Cli/InspectionCommands.cs",
]:
    text = open(path).read()
    # Counts matches rather than comparing before and after: stamping the version that is already
    # there is a no-op, not a failure, and treating it as one made the release fail on the first
    # tag cut at the committed version.
    updated, matches = re.subn(pattern, replacement, text)
    if matches != 1:
        raise SystemExit(f"✗ expected one version in {path}, found {matches}")
    open(path, "w").write(updated)
PY
say "Sources/dnt/Dnt.swift" "$VERSION"
say "windows/DoNotType.Cli" "$VERSION"

echo "✓ every platform now reports $VERSION"
