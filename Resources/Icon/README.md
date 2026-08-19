# Icon artwork

This document describes the DoNotType app icon, the single-source rendering pipeline that produces
all platform assets from one SVG, the variants rendered for each platform, and where the rendered
outputs are consumed.

## Description

The icon is a text insertion caret whose stem is a microphone. The two serifs of an I-beam caret
bracket a mic capsule, and the caret's lower serif is also the mic's base. The mark states the
product in one glyph: speech placed where the cursor is, with nothing else added.

The colors follow the same reading: amber is the voice, steel is the caret holding it, and the
ink ground is the screen the words land on.

## One source

All assets are rendered from [`DoNotType.svg`](DoNotType.svg). The mark's geometry appears once,
in that file's `<defs>`, and each platform asset is a named group rendered out of it. This is the
same arrangement `prompt/` uses, for the same reason: four platforms that each own a copy of the
artwork would produce inconsistent app icons across four platforms.

The rendered outputs are committed, so building any of the apps requires none of the tools below.

### Re-rendering

```bash
brew install librsvg imagemagick
./Resources/Icon/make-icons.sh          # re-render everything, then commit what changed
./Resources/Icon/make-icons.sh squircle # print the macOS corner path, for pasting into the SVG
```

### Determinism

Running the script twice produces byte-identical output, so a re-run with no edit leaves a clean
tree, and any change a re-run does produce comes from an edit to the source. Two details keep this
true: the menu-bar images are PNG rather than PDF, and the one ImageMagick step passes `-strip`,
because cairo stamps a timestamp into every PDF and ImageMagick writes one into a PNG text chunk.

### Rationale for a manual step

Re-rendering remains a manual step rather than a CI check because the guarantee stops at the
machine: output is not byte-identical across librsvg versions, so a job diffing the committed
assets against a fresh render would fail on the day GitHub bumped a runner image rather than on
the day someone forgot to re-run the script. This is the same reason the integration tests are not
in CI — a check that fails for reasons unrelated to the change is a coin flip, not a signal.
Editing the SVG without re-running the script is caught in review instead.

## Variants

Each variant is a top-level group in the SVG, rendered by export id.

| Variant | Where it goes |
|---|---|
| `icon` | iOS app icon, Windows `.ico` at 32px and up, Android's legacy square icon, README |
| `icon-small` | Windows `.ico` at 16–24px: mark 14% larger, no bloom or sheen |
| `icon-macos` | `AppIcon.icns`, inset to Apple's 824-of-1024 squircle |
| `icon-macos-small` | The 16px and 32px slots of the same `.icns` |
| `android-background`, `android-foreground`, `android-monochrome` | Adaptive launcher layers, 108dp |
| `status-idle`, `status-recording`, `status-transcribing` | macOS menu-bar templates, alpha only |

Small sizes are drawn differently on purpose. Below about 24px, the bloom and the sheen soften
edges that are only two pixels wide to begin with, and a mark sized for a 512px tile reads as a
smudge, so those slots get a larger, flatter variant. This is what per-size images in an `.icns`
and an `.ico` are for.

The menu bar shows state in the same mark: the capsule is hollow when idle, solid while recording,
and becomes a level meter while transcribing. Failure is the exception — it keeps the system
warning triangle, because an error is the one moment where being instantly recognisable beats
being on brand.

## Outputs

| Path | Built by |
|---|---|
| `Resources/AppIcon.icns`, `Resources/MenuBar/*.png` | copied into the bundle by the `Makefile` |
| `windows/DoNotType.App/Assets/DoNotType.ico` | `ApplicationIcon` and an `EmbeddedResource`; read back at runtime by `AppIcon.cs` |
| `android/app/src/main/res/mipmap-*/` | `mipmap-anydpi-v26/ic_launcher.xml` |
| `ios/App/Assets.xcassets/AppIcon.appiconset/` | `ASSETCATALOG_COMPILER_APPICON_NAME` in `ios/project.yml` |
| `Resources/Icon/rendered/appicon.png` | the README, and the 512px Google Play wants |
