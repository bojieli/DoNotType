#!/usr/bin/env python3
"""Builds a local page for verifying dictation clips by ear.

Why this exists
---------------
Every accuracy number in `docs/EVALUATION.md` rests on ground truth, and the ordinary-dictation
corpus has none. `dnt-eval dictation` can measure latency, failure rate and cross-backend
agreement without it, but not whether any transcript is *right* — and agreement is not correctness,
because two backends can share a mistake.

The missing step needs a human with the audio, and the thing that makes it expensive is not the
listening, it is the tooling: a hundred clips, four transcripts each, spread across a JSON file
nobody can play. This puts the audio and the candidate transcripts side by side, worst
disagreement first, and lets the verified text be exported as JSON that can be scored.

Clips are ordered by how much the backends disagree, because that is where a human ear buys the
most: where three independent backends produced the same words they are probably right, and
listening to those first spends the scarce resource on the easy cases.

Privacy: the corpus is the maintainer's own speech and `eval/dictation/` is gitignored. This page
references the audio by relative path rather than embedding it, so nothing leaves the machine and
the file stays small enough to open.

Usage:  ./make-review-sheet.py [--corpus eval/dictation] [--limit 30]
        open eval/dictation/review.html
"""

import argparse
import collections
import html
import json
import sys
from pathlib import Path


def tokens(text: str) -> list[str]:
    """Latin words, CJK per character — the split `dnt-eval dictation` uses."""
    out: list[str] = []
    current = ""
    for character in text.lower():
        codepoint = ord(character)
        if 0x4E00 <= codepoint <= 0x9FFF or 0x3040 <= codepoint <= 0x30FF:
            if current:
                out.append(current)
                current = ""
            out.append(character)
        elif character.isalnum():
            current += character
        else:
            if current:
                out.append(current)
                current = ""
    if current:
        out.append(current)
    return out


def similarity(left: str, right: str) -> float:
    a, b = tokens(left), tokens(right)
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    counts = collections.Counter(a)
    shared = 0
    for word in b:
        if counts[word] > 0:
            counts[word] -= 1
            shared += 1
    return 2 * shared / (len(a) + len(b))


PAGE = """<!doctype html>
<meta charset="utf-8">
<title>DoNotType — verify transcripts by ear</title>
<style>
  :root {{ color-scheme: light dark; --bg:#fff; --fg:#1a1a1a; --muted:#666; --line:#e3e3e3;
           --card:#fafafa; --warn:#b45309; }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --bg:#16181c; --fg:#e8e8e8; --muted:#9aa0a6; --line:#2c2f36; --card:#1d2026;
             --warn:#f0b429; }}
  }}
  body {{ background:var(--bg); color:var(--fg); margin:0 auto; padding:32px 20px; max-width:900px;
          font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }}
  h1 {{ font-size:22px; margin:0 0 6px; }}
  .lede {{ color:var(--muted); margin:0 0 28px; }}
  .clip {{ border:1px solid var(--line); border-radius:10px; padding:16px 18px; margin:0 0 18px;
           background:var(--card); }}
  .head {{ display:flex; gap:12px; align-items:baseline; flex-wrap:wrap; margin-bottom:10px; }}
  .id {{ font-weight:600; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }}
  .meta {{ color:var(--muted); font-size:13px; }}
  .agree {{ margin-left:auto; font-size:13px; font-weight:600; }}
  audio {{ width:100%; margin:6px 0 12px; }}
  table {{ width:100%; border-collapse:collapse; font-size:14px; }}
  td {{ padding:6px 8px; vertical-align:top; border-top:1px solid var(--line); }}
  td.who {{ width:96px; color:var(--muted); font-family:ui-monospace,Menlo,monospace;
            white-space:nowrap; }}
  textarea {{ width:100%; box-sizing:border-box; margin-top:10px; padding:8px; min-height:52px;
              border:1px solid var(--line); border-radius:6px; background:var(--bg);
              color:var(--fg); font:14px/1.5 inherit; }}
  .bar {{ position:sticky; top:0; background:var(--bg); padding:12px 0; border-bottom:1px solid
          var(--line); margin-bottom:20px; display:flex; gap:12px; align-items:center; }}
  button {{ font:inherit; padding:7px 14px; border-radius:7px; border:1px solid var(--line);
            background:var(--card); color:var(--fg); cursor:pointer; }}
  .note {{ color:var(--warn); font-size:13px; }}
  code {{ font-family:ui-monospace,Menlo,monospace; font-size:13px; }}
</style>

<h1>Verify transcripts by ear</h1>
<p class="lede">
  {count} clips, worst backend disagreement first — that is where listening buys the most, because
  where independent backends already agree they are probably right. Type what you actually hear;
  leave a clip blank to skip it. Nothing here leaves your machine.
</p>

<div class="bar">
  <button onclick="exportJSON()">Export verified transcripts</button>
  <span class="meta" id="progress"></span>
  <span class="note" id="saved"></span>
</div>

{clips}

<script>
  const KEY = "dnt-review-v1";
  const saved = JSON.parse(localStorage.getItem(KEY) || "{{}}");

  document.querySelectorAll("textarea").forEach(box => {{
    if (saved[box.dataset.clip]) box.value = saved[box.dataset.clip];
    box.addEventListener("input", () => {{
      saved[box.dataset.clip] = box.value;
      localStorage.setItem(KEY, JSON.stringify(saved));
      document.getElementById("saved").textContent = "saved locally";
      progress();
    }});
  }});

  function progress() {{
    const done = Object.values(saved).filter(v => v.trim()).length;
    document.getElementById("progress").textContent = done + " of {count} verified";
  }}
  progress();

  // Written as the shape eval/score-review.py reads, so verifying and scoring are one step apart.
  function exportJSON() {{
    const rows = Object.entries(saved)
      .filter(([, text]) => text.trim())
      .map(([clip, text]) => ({{ clip, verified: text.trim() }}));
    const blob = new Blob([JSON.stringify({{ verified: rows }}, null, 2)],
                          {{ type: "application/json" }});
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = "verified.json";
    link.click();
  }}
</script>
"""


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--corpus", default="eval/dictation")
    parser.add_argument("--limit", type=int, default=30,
                        help="How many clips to include, worst agreement first.")
    parser.add_argument("--fixtures", action="store_true",
                        help="Review the near-miss fixtures and their goldens instead.")
    args = parser.parse_args()

    if args.fixtures:
        return build_fixture_sheet()

    root = Path(args.corpus)
    try:
        manifest = json.loads((root / "manifest.json").read_text())
        results = json.loads((root / "results.json").read_text())["results"]
    except FileNotFoundError as error:
        print(f"{error}\nBuild the corpus first: eval/build-dictation-corpus.py", file=sys.stderr)
        return 1

    entries = {e["id"]: e for e in manifest["entries"]}
    by_clip: dict[str, dict[str, str]] = collections.defaultdict(dict)
    for row in results:
        if row.get("error") or not row.get("text"):
            continue
        by_clip[row["clip"]][row["provider"]] = row["text"]

    scored = []
    for clip, texts in by_clip.items():
        if len(texts) < 2:
            continue
        names = sorted(texts)
        pairs = [similarity(texts[a], texts[b])
                 for i, a in enumerate(names) for b in names[i + 1:]]
        scored.append((sum(pairs) / len(pairs), clip, texts))
    scored.sort()

    blocks = []
    for agreement, clip, texts in scored[: args.limit]:
        entry = entries.get(clip, {})
        rows = "".join(
            f'<tr><td class="who">{html.escape(name)}</td>'
            f"<td>{html.escape(text)}</td></tr>"
            for name, text in sorted(texts.items()))
        blocks.append(f"""<div class="clip">
  <div class="head">
    <span class="id">{html.escape(clip)}</span>
    <span class="meta">{entry.get('seconds', '?')}s · {html.escape(str(entry.get('source', '')))}
      @ {entry.get('offsetSeconds', '?')}s</span>
    <span class="agree">{agreement * 100:.0f}% agreement</span>
  </div>
  <audio controls preload="none" src="{html.escape(entry.get('audio', ''))}"></audio>
  <table>{rows}</table>
  <textarea data-clip="{html.escape(clip)}"
            placeholder="What you actually hear — leave blank to skip"></textarea>
</div>""")

    out = root / "review.html"
    out.write_text(PAGE.format(count=len(blocks), clips="\n".join(blocks)))
    print(f"{len(blocks)} clips → {out}")
    print(f"open {out}")
    return 0


def build_fixture_sheet() -> int:
    """The near-miss fixtures beside the ground truth each one asserts.

    Different question from the dictation sheet. There the transcripts are candidates and the
    truth is missing; here the truth is *claimed*, and the point is to check whether the claim
    matches the audio. Five of these were spoken by macOS `say` and their goldens are correct by
    construction — the text was written first, then synthesised. The rest are extracts of real
    speech whose goldens were written down by a human listening, and those are the ones worth an
    ear.
    """
    cases_dir = Path("eval/nearmiss")
    audio_dir = Path("eval/audio")
    synthesised = set()
    script = Path("eval/make-audio.sh")
    if script.exists():
        for line in script.read_text().splitlines():
            if line.strip().startswith("synth "):
                parts = line.split(None, 2)
                if len(parts) >= 2:
                    synthesised.add(parts[1])

    blocks = []
    for path in sorted(cases_dir.glob("*.json")):
        case = json.loads(path.read_text())
        audio_name = Path(case["audio"]).name
        stem = Path(audio_name).stem
        origin = ("macOS <code>say</code> — golden exact by construction"
                  if stem in synthesised else
                  "real recorded speech — golden written down by ear")

        claims = []
        if case.get("expectTranscript"):
            claims.append(("exact transcript", case["expectTranscript"]))
        for fragment in case.get("mustContain") or []:
            claims.append(("must contain", fragment))
        for fragment in case.get("mustNotContain") or []:
            claims.append(("must NOT contain", fragment))
        if case.get("mustBeScript"):
            claims.append(("script", case["mustBeScript"]))
        rows = "".join(
            f'<tr><td class="who">{html.escape(label)}</td>'
            f"<td>{html.escape(str(value))}</td></tr>" for label, value in claims)

        blocks.append(f"""<div class="clip">
  <div class="head">
    <span class="id">{html.escape(case['id'])}</span>
    <span class="meta">{html.escape(audio_name)} · {html.escape(origin)}</span>
  </div>
  <audio controls preload="none" src="../audio/{html.escape(audio_name)}"></audio>
  <table>{rows}</table>
  <textarea data-clip="{html.escape(case['id'])}"
            placeholder="Wrong? Type what you actually hear — leave blank if the golden is right"></textarea>
</div>""")

    out = cases_dir.parent / "dictation" / "fixtures.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    page = PAGE.format(count=len(blocks), clips="\n".join(blocks))
    page = page.replace(
        "worst backend disagreement first — that is where listening buys the most, because\n"
        "  where independent backends already agree they are probably right. Type what you actually"
        " hear;\n  leave a clip blank to skip it. Nothing here leaves your machine.",
        "the near-miss fixtures beside the ground truth each asserts. Five were spoken by macOS "
        "<code>say</code>, so their goldens are correct by construction. The rest are real speech "
        "whose goldens were written down by ear — those are the ones worth checking. Leave a box "
        "blank if the golden is right.")
    out.write_text(page)
    print(f"{len(blocks)} fixtures → {out}")
    print(f"open {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
