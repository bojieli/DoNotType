#!/usr/bin/env python3
"""Rebuilds the recordings that must never produce words.

Seeded, so the files are reproducible and a change to them is a deliberate act rather than noise in
a diff. See README.md for what each one is for.
"""

import math
import os
import random
import struct

RATE = 16_000
HERE = os.path.dirname(os.path.abspath(__file__))


def wav(name: str, samples) -> float:
    body = b"".join(struct.pack("<h", max(-32768, min(32767, int(s)))) for s in samples)
    header = (
        b"RIFF" + struct.pack("<I", 36 + len(body)) + b"WAVEfmt "
        + struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16)
        + b"data" + struct.pack("<I", len(body))
    )
    with open(os.path.join(HERE, name), "wb") as handle:
        handle.write(header + body)
    return len(body) // 2 / RATE


def main() -> None:
    random.seed(20260815)

    # The floor case: a muted microphone.
    wav("digital-silence.wav", [0] * (RATE * 3))

    # An open microphone in a quiet room.
    wav("room-tone.wav", [random.gauss(0, 40) for _ in range(RATE * 3)])

    # A fan, air conditioning, a car.
    wav("steady-noise.wav", [random.gauss(0, 600) for _ in range(RATE * 3)])

    # Mains buzz. Louder than quiet speech, and still not speech — which is the point of it.
    wav("hum.wav", [900 * math.sin(2 * math.pi * 50 * t / RATE) for t in range(RATE * 3)])

    # A key press. Enormous dynamic range, no duration.
    clicks = [0.0] * (RATE * 2)
    for i in range(120):
        clicks[RATE // 2 + i] = 9000 * math.exp(-i / 25)
    wav("click.wav", clicks)

    # A tap on the hotkey rather than a hold.
    wav("too-short.wav", [random.gauss(0, 30) for _ in range(RATE // 3)])

    print("rebuilt 6 recordings in", HERE)


if __name__ == "__main__":
    main()
