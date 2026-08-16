#!/usr/bin/env bash
#
# Renders every platform's app icon from Resources/Icon/DoNotType.svg.
#
# The mark is drawn once, in one file, and every incarnation of the app is a render of it -- the
# same arrangement prompt/ has, and for the same reason: four platforms that each own a copy of
# the artwork are four platforms that will quietly disagree about what the app looks like.
#
# Outputs are committed, so building the app needs none of the tools below. Run this only after
# editing the SVG, and commit what it changes.
#
#   ./Resources/Icon/make-icons.sh            render everything
#   ./Resources/Icon/make-icons.sh squircle   print the macOS corner path, for pasting into the SVG
#
# Needs: rsvg-convert and magick (brew install librsvg imagemagick), plus iconutil from macOS.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ROOT=$PWD
SVG=Resources/Icon/DoNotType.svg
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The macOS icon corner is a superellipse, not a rounded rectangle, and eyeballing the difference
# is exactly the kind of thing that looks fine alone and wrong beside every other icon in the
# Finder. This prints |x|^5 + |y|^5 = 1 fitted with cubic Beziers, at Apple's 824 within 1024.
if [[ "${1:-}" == "squircle" ]]; then
  python3 -c '
import math
a, cx, cy, n, N = 412.0, 512.0, 512.0, 5.0, 24
pt = lambda t: (cx + a*(abs(math.cos(t))**n + abs(math.sin(t))**n)**(-1/n)*math.cos(t),
                cy + a*(abs(math.cos(t))**n + abs(math.sin(t))**n)**(-1/n)*math.sin(t))
def tangent(t, h=1e-5):
    (x1, y1), (x2, y2) = pt(t-h), pt(t+h)
    return ((x2-x1)/(2*h), (y2-y1)/(2*h))
step = 2*math.pi/N
pts, tans = [pt(step*i) for i in range(N)], [tangent(step*i) for i in range(N)]
out = "M %.1f %.1f" % pts[0]
for i in range(N):
    (x0, y0), (x3, y3) = pts[i], pts[(i+1) % N]
    (tx0, ty0), (tx3, ty3) = tans[i], tans[(i+1) % N]
    k = step/3
    out += " C %.1f %.1f %.1f %.1f %.1f %.1f" % (
        x0+tx0*k, y0+ty0*k, x3-tx3*k, y3-ty3*k, x3, y3)
print(out + " Z")'
  exit 0
fi

for tool in rsvg-convert magick; do
  command -v "$tool" >/dev/null || { echo "missing $tool"; exit 1; }
done

# render <variant-id> <width> <height> <output>
render() {
  rsvg-convert --export-id="$1" --width="$2" --height="$3" "$ROOT/$SVG" --output "$4"
}

echo "==> macOS"
# Apple's iconset. Below 32px the detailed art turns to mush, so those slots get the variant with
# a larger, flatter mark; this is what the per-size images in an .icns are for.
ICONSET=$TMP/DoNotType.iconset
mkdir -p "$ICONSET"
render icon-macos-small 16 16 "$ICONSET/icon_16x16.png"
render icon-macos-small 32 32 "$ICONSET/icon_16x16@2x.png"
render icon-macos-small 32 32 "$ICONSET/icon_32x32.png"
render icon-macos 64 64 "$ICONSET/icon_32x32@2x.png"
render icon-macos 128 128 "$ICONSET/icon_128x128.png"
render icon-macos 256 256 "$ICONSET/icon_128x128@2x.png"
render icon-macos 256 256 "$ICONSET/icon_256x256.png"
render icon-macos 512 512 "$ICONSET/icon_256x256@2x.png"
render icon-macos 512 512 "$ICONSET/icon_512x512.png"
render icon-macos 1024 1024 "$ICONSET/icon_512x512@2x.png"
iconutil --convert icns "$ICONSET" --output Resources/AppIcon.icns

# Menu-bar images, at the 18pt the status bar draws and again at 2x for Retina. A template image
# is tinted by the system from its alpha alone, so these carry no colour.
#
# PDF would scale to any backing store from one file, and was the first thing tried, but cairo
# stamps a creation timestamp into every PDF it writes -- so re-running this script produced three
# changed files whether or not the artwork had moved, which makes "commit what changed" useless
# advice. Rendering the two sizes rsvg emits byte-identically is worth more than the third scale
# factor macOS does not have.
mkdir -p Resources/MenuBar
for state in idle recording transcribing; do
  name=Status$(echo "${state:0:1}" | tr '[:lower:]' '[:upper:]')${state:1}
  render "status-$state" 18 18 "Resources/MenuBar/$name.png"
  render "status-$state" 36 36 "Resources/MenuBar/$name@2x.png"
done

echo "==> Windows"
# One .ico holding every size Windows asks for: 16 in the tray at 100% DPI, 24 at 150%, 32 in the
# task switcher, 256 in Explorer's largest view.
mkdir -p windows/DoNotType.App/Assets
ICO=windows/DoNotType.App/Assets/DoNotType.ico
for size in 16 20 24; do render icon-small "$size" "$size" "$TMP/win-$size.png"; done
for size in 32 48 64 128 256; do render icon "$size" "$size" "$TMP/win-$size.png"; done
magick "$TMP/win-16.png" "$TMP/win-20.png" "$TMP/win-24.png" "$TMP/win-32.png" \
       "$TMP/win-48.png" "$TMP/win-64.png" "$TMP/win-128.png" "$ICO"

# The 256 slot is appended by hand because it has to hold a PNG rather than the uncompressed DIB
# ImageMagick writes for every size. That is what Windows has read since Vista and what every icon
# toolchain emits at this size, and it costs 34KB where the raw bitmap cost 270KB.
#
# Nothing at runtime asks for it: System.Drawing tops out below 256 and hands back the 128 entry
# whatever this slot contains, which is a GDI+ limit rather than anything about the file. The
# reader that does use it is the shell's, behind Explorer's Extra Large Icons.
python3 - "$ICO" "$TMP/win-256.png" <<'PY'
import struct, sys

ico_path, png_path = sys.argv[1], sys.argv[2]
with open(ico_path, "rb") as f:
    ico = f.read()
with open(png_path, "rb") as f:
    png = f.read()

_, kind, count = struct.unpack_from("<HHH", ico, 0)
assert kind == 1, f"not an icon file: type {kind}"

# Every existing payload slides down by the one directory entry being inserted.
old_header = 6 + 16 * count
entries = []
for i in range(count):
    w, h, colours, res, planes, bpp, size, offset = struct.unpack_from("<BBBBHHII", ico, 6 + 16 * i)
    entries.append((w, h, colours, res, planes, bpp, size, offset + 16))
payloads = ico[old_header:]

# A width and height of zero is how the format spells 256; a byte cannot hold the number itself.
entries.append((0, 0, 0, 0, 1, 32, len(png), 6 + 16 * (count + 1) + len(payloads)))

out = struct.pack("<HHH", 0, 1, count + 1)
for entry in entries:
    out += struct.pack("<BBBBHHII", *entry)
with open(ico_path, "wb") as f:
    f.write(out + payloads + png)
PY

echo "==> Android"
# Adaptive icon layers are 108dp regardless of density, and the launcher masks them to its own
# shape. The monochrome layer is what Android 13 tints to the wallpaper.
# The trailing number is the legacy square icon, 48dp at each density: launchers that ask for a
# plain drawable instead of the adaptive one still get the mark rather than nothing.
android_densities=(mdpi:108:48 hdpi:162:72 xhdpi:216:96 xxhdpi:324:144 xxxhdpi:432:192)
for entry in "${android_densities[@]}"; do
  IFS=: read -r density layer legacy <<<"$entry"
  dir=android/app/src/main/res/mipmap-$density
  mkdir -p "$dir"
  render android-background "$layer" "$layer" "$dir/ic_launcher_background.png"
  render android-foreground "$layer" "$layer" "$dir/ic_launcher_foreground.png"
  render android-monochrome "$layer" "$layer" "$dir/ic_launcher_monochrome.png"
  render icon "$legacy" "$legacy" "$dir/ic_launcher.png"
done

echo "==> iOS"
# One 1024 image; Xcode derives every size the system needs from it. Flattened because App Store
# Connect rejects an app icon with an alpha channel, even a fully opaque one.
mkdir -p ios/App/Assets.xcassets/AppIcon.appiconset
# -strip because ImageMagick otherwise writes the current time into a PNG text chunk, which would
# make this file differ on every run for no reason anyone could see.
render icon 1024 1024 "$TMP/ios-1024.png"
magick "$TMP/ios-1024.png" -background black -alpha remove -alpha off -strip \
  ios/App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png

echo "==> docs"
# For the README, and the size Google Play wants for a store listing. The 1024 master lives in
# the iOS asset catalogue; there is no reason to keep a second copy of it here.
mkdir -p Resources/Icon/rendered
render icon 512 512 Resources/Icon/rendered/appicon.png

echo "done"
