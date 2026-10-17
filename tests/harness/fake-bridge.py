#!/usr/bin/env python3
"""Stand-in for voxtype-audio-bridge in the visual test harness.

Prints the bridge's NDJSON frames at 100 Hz: in "speech" mode an RMS level
that rises and falls like words, with voice activity while it is loud, and
in "silent" mode a quiet room with no voice at all, and in "stall" mode
three seconds of that quiet room and then nothing, like a bridge that has
lost the daemon's socket.
"""

import json
import math
import sys
import time


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else "speech"
    print(json.dumps({"status": "connected"}), flush=True)
    start = time.monotonic()
    while True:
        t = time.monotonic() - start
        if mode == "stall" and t >= 3:
            time.sleep(1)
            continue
        if mode in ("silent", "stall"):
            rms = 0.004 + 0.002 * math.sin(t * 7)
        else:
            words = max(0.0, math.sin(t * 5.3)) * max(0.0, math.sin(t * 1.1 + 0.4))
            rms = 0.01 + 0.12 * words
        peak = min(1.0, rms * 3.2)
        frame = {
            "peak": round(peak, 3),
            "rms": round(rms, 3),
            "vad": 1 if rms > 0.05 else 0,
            "ts_ms": int(t * 1000),
        }
        print(json.dumps(frame), flush=True)
        time.sleep(0.01)


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
