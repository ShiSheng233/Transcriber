# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["numpy>=1.24", "transformers>=4.45,<5"]
# ///
"""Write a reference log-mel spectrogram for AudioFeaturesTests.

Runs Hugging Face's WhisperFeatureExtractor (the front end the original
pipeline uses for its VAD) on a deterministic 10 s signal, which the extractor
zero-pads to 30 s like the VAD does for a short last chunk.

Output (little-endian float32, no header):
    input-samples.f32   160000 samples at 16 kHz
    whisper-base-mel.f32  80 x 3000 log-mel features, mel band major

Usage:
    uv run --script make_mel_fixture.py OUTPUT_DIR
"""

import sys
from pathlib import Path

import numpy as np
from transformers import WhisperFeatureExtractor

SAMPLE_RATE = 16_000
DURATION_SECONDS = 10


def make_signal() -> np.ndarray:
    """A 100 Hz -> 6 kHz chirp plus quiet seeded noise, with 2 s of silence."""
    time = np.arange(SAMPLE_RATE * DURATION_SECONDS) / SAMPLE_RATE
    start_hz, end_hz = 100.0, 6_000.0
    sweep_rate = (end_hz - start_hz) / DURATION_SECONDS
    chirp = 0.5 * np.sin(2 * np.pi * (start_hz * time + 0.5 * sweep_rate * time**2))
    noise = 0.01 * np.random.default_rng(seed=0).standard_normal(time.shape)
    signal = chirp + noise
    signal[4 * SAMPLE_RATE : 6 * SAMPLE_RATE] = 0.0
    return signal.astype(np.float32)


def main() -> None:
    output_dir = Path(sys.argv[1])
    output_dir.mkdir(parents=True, exist_ok=True)
    samples = make_signal()
    # The VAD metadata names openai/whisper-base; its preprocessor config is the
    # library default (80 mel bands, n_fft 400, hop 160, 30 s).
    extractor = WhisperFeatureExtractor(feature_size=80)
    features = extractor(samples, sampling_rate=SAMPLE_RATE, return_tensors="np").input_features[0]
    assert features.shape == (80, 3000), features.shape

    samples.astype("<f4").tofile(output_dir / "input-samples.f32")
    features.astype("<f4").tofile(output_dir / "whisper-base-mel.f32")
    print(f"wrote {output_dir} (features min {features.min():.4f}, max {features.max():.4f})")


if __name__ == "__main__":
    main()
