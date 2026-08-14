#!/usr/bin/env bash
#
# Fills the version and checksums into the Homebrew cask and the winget manifests, from a published
# release.
#
# Hand-copying a sha256 is the step that goes wrong, and it goes wrong invisibly: a cask with a
# stale hash fails at install time complaining about a corrupt download, and a winget manifest with
# one complains about a tampered package. Both read as something far more alarming than "somebody
# forgot to update a field". So nobody types a hash — this reads them from the `.sha256` files the
# release workflow already publishes beside each artifact.
#
#     ./scripts/update-packaging.sh 0.2.0
#
# Run it after the release is published, not before: it downloads from the release URL.

set -euo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>   # e.g. 0.2.0" >&2; exit 2; }
VERSION="${VERSION#v}"

REPO="${REPO:-bojieli/DoNotType}"
BASE="https://github.com/$REPO/releases/download/v$VERSION"

# The published `.sha256` rather than a re-download of the artifact: it is the same number, it is
# what a user verifying by hand would check against, and it is a few bytes instead of tens of
# megabytes. If the two ever disagree, the packaging should carry what the release published.
fetch_sha() {
  local name="$1"
  local line
  if ! line=$(curl -fsSL "$BASE/$name.sha256"); then
    echo "✗ no $name.sha256 at $BASE — is v$VERSION published?" >&2
    exit 1
  fi
  echo "$line" | awk '{ print $1 }'
}

echo "reading checksums for v$VERSION"
MAC_SHA=$(fetch_sha "DoNotType-macOS.zip")
WIN_SHA=$(fetch_sha "DoNotType-Windows-x64.zip")
printf '  %-28s %s\n' "DoNotType-macOS.zip" "$MAC_SHA"
printf '  %-28s %s\n' "DoNotType-Windows-x64.zip" "$WIN_SHA"

python3 - "$VERSION" "$MAC_SHA" "$WIN_SHA" <<'PY'
import re, sys

version, mac_sha, win_sha = sys.argv[1], sys.argv[2], sys.argv[3]

# Homebrew: version and sha256 are their own lines, so this is unambiguous.
path = "packaging/homebrew/donottype.rb"
text = open(path).read()
text = re.sub(r'version "[^"]*"', f'version "{version}"', text, count=1)
text = re.sub(r'sha256 "[^"]*"', f'sha256 "{mac_sha}"', text, count=1)
open(path, "w").write(text)

# winget: three files, and the version appears in all of them.
for path in [
    "packaging/winget/DoNotType.yaml",
    "packaging/winget/DoNotType.locale.en-US.yaml",
    "packaging/winget/DoNotType.installer.yaml",
]:
    text = open(path).read()
    text = re.sub(r"PackageVersion: .*", f"PackageVersion: {version}", text)
    text = re.sub(r"/download/v[^/]+/", f"/download/v{version}/", text)
    text = re.sub(r"InstallerSha256: .*", f"InstallerSha256: {win_sha}", text)
    open(path, "w").write(text)
PY

echo "✓ packaging updated to $VERSION"
echo
echo "Next, and both are manual on purpose — each is a submission to somebody else's repository:"
echo "  Homebrew  copy packaging/homebrew/donottype.rb into your tap's Casks/ and push"
echo "  winget    wingetcreate submit packaging/winget/  (needs a signed installer)"
