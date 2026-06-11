#!/usr/bin/env python3
"""Generate a +3 dBFS 1 kHz test tone and EQ profile for live acoustic verification."""

import json
import math
import struct
import sys
import uuid
import wave
from pathlib import Path

SAMPLE_RATE = 48000
DURATION_S = 4
FREQUENCY = 1000
INPUT_DBFS = 3.0
EQ_BOOST_DB = 2.0
EXPECTED_OUTPUT_DBFS = INPUT_DBFS + EQ_BOOST_DB


def peak_amplitude(dbfs: float) -> float:
    return 10 ** (dbfs / 20.0)


def write_tone_wav(path: Path) -> None:
    peak = peak_amplitude(INPUT_DBFS)
    frames = SAMPLE_RATE * DURATION_S
    with wave.open(str(path), "w") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        for n in range(frames):
            sample = peak * math.sin(2.0 * math.pi * FREQUENCY * n / SAMPLE_RATE)
            clipped = max(-1.0, min(1.0, sample))
            wav.writeframes(struct.pack("<h", int(clipped * 32767)))


def write_profile_json(path: Path) -> None:
    profile = {
        "bands": [
            {
                "frequency": FREQUENCY,
                "gain": EQ_BOOST_DB,
                "id": str(uuid.uuid4()),
                "q": 1.0,
                "type": "peaking",
            }
        ],
        "id": str(uuid.uuid4()),
        "isFavorite": False,
        "name": "Acoustic Verify +2 @ 1 kHz",
        "notes": "Generated for automated acoustic EQ verification",
        "preamp": 0.0,
        "sourceAttribution": None,
    }
    path.write_text(json.dumps(profile, indent=2))


def main() -> int:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/sonarforge_acoustic_test")
    out_dir.mkdir(parents=True, exist_ok=True)

    tone_path = out_dir / "tone_1khz_plus3db.wav"
    profile_path = out_dir / "profile_plus2_1khz.json"

    write_tone_wav(tone_path)
    write_profile_json(profile_path)

    print(f"tone={tone_path}")
    print(f"profile={profile_path}")
    print(f"input_dbfs={INPUT_DBFS}")
    print(f"eq_boost_db={EQ_BOOST_DB}")
    print(f"expected_output_dbfs={EXPECTED_OUTPUT_DBFS}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())