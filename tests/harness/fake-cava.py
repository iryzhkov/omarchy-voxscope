#!/usr/bin/python3 -I
"""Stand-in for cava in the visual test harness.

Prints cava's raw ASCII output at 60 frames a second: 32 bars from 0 to
1000 separated by semicolons, one frame per line, as the cava.conf template
asks for. The arguments ("-p <config>") are ignored. HARNESS_CAVA picks
the level:

  quiet  0.6 s of room hiss (0 to 2 of 1000), then speech-shaped bands
         peaking at about 30 of 1000, like soft speech into a laptop
         microphone
  loud   the same speech peaking at about 900, with the loudest bands
         touching 1000 on the loudest syllables
"""

import math
import os
import random
import sys
import time

BARS = 32


def shape(i: int) -> float:
    """Relative loudness of band i in speech: strong low-mid, weaker highs."""
    return 0.75 * math.exp(-(((i - 7) / 7) ** 2)) + 0.35 * math.exp(-(((i - 17) / 5) ** 2))


def main() -> None:
    mode = os.environ.get("HARNESS_CAVA", "quiet")
    top = 900 if mode == "loud" else 30
    rng = random.Random(7)
    start = time.monotonic()
    while True:
        t = time.monotonic() - start
        speaking = t >= 0.6
        words = max(0.0, math.sin(t * 5.3)) * max(0.0, math.sin(t * 1.1 + 0.4)) if speaking else 0.0
        # Syllables of different loudness, so peaks vary word to word.
        accent = 0.75 + 0.25 * math.sin(t * 2.3)
        bars = []
        for i in range(BARS):
            hiss = rng.uniform(0, 2)
            voice = top * shape(i) * words * accent * rng.uniform(0.85, 1.15) / 0.75
            bars.append(str(int(min(1000, hiss + voice))))
        sys.stdout.write(";".join(bars) + ";\n")
        sys.stdout.flush()
        time.sleep(1 / 60)


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
