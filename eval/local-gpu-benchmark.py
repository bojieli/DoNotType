#!/usr/bin/env python3
"""Drive a local OpenAI-compatible audio model when Swift is unavailable.

This mirrors the request shape used by OpenAICompatibleProvider: the same PROMPT.md system
instruction, context blocks before the audio, and the same structured-output schema. It is a
portable fallback for GPU boxes, not a replacement for dnt-eval's diff reporting.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
import statistics
import time
import unicodedata
from pathlib import Path

import requests


ROOT = Path(__file__).resolve().parent.parent
MODEL_DEFAULT = "Qwen/Qwen3-Omni-30B-A3B-Instruct"
# This is the ignored espeak transport stand-in that was once copied to the authoritative name.
# Refuse it by default so a local smoke test cannot be reported as the real benchmark.
KNOWN_SYNTHETIC_FIXTURES = {
    "e9d577224798711e58eee3db2e9fe6388776b0dae23298dbe2e0729f34d118cb"
}
CONTEXT_HEADER = "===== SCREEN CONTEXT — REFERENCE ONLY, DO NOT TRANSCRIBE ====="
CONTEXT_FOOTER = """===== END SCREEN CONTEXT =====
None of the text above was spoken. It is a spelling reference only.
Numbers, version numbers, dates and names in your output must come from the audio alone,
even when the text above shows a different value for the same thing.
The audio that follows is the ONLY thing to transcribe."""


def fenced_clause(prompt: str, heading: str) -> str:
    tail = prompt.split(f"### {heading}", 1)[1]
    return tail.split("```", 2)[1].strip().replace("\n", " ")


def system_prompt(fidelity: str = "light") -> str:
    prompt = (ROOT / "PROMPT.md").read_text()
    body = prompt.split("<!-- BEGIN SYSTEM -->", 1)[1].split("<!-- END SYSTEM -->", 1)[0]
    return body.strip().replace("{{FIDELITY_RULE}}", fenced_clause(prompt, fidelity))


def context_parts(context: dict) -> list[dict]:
    identity = []
    app = context.get("appName", "").strip()
    title = context.get("windowTitle", "").strip()
    if app and title:
        identity.append(f"App: {app} — {title}")
    elif app:
        identity.append(f"App: {app}")
    elif title:
        identity.append(f"Window: {title}")
    if context.get("browserURL", "").strip():
        identity.append(f"URL: {context['browserURL'].strip()}")
    if context.get("role", "").strip():
        editable = " · editable" if context.get("isEditable") else ""
        identity.append(f"Field: {context['role'].strip()}{editable}")

    opening = "\n".join([CONTEXT_HEADER, *identity])
    sections = []
    for key, label in (
        ("visibleText", "VISIBLE TEXT (accessibility)"),
        ("textBeforeCaret", "TEXT BEFORE CARET"),
        ("textAfterCaret", "TEXT AFTER CARET"),
        ("selectedText", "SELECTED TEXT"),
    ):
        value = context.get(key, "").strip()
        if value:
            sections.append(f"--- {label} ---\n{value}")
    sections.append(CONTEXT_FOOTER)
    return [
        {"type": "text", "text": opening},
        {"type": "text", "text": "\n\n".join(sections)},
    ]


def audio_part(path: Path) -> dict:
    return {
        "type": "input_audio",
        "input_audio": {
            "data": base64.b64encode(path.read_bytes()).decode(),
            "format": path.suffix.removeprefix(".") or "wav",
        },
    }


def ensure_benchmark_audio(path: Path, allow_synthetic: bool = False) -> None:
    """Reject the known TTS stand-in when it occupies an authoritative fixture path."""
    if allow_synthetic or not path.is_file():
        return
    if path.name not in {"real-talk-gemini15.wav", "real-mandarin.wav"}:
        return
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest in KNOWN_SYNTHETIC_FIXTURES:
        raise RuntimeError(
            f"synthetic stand-in at {path}; supply the real fixture or pass "
            "--allow-synthetic for a transport-only smoke test"
        )


def parse_transcript(content: str) -> str:
    candidate = content.strip()
    if candidate.startswith("```"):
        candidate = "\n".join(candidate.splitlines()[1:-1]).strip()
    try:
        parsed = json.loads(candidate)
        return parsed.get("transcript", candidate).strip()
    except json.JSONDecodeError:
        match = re.search(r'"transcript"\s*:\s*"((?:\\.|[^"\\])*)', candidate)
        if match:
            return bytes(match.group(1), "utf-8").decode("unicode_escape").strip()
        return candidate


class Client:
    def __init__(self, base_url: str, model: str):
        self.base_url = base_url
        self.model = model
        self.session = requests.Session()

    def transcribe(self, audio: Path, context: dict | None = None, system: str | None = None):
        parts = context_parts(context) if context else []
        parts.append(audio_part(audio))
        body = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system or system_prompt()},
                {"role": "user", "content": parts},
            ],
            "max_tokens": 2048,
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "transcript",
                    "strict": True,
                    "schema": {
                        "type": "object",
                        "properties": {
                            "transcript": {"type": "string"},
                            "language": {"type": "string"},
                        },
                        "required": ["transcript", "language"],
                        "additionalProperties": False,
                    },
                },
            },
        }
        started = time.monotonic()
        response = self.session.post(
            self.base_url,
            headers={"Authorization": "Bearer not-required"},
            json=body,
            timeout=180,
        )
        elapsed = time.monotonic() - started
        if response.status_code in (400, 422):
            body.pop("response_format")
            started = time.monotonic()
            response = self.session.post(
                self.base_url,
                headers={"Authorization": "Bearer not-required"},
                json=body,
                timeout=180,
            )
            elapsed = time.monotonic() - started
        response.raise_for_status()
        payload = response.json()
        text = parse_transcript(payload["choices"][0]["message"]["content"])
        usage = payload.get("usage", {})
        audio_tokens = (usage.get("prompt_tokens_details") or {}).get("audio_tokens")
        return text, elapsed, audio_tokens, usage

    def complete_text(self, text: str, system: str):
        """Text-only completion used by the two-pass ablation."""
        body = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": [{"type": "text", "text": text}]},
            ],
            "max_tokens": 2048,
        }
        started = time.monotonic()
        response = self.session.post(
            self.base_url,
            headers={"Authorization": "Bearer not-required"},
            json=body,
            timeout=180,
        )
        response.raise_for_status()
        payload = response.json()
        return parse_transcript(payload["choices"][0]["message"]["content"]), time.monotonic() - started


def run_probe(client: Client, audio: Path, allow_synthetic: bool):
    ensure_benchmark_audio(audio, allow_synthetic)
    text, latency, audio_tokens, usage = client.transcribe(audio)
    print(f"model      {client.model}")
    print(f"audio      {audio}")
    print(f"audioTok   {audio_tokens if audio_tokens is not None else 'not reported'}")
    print(f"latency    {latency:.2f}s")
    print(f"usage      {json.dumps(usage, sort_keys=True)}")
    print(f"output     {text}")


def run_ablate(client: Client, audio: Path, trials: int, allow_synthetic: bool):
    ensure_benchmark_audio(audio, allow_synthetic)
    hostile = {
        "appName": "Safari",
        "windowTitle": "Documentation",
        "visibleText": (
            "Gemini 2.5 Flash is the current model. See the Gemini 2.5 guide. "
            "Gemini 2.5 Flash pricing is lower. Upgrade to Gemini 2.5 today. "
            "Gemini 2.5 Flash benchmarks."
        ),
    }
    prompt = system_prompt()
    single_system = prompt + (
        "\n\nAfter transcribing, rewrite the transcript in this style, keeping every number, "
        "name and identifier exactly as transcribed:\n"
        + fenced_clause((ROOT / "PROMPT.md").read_text(), "style: formal")
    )
    rewrite_system = (
        "You rewrite a transcript of spoken words into clear written prose. Preserve meaning "
        "exactly. Never add or remove a fact, name, number, commitment or caveat. Numbers, "
        "version numbers, dates, names and identifiers pass through unchanged. Fix run-on "
        "sentences, false starts and punctuation. Return only the rewritten text."
    )
    labels = (("no-context", None, prompt), ("verbatim", hostile, prompt),
              ("single-formal", hostile, single_system), ("two-formal", hostile, prompt))
    for label, context, system in labels:
        transcripts, latencies = [], []
        for _ in range(trials):
            if label == "two-formal":
                raw, first_latency, _, _ = client.transcribe(audio, context, system)
                text, second_latency = client.complete_text(raw, rewrite_system)
                latency = first_latency + second_latency
            else:
                text, latency, _, _ = client.transcribe(audio, context, system)
            transcripts.append(text)
            latencies.append(latency)
        substituted = sum("2.5" in text for text in transcripts)
        correct = sum("1.5" in text for text in transcripts if "2.5" not in text)
        no_version = trials - substituted - correct
        judged = substituted + correct
        rate = substituted / judged if judged else 0
        print(
            f"{label}: substituted {substituted}/{judged} ({rate:.0%}); "
            f"correct {correct}; n/a {no_version}; mean {statistics.mean(latencies):.2f}s"
        )
        print(f"  e.g. {transcripts[0]}")


def normalize(value: str) -> str:
    return " ".join(re.findall(r"[a-z0-9]+", value.lower()))


def satisfies_case(text: str, case: dict) -> bool:
    """Apply EvalCase's exact or fragment assertions to a transcript."""
    expected = case.get("expectTranscript")
    if expected:
        return normalize(text) == normalize(expected)

    must_contain = case.get("mustContain", [])
    must_not_contain = case.get("mustNotContain", [])
    # An empty fragment case asserts nothing and must not silently pass.
    if not must_contain and not must_not_contain:
        return False
    def contains_loosely(needle: str) -> bool:
        # Match Swift String.containsLoosely: case- and diacritic-insensitive substring.
        def fold(value: str) -> str:
            decomposed = unicodedata.normalize("NFKD", value.casefold())
            return "".join(char for char in decomposed if not unicodedata.combining(char))

        return fold(needle) in fold(text)

    return (
        all(contains_loosely(fragment) for fragment in must_contain)
        and all(not contains_loosely(fragment) for fragment in must_not_contain)
    )


def run_suite(client: Client, directory: Path, repeat_count: int, allow_synthetic: bool):
    totals = {"matched": 0, "improved": 0, "neutral-correct": 0, "neutral-wrong": 0, "regressed": 0}
    for case_path in sorted(directory.glob("*.json")):
        case = json.loads(case_path.read_text())
        audio = (case_path.parent / case["audio"]).resolve()
        if not audio.is_file():
            print(f"BLOCKED {case['id']}: missing audio fixture {audio}")
            continue
        try:
            ensure_benchmark_audio(audio, allow_synthetic)
        except RuntimeError as error:
            print(f"BLOCKED {case['id']}: {error}")
            continue
        passed = 0
        sample_failure = None
        for _ in range(repeat_count):
            with_context, _, _, _ = client.transcribe(audio, case["context"])
            baseline, _, _, _ = client.transcribe(audio)
            grounded_ok = satisfies_case(with_context, case)
            baseline_ok = satisfies_case(baseline, case)
            if grounded_ok:
                passed += 1
                totals["matched"] += 1
            effect = {
                (False, True): "improved",
                (True, False): "regressed",
                (True, True): "neutral-correct",
                (False, False): "neutral-wrong",
            }[(baseline_ok, grounded_ok)]
            totals[effect] += 1
            if not grounded_ok and sample_failure is None:
                expected = case.get("expectTranscript")
                assertion = (
                    f"expected {expected}"
                    if expected
                    else f"mustContain={case.get('mustContain', [])}, "
                    f"mustNotContain={case.get('mustNotContain', [])}"
                )
                sample_failure = (assertion, with_context, baseline, effect)
        verdict = "PASS" if passed == repeat_count else ("FAIL" if passed == 0 else "FLAKY")
        print(f"{verdict:5} {case['id']} {passed}/{repeat_count}")
        if sample_failure:
            print(f"  expected {sample_failure[0]}")
            print(f"  got      {sample_failure[1]}")
            print(f"  baseline {sample_failure[2]}")
            print(f"  effect   {sample_failure[3]}")
    print(json.dumps(totals, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("probe", "ablate", "suite"))
    parser.add_argument("--base-url", default="http://127.0.0.1:8000/v1/chat/completions")
    parser.add_argument("--model", default=MODEL_DEFAULT)
    parser.add_argument("--audio", type=Path, default=ROOT / "eval/audio/real-talk-gemini15.wav")
    parser.add_argument("--trials", type=int, default=15)
    parser.add_argument("--directory", type=Path, default=ROOT / "eval/nearmiss")
    parser.add_argument("--repeat-count", type=int, default=3)
    parser.add_argument(
        "--allow-synthetic",
        action="store_true",
        help="allow the known ignored TTS stand-in for transport smoke tests",
    )
    args = parser.parse_args()
    client = Client(args.base_url, args.model)
    try:
        if args.command == "probe":
            run_probe(client, args.audio, args.allow_synthetic)
        elif args.command == "ablate":
            run_ablate(client, args.audio, args.trials, args.allow_synthetic)
        else:
            run_suite(client, args.directory, args.repeat_count, args.allow_synthetic)
    except RuntimeError as error:
        print(f"BLOCKED {error}")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
