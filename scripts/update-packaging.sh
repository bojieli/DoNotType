#!/usr/bin/env bash
#
# Fills the version and checksum into the Homebrew cask from a published release.
#
# Hand-copying a sha256 is the step that goes wrong, and it goes wrong invisibly: a cask with a
# stale hash fails at install time complaining about a corrupt download. That reads as something
# far more alarming than "somebody forgot to update a field". So nobody types a hash — this reads
# it from the `.sha256` file the release workflow publishes beside the macOS artifact.
#
#     ./scripts/update-packaging.sh 0.2.0
#
# Run it after the release is published, not before: it downloads from the release URL.

set -euo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>   # e.g. 0.2.0" >&2; exit 2; }
VERSION="${VERSION#v}"
if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "✗ '$VERSION' is not a canonical x.y.z version" >&2
  exit 2
fi

REPO="${REPO:-bojieli/DoNotType}"
BASE="https://github.com/$REPO/releases/download/v$VERSION"

# The published `.sha256` rather than a re-download of the artifact: it is the same number, it is
# what a user verifying by hand would check against, and it is a few bytes instead of tens of
# megabytes. If the two ever disagree, the packaging should carry what the release published.
fetch_sha() {
  local name="$1"
  local line
  local digest
  local recorded_name
  if ! line=$(curl -fsSL "$BASE/$name.sha256"); then
    echo "✗ no $name.sha256 at $BASE — is v$VERSION published?" >&2
    exit 1
  fi
  digest=$(printf '%s\n' "$line" | awk 'NF == 2 { print $1 }')
  recorded_name=$(printf '%s\n' "$line" | awk 'NF == 2 { print $2 }')
  if ! [[ "$digest" =~ ^[0-9A-Fa-f]{64}$ ]] || [[ "$recorded_name" != "$name" ]]; then
    echo "✗ malformed checksum for $name (recorded name: '$recorded_name')" >&2
    exit 1
  fi
  printf '%s\n' "$digest"
}

echo "reading checksums for v$VERSION"
MAC_SHA=$(fetch_sha "DoNotType-macOS.zip")
printf '  %-28s %s\n' "DoNotType-macOS.zip" "$MAC_SHA"

python3 - "$VERSION" "$MAC_SHA" <<'PY'
import re, sys

version, mac_sha = sys.argv[1], sys.argv[2]

# Homebrew: version and sha256 are their own lines, so this is unambiguous.
path = "packaging/homebrew/donottype.rb"
text = open(path).read()
text, version_matches = re.subn(
    r'version "[^"]*"', f'version "{version}"', text, count=1)
text, sha_matches = re.subn(r'sha256 "[^"]*"', f'sha256 "{mac_sha}"', text, count=1)
if version_matches != 1 or sha_matches != 1:
    raise SystemExit(f"expected one version and checksum in {path}, found "
                     f"{version_matches} and {sha_matches}")
open(path, "w").write(text)
PY

echo "✓ packaging updated to $VERSION"
echo
echo "Next (manual because it is a submission to another repository):"
echo "  Homebrew  copy packaging/homebrew/donottype.rb into your tap's Casks/ and push"
