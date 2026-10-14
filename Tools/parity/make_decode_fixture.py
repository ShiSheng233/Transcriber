# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["av>=11,<16", "faster-whisper==1.2.1", "numpy>=1.24", "soundfile>=0.12"]
# ///
"""Write reference decoded audio for MediaDecodingTests with faster-whisper's decode_audio.

PyAV is held below 16, which drops the metadata_errors argument
faster-whisper 1.2.1 passes.

Builds a 3 s stereo 44.1 kHz clip (Japanese TTS on the left, a chirp on the
right), stores it as 16-bit WAV and as AAC in M4A (via afconvert), and decodes
both with faster_whisper.audio.decode_audio (PyAV: s16 mono 16 kHz / 32768).

Output:
    stereo-44k.wav, stereo-44k.m4a           inputs
    stereo-44k.wav.f32, stereo-44k.m4a.f32   expected samples, little-endian float32

Usage:
    uv run --script make_decode_fixture.py OUTPUT_DIR
"""

import subprocess
import sys
import tempfile
from pathlib import Path

import av
import numpy as np
import soundfile
from faster_whisper.audio import decode_audio

SOURCE_RATE = 44_100
DURATION_SECONDS = 3.0


def speech_channel(sample_count: int) -> np.ndarray:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "speech.wav"
        subprocess.run(
            ["say", "-v", "Kyoko", "--file-format=WAVE", f"--data-format=LEF32@{SOURCE_RATE}",
             "-o", str(path), "字幕のテストです。"],
            check=True,
        )
        speech, _ = soundfile.read(path, dtype="float32")
    channel = np.zeros(sample_count, dtype=np.float32)
    channel[: min(sample_count, len(speech))] = speech[:sample_count]
    return channel


def chirp_channel(sample_count: int) -> np.ndarray:
    time = np.arange(sample_count) / SOURCE_RATE
    return (0.3 * np.sin(2 * np.pi * (200 * time + 1_500 * time**2))).astype(np.float32)


def main() -> None:
    output_dir = Path(sys.argv[1])
    output_dir.mkdir(parents=True, exist_ok=True)
    sample_count = int(SOURCE_RATE * DURATION_SECONDS)
    stereo = np.stack([speech_channel(sample_count), chirp_channel(sample_count)], axis=1)

    wav_path = output_dir / "stereo-44k.wav"
    m4a_path = output_dir / "stereo-44k.m4a"
    soundfile.write(wav_path, stereo, SOURCE_RATE, subtype="PCM_16")
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "96000", str(wav_path), str(m4a_path)], check=True)

    for path in [wav_path, m4a_path]:
        decoded = decode_audio(str(path), sampling_rate=16_000)
        decoded.astype("<f4").tofile(output_dir / f"{path.name}.f32")
        print(f"{path.name}: {len(decoded)} samples")
    print(f"PyAV {av.__version__}, FFmpeg {av.library_versions.get('libavcodec')}")


if __name__ == "__main__":
    main()
