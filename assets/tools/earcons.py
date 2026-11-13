#!/usr/bin/env python3
"""Generate ZORO's four earcons as 16-bit mono WAV files.

These sounds are original works synthesised by this script (additive sine partials, no samples,
no recordings, no machine-learning model). The ZORO project dedicates them to the public domain
under CC0 1.0. Re-running the script reproduces them bit for bit.

    python3 -I assets/tools/earcons.py ios/Packages/ZoroDesign/Sources/ZoroDesign/Resources/Sounds

Tuning: Sa = D5 (587.33 Hz). The motif is Sa-Pa, the drone interval of a tanpura, so the sounds sit
with ZORO's palette rather than with a phone's stock alerts. Peak level is -9 dBFS: earcons should
be quieter than speech.
"""

from __future__ import annotations

import math
import os
import struct
import sys
import wave

RATE = 44_100
PEAK = 10 ** (-9 / 20)

SA = 587.33
GA = SA * 5 / 4
PA = SA * 3 / 2
SA_LOW = SA / 2


def note(freq: float, start: float, decay: float, gain: float, bright: float) -> tuple[float, float, float, float, float]:
    return (freq, start, decay, gain, bright)


def render(notes: list[tuple[float, float, float, float, float]], length: float) -> list[float]:
    n = int(RATE * length)
    out = [0.0] * n
    attack = 0.006
    for freq, start, decay, gain, bright in notes:
        first = int(start * RATE)
        # Bell-like partials: fundamental, octave, and a soft inharmonic third partial.
        partials = [(1.0, 1.0), (2.0, 0.28 * bright), (2.76, 0.09 * bright)]
        for i in range(first, n):
            t = (i - first) / RATE
            env = math.exp(-t / decay)
            if t < attack:
                env *= 0.5 - 0.5 * math.cos(math.pi * t / attack)
            if env < 1e-4:
                break
            s = 0.0
            for ratio, amp in partials:
                # Higher partials die faster, as on a struck bell.
                s += amp * math.exp(-t * (ratio - 1) * 6) * math.sin(2 * math.pi * freq * ratio * t)
            out[i] += gain * env * s
    # Fade the last 30 ms to silence so nothing clicks.
    tail = int(0.03 * RATE)
    for k in range(tail):
        out[n - 1 - k] *= k / tail
    peak = max(abs(x) for x in out) or 1.0
    return [x / peak * PEAK for x in out]


EARCONS = {
    # Rising Sa to Pa: "I'm listening".
    "zoro-earcon-listen-start": ([note(SA, 0.0, 0.07, 0.8, 1.0), note(PA, 0.075, 0.16, 1.0, 1.0)], 0.42),
    # Falling Pa to Sa, softer and duller: "I've stopped listening".
    "zoro-earcon-listen-stop": ([note(PA, 0.0, 0.06, 0.8, 0.6), note(SA, 0.07, 0.14, 0.9, 0.6)], 0.36),
    # Sa, Ga, Pa, overlapping: "done".
    "zoro-earcon-done": (
        [note(SA, 0.0, 0.12, 0.7, 1.0), note(GA, 0.07, 0.12, 0.7, 1.0), note(PA, 0.14, 0.26, 1.0, 1.0)],
        0.62,
    ),
    # Two low, dull strikes a semitone apart: "that didn't work".
    "zoro-earcon-error": (
        [note(SA_LOW * 16 / 15, 0.0, 0.09, 1.0, 0.3), note(SA_LOW, 0.12, 0.16, 1.0, 0.3)],
        0.48,
    ),
}


def write(path: str, samples: list[float]) -> None:
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, x)) * 32767)) for x in samples))


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 64
    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)
    for name, (notes, length) in EARCONS.items():
        path = os.path.join(out_dir, name + ".wav")
        write(path, render(notes, length))
        print(f"wrote {path} ({os.path.getsize(path)} bytes, {length:.2f} s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
