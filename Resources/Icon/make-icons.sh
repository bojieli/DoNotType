#!/usr/bin/env bash
#
# Renders every platform's app icon from Resources/Icon/DoNotType.svg.
#
# The mark is drawn once, in one file, and every incarnation of the app is a render of it -- the
# same arrangement PROMPT.md has, and for the same reason: four platforms that each own a copy of
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

# Menu-bar images. PDF rather than PNG because a status item is drawn at whatever backing scale
# the display has, and a template image is tinted by the system from its alpha alone.
mkdir -p Resources/MenuBar
for state in idle recording transcribing; do
  out=Resources/MenuBar/Status$(echo "${state:0:1}" | tr '[:lower:]' '[:upper:]')${state:1}.pdf
  rsvg-convert --export-id="status-$state" --format=pdf --width=64 --height=64 \
    "$ROOT/$SVG" --output "$out"
done

echo "==> Windows"
# One .ico holding every size Windows asks for: 16 in the tray at 100% DPI, 24 at 150%, 32 in the
# task switcher, 256 in Explorer's largest view.
mkdir -p windows/DoNotType.App/Assets
for size in 16 20 24; do render icon-small "$size" "$size" "$TMP/win-$size.png"; done
for size in 32 48 64 128 256; do render icon "$size" "$size" "$TMP/win-$size.png"; done
magick "$TMP/win-16.png" "$TMP/win-20.png" "$TMP/win-24.png" "$TMP/win-32.png" \
       "$TMP/win-48.png" "$TMP/win-64.png" "$TMP/win-128.png" "$TMP/win-256.png" \
       windows/DoNotType.App/Assets/DoNotType.ico

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
render icon 1024 1024 "$TMP/ios-1024.png"
magick "$TMP/ios-1024.png" -background black -alpha remove -alpha off \
  ios/App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png

echo "==> docs"
# For the README, and the size Google Play wants for a store listing. The 1024 master lives in
# the iOS asset catalogue; there is no reason to keep a second copy of it here.
mkdir -p Resources/Icon/rendered
render icon 512 512 Resources/Icon/rendered/appicon.png

echo "done"
