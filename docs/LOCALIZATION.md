# Localization

The interface is English. The *transcription* never was — the prompt tells the model to keep the
speaker's language and never translate, and the evaluation corpus is mostly Mandarin. So a Chinese
speaker can dictate Chinese perfectly well through an English interface, which is why this has not
been urgent.

What follows is how to translate it, and what has to be true first.

## The state of it

```bash
./scripts/localizable-report.py
```

That prints how many strings a translator could reach and how many they could not. Treat it as a
direction rather than a target: English-only is a reasonable state for a project with no
translators, and the number that matters is the second one — whether translating *could* start
without first rewriting the interface.

## Apple: the English string is the key

SwiftUI's `Text("Transcribe")` takes a `LocalizedStringKey`, so every literal is already a lookup.
There is no extraction step and no key list to maintain: add a `.lproj` and the app is translated.

```
Resources/Localizations/zh-Hans.lproj/Localizable.strings
```

```
"Transcribe" = "转写";
"Choose a recording…" = "选择录音…";
```

`make app` copies any `.lproj` it finds into the bundle, and the iOS project includes the same
directory. Nothing else is needed.

**What blocks it: strings assembled with `+`.** This is the one construct that cannot be translated,
and the report counts them:

```swift
// Cannot be translated. The two halves reach the catalogue separately, and no language is obliged
// to put them in this order.
Text("Recording… " + hint)

// Can be. One key, one sentence, with the variable interpolated at the position the translation
// chooses.
Text("Recording… \(hint)")
```

Most of the long explanatory paragraphs in Settings are concatenated because they were written to
fit inside a line limit. Converting them is mechanical and safe, and worth doing when you are
already editing one, rather than as a sweep — a sweep of a hundred strings is a hundred chances to
change what one of them says.

## Android: `strings.xml`, as usual

Four strings are already there because the system needs them: the app name, the keyboard's name and
the accessibility service's description, which Android itself displays in Settings. The rest of the
interface is built in Kotlin with literals.

The convention is the ordinary one — `getString(R.string.…)`, translations in
`res/values-zh-rCN/strings.xml`. Move strings across as you touch the screens rather than in one
pass, for the same reason as above.

## Windows: no catalogue yet

WinForms localizes through `.resx` resources and `ResourceManager`. Nothing has been set up, because
nothing has needed it. Whoever wants a translated Windows build should add
`Resources/Strings.resx`, a `Strings.zh-CN.resx` beside it, and route the settings form through it.

## The CLIs are not localized, and will not be

`dnt` and `dnt-eval` print in English, and that is a decision rather than an omission. Their output
is parsed by scripts, pasted into issues, and quoted in this documentation; a message that changes
with the operator's locale is one that cannot be searched for. The same reasoning as error codes.

## If you want to contribute a translation

The interface strings are the small part. The parts that would actually need care:

- **`PROMPT.md` is not translated and must not be.** It is the contract sent to the model, its
  wording is measured, and the changelog's numbers describe that exact text. A translated prompt is
  a different prompt with no measurements behind it.
- **The explanatory paragraphs carry the argument.** "Even Tidy only changes typography" and "screen
  text may correct spelling, never content" are the product, not chrome. A translation that softens
  them into ordinary marketing has lost the thing being said.
- **The permission explanations are load-bearing.** They are what someone reads while deciding
  whether to let an app read their screen. Accuracy beats fluency there.

Open an issue before starting, so two people do not translate the same screen.
