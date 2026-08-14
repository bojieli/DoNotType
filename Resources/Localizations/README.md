# Translations

Drop a `.lproj` directory here and both Apple apps pick it up — `make app` copies whatever is
present into the bundle, and the iOS project includes this directory.

```
Resources/Localizations/zh-Hans.lproj/Localizable.strings
```

The key is the English string, because SwiftUI's `Text("…")` is a `LocalizedStringKey`. There is no
extraction step and no key list to keep in sync:

```
"Transcribe" = "转写";
```

Read [docs/LOCALIZATION.md](../../docs/LOCALIZATION.md) first — particularly the part about which
strings carry the argument and must not be softened, and the one about `PROMPT.md`, which is a
contract sent to a model and must never be translated.
