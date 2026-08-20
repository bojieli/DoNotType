#!/usr/bin/env bash
#
# Verifies that the checked-in platform defaults agree with VERSION.
#
# The platform files intentionally contain generated defaults so a local build works without a
# checkout-time mutation. VERSION is the only source to edit; stamp-version.sh refreshes these
# fields for a release build, and this check prevents a forgotten generated field from shipping.

set -euo pipefail

version_file="${VERSION_FILE:-VERSION}"
[[ -f "$version_file" ]] || { echo "✗ missing $version_file" >&2; exit 1; }
version=$(tr -d '[:space:]' < "$version_file")
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo "✗ $version_file does not contain a canonical x.y.z version" >&2
  exit 1
}

build=$(python3 - "$version" <<'PY'
import sys
major, minor, patch = map(int, sys.argv[1].split("."))
if minor > 99 or patch > 99:
    raise SystemExit("✗ minor and patch versions must each be between 0 and 99")
print(major * 10_000 + minor * 100 + patch)
PY
)

python3 - "$version" "$build" <<'PY'
import plistlib
import re
import sys
from pathlib import Path

version, build = sys.argv[1:]

def fail(path: str, message: str) -> None:
    raise SystemExit(f"✗ {path}: {message}")

with Path("Resources/Info.plist").open("rb") as handle:
    plist = plistlib.load(handle)
if plist.get("CFBundleShortVersionString") != version:
    fail("Resources/Info.plist", "CFBundleShortVersionString is not VERSION")
if str(plist.get("CFBundleVersion")) != build:
    fail("Resources/Info.plist", "CFBundleVersion is not derived from VERSION")

checks = [
    ("android/app/build.gradle.kts", rf'versionCode = {re.escape(build)}'),
    ("android/app/build.gradle.kts", rf'versionName = "{re.escape(version)}"'),
    ("ios/project.yml", rf'MARKETING_VERSION: "{re.escape(version)}"'),
    ("ios/project.yml", rf'CURRENT_PROJECT_VERSION: "{re.escape(build)}"'),
    ("windows/Directory.Build.props", rf'<Version>{re.escape(version)}</Version>'),
    ("windows/DoNotType.App/app.manifest", rf'version="{re.escape(version)}\.0"'),
    ("Sources/dnt/Dnt.swift", rf'version: "dnt {re.escape(version)}"'),
    ("windows/DoNotType.Cli/Program.cs", rf'Out\.Line\("dnt {re.escape(version)}"\)'),
    ("windows/DoNotType.Cli/InspectionCommands.cs", rf'Out\.Line\("DoNotType — dnt {re.escape(version)}"\)'),
]
for filename, pattern in checks:
    text = Path(filename).read_text()
    if not re.search(pattern, text):
        fail(filename, f"does not contain generated version {version}")
PY

echo "✓ generated platform defaults match VERSION $version ($build)"
