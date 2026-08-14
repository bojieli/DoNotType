#!/usr/bin/env python3
"""Counts the user-facing strings a translator could not reach.

"Make it localizable" is otherwise an open-ended chore nobody finishes. This turns it into a number
that can go down: how many strings are assembled by concatenation, which is the one construct that
cannot be translated on any of these platforms.

    ./scripts/localizable-report.py

SwiftUI's `Text("…")` and Android's `getString(R.string.…)` look strings up by key, so a literal is
translatable the moment a catalogue exists. `Text("a " + b)` is not: the pieces reach the catalogue
separately, and no language reassembles a sentence in the order English happens to use.

Deliberately a parser rather than a grep. A concatenated string spans lines, and a line-oriented
search cannot see the continuation — the first version of this reported zero and was believed for
about a minute.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def swift_files() -> list[Path]:
    roots = [ROOT / "Sources/DoNotTypeApp", ROOT / "ios/App", ROOT / "ios/Keyboard"]
    return [p for root in roots if root.exists() for p in root.rglob("*.swift")]


def calls(source: str, name: str):
    """Yields the argument text of every `name(...)` call, brackets balanced."""
    for match in re.finditer(rf"\b{name}\(", source):
        start = match.end()
        depth, index, in_string = 1, start, False
        while index < len(source) and depth:
            character = source[index]
            if character == '"' and source[index - 1] != "\\":
                in_string = not in_string
            elif not in_string:
                if character in "([":
                    depth += 1
                elif character in ")]":
                    depth -= 1
            index += 1
        yield source[start : index - 1]


def strip_strings(text: str) -> str:
    return re.sub(r'"(?:[^"\\]|\\.)*"', '""', text)


def apple() -> tuple[int, int]:
    literal = concatenated = 0
    for path in swift_files():
        source = path.read_text(encoding="utf-8")
        for name in ("Text", "Label"):
            for argument in calls(source, name):
                if '"' not in argument:
                    continue  # a variable or an interpolation of one; nothing to translate
                # A `+` outside a string literal means the sentence is assembled at runtime.
                if "+" in strip_strings(argument):
                    concatenated += 1
                else:
                    literal += 1
    return literal, concatenated


def android() -> tuple[int, int]:
    catalogue = ROOT / "android/app/src/main/res/values/strings.xml"
    defined = len(re.findall(r"<string name=", catalogue.read_text(encoding="utf-8")))

    hardcoded = 0
    for path in (ROOT / "android/app/src/main/kotlin").rglob("*.kt"):
        source = path.read_text(encoding="utf-8")
        for pattern in (r"\btext = \"", r"\bhint = \"", r"Toast\.makeText\([^,]+, \""):
            hardcoded += len(re.findall(pattern, source))
    return defined, hardcoded


def windows() -> int:
    hardcoded = 0
    for path in (ROOT / "windows/DoNotType.App").rglob("*.cs"):
        source = path.read_text(encoding="utf-8")
        hardcoded += len(re.findall(r"Text = \"|MessageBox\.Show\(\"", source))
    return hardcoded


def translations() -> list[str]:
    found = []
    for pattern in ("Resources/Localizations/*.lproj", "android/app/src/main/res/values-*"):
        found += [p.name for p in ROOT.glob(pattern) if p.is_dir()]
    return sorted(found)


def main() -> int:
    def row(label: str, value) -> None:
        print(f"  {label:<52}{value}")

    literal, concatenated = apple()
    print("\nApple — SwiftUI literals are translatable as they stand")
    row('Text("…") and Label("…") literals', literal)
    row("assembled with +, not translatable", concatenated)

    defined, hardcoded = android()
    print("\nAndroid — strings.xml is the catalogue")
    row("strings in strings.xml", defined)
    row("hardcoded in Kotlin, not translatable", hardcoded)

    print("\nWindows — no catalogue yet")
    row("hardcoded in WinForms, not translatable", windows())

    print("\nTranslations present")
    for name in translations() or ["none"]:
        row(name, "")

    print(
        "\nRead this as a direction rather than a target. An English-only interface is a reasonable\n"
        "state for a project with no translators. What this measures is whether translating *could*\n"
        "start without first rewriting the interface — which has to be true before anyone volunteers.\n"
        "\nSee docs/LOCALIZATION.md."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
