#!/usr/bin/env python3
"""Record one dictation or transcribe a local PCM WAV with OpenRouter."""
import argparse
import base64
import getpass
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import wave

PROMPTS = Path(__file__).resolve().parents[1] / "prompt"
ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
MAX_AUDIO = 16 * 1024 * 1024
MAX_SECONDS = 120


def record(path, seconds, device):
    if sys.platform == "darwin":
        if device:
            raise ValueError("Choose the recording input in System Preferences > Sound > Input.")
        helper = Path(__file__).resolve().parent / "macos/record"
        if not helper.is_file():
            raise ValueError("Build the recorder with portable/macos/build.sh first.")
        subprocess.run([str(helper), str(path), str(seconds)], check=True, timeout=seconds + 75)
        return
    if not shutil.which("arecord"):
        raise ValueError("Install ALSA arecord (alsa-utils) or use --audio FILE.")
    subprocess.run(
        ["arecord", "-q", "-D", device or "default", "-t", "wav", "-f", "S16_LE",
         "-r", "16000", "-c", "1", "-d", str(seconds), str(path)],
        check=True, timeout=seconds + 10, stdin=subprocess.DEVNULL,
    )


def read_audio(path):
    with path.open("rb") as source:
        data = source.read(MAX_AUDIO + 1)
    if len(data) > MAX_AUDIO:
        raise ValueError("WAV exceeds the 16 MiB limit.")
    with wave.open(io.BytesIO(data), "rb") as wav:
        count, rate = wav.getnframes(), wav.getframerate()
        if not rate or not 0 < count <= MAX_SECONDS * rate:
            raise ValueError("Provide a nonempty PCM WAV of at most 120 seconds.")
        if len(wav.readframes(count)) != count * wav.getsampwidth() * wav.getnchannels():
            raise ValueError("The WAV recording is incomplete.")
    return data


def transcribe(audio, key, model):
    system = (PROMPTS / "system.md").read_text(encoding="utf-8").replace(
        "{{FIDELITY_RULE}}", (PROMPTS / "fidelity/light.md").read_text(encoding="utf-8").strip())
    part = {"type": "input_audio", "input_audio": {
        "format": "wav", "data": base64.b64encode(audio).decode("ascii")}}
    schema = {"type": "object", "properties": {
        "transcript": {"type": "string"}, "language": {"type": "string"}},
        "required": ["transcript", "language"], "additionalProperties": False}
    body = {"model": model, "messages": [
        {"role": "system", "content": system}, {"role": "user", "content": [part]}],
        "response_format": {"type": "json_schema", "json_schema": {
            "name": "transcript", "strict": True, "schema": schema}}}
    request = urllib.request.Request(
        ENDPOINT, data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=120) as response:
        reply = json.load(response)
    choice = reply["choices"][0]
    if choice.get("finish_reason") == "length":
        raise ValueError("Provider truncated the transcript. Try a shorter recording.")
    transcript = json.loads(choice["message"]["content"])["transcript"]
    if not isinstance(transcript, str):
        raise ValueError("Provider returned an invalid transcript.")
    return "" if transcript.strip() == "[NO_SPEECH]" else transcript.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", type=Path, help="send an existing PCM WAV")
    parser.add_argument("--seconds", type=int, default=10, help="recording duration (1–120, default 10)")
    parser.add_argument("--device", help="ALSA capture device (default: default)")
    parser.add_argument("--model", default="google/gemini-3.6-flash", help="OpenRouter audio model")
    args = parser.parse_args()
    if not 1 <= args.seconds <= MAX_SECONDS:
        parser.error("--seconds must be between 1 and 120")
    key = os.environ.get("OPENROUTER_API_KEY") or getpass.getpass("OpenRouter API key: ")
    if not key.strip():
        parser.error("an OpenRouter API key is required")
    try:
        if args.audio:
            audio = read_audio(args.audio)
        else:
            with tempfile.TemporaryDirectory(prefix="dnt-") as folder:
                path = Path(folder) / "recording.wav"
                print("Recording for {} seconds…".format(args.seconds), file=sys.stderr, flush=True)
                record(path, args.seconds, args.device)
                audio = read_audio(path)
        result = transcribe(audio, key.strip(), args.model)
        if result:
            print(result)
    except urllib.error.HTTPError as exc:
        parser.exit(1, "OpenRouter returned HTTP {} ({}).\n".format(exc.code, exc.reason))
    except (OSError, ValueError, TypeError, KeyError, IndexError, EOFError,
            subprocess.SubprocessError, wave.Error) as exc:
        parser.exit(1, "Dictation failed: {}\n".format(exc))


if __name__ == "__main__":
    main()
