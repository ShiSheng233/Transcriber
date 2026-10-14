# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["numpy>=1.24", "onnxruntime>=1.20", "soundfile>=0.12", "transformers>=4.45,<5"]
# ///
"""Write reference VAD probabilities for SpeechDetectionTests.

Synthesizes about 20 s of Japanese speech with pauses using macOS `say`, then
runs it through the original pipeline's VAD path: WhisperFeatureExtractor
(whisper-base, 80 mel) -> ONNX Runtime -> sigmoid.

Output (little-endian float32, no header):
    speech-samples.f32        16 kHz mono samples (< 30 s, one VAD window)
    speech-probabilities.f32  1500 per-20 ms speech probabilities

Usage:
    uv run --script make_vad_fixture.py MODEL_ONNX OUTPUT_DIR
"""

import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import onnxruntime
import soundfile
from transformers import WhisperFeatureExtractor

SAMPLE_RATE = 16_000
VOICE = "Kyoko"
SENTENCES = [
    "こんにちは。今日はいい天気ですね。",
    "少し休憩してから、また始めましょう。",
    "字幕のテストをしています。",
]
PAUSE_SECONDS = [1.5, 3.0, 0.5]


def synthesize(text: str, directory: Path) -> np.ndarray:
    path = directory / "speech.wav"
    subprocess.run(
        ["say", "-v", VOICE, "--file-format=WAVE", f"--data-format=LEF32@{SAMPLE_RATE}", "-o", str(path), text],
        check=True,
    )
    samples, rate = soundfile.read(path, dtype="float32")
    assert rate == SAMPLE_RATE, rate
    return samples


def make_speech() -> np.ndarray:
    parts = []
    with tempfile.TemporaryDirectory() as directory:
        for sentence, pause in zip(SENTENCES, PAUSE_SECONDS):
            parts.append(np.zeros(int(pause * SAMPLE_RATE), dtype=np.float32))
            parts.append(synthesize(sentence, Path(directory)))
    speech = np.concatenate(parts)
    assert len(speech) < 30 * SAMPLE_RATE, len(speech) / SAMPLE_RATE
    return speech


def main() -> None:
    model_path, output_dir = Path(sys.argv[1]), Path(sys.argv[2])
    speech = make_speech()

    extractor = WhisperFeatureExtractor(feature_size=80)
    features = extractor(speech, sampling_rate=SAMPLE_RATE, return_tensors="np").input_features
    session = onnxruntime.InferenceSession(str(model_path), providers=["CPUExecutionProvider"])
    logits = session.run(None, {session.get_inputs()[0].name: features})[0][0]
    probabilities = 1 / (1 + np.exp(-logits))

    output_dir.mkdir(parents=True, exist_ok=True)
    speech.astype("<f4").tofile(output_dir / "speech-samples.f32")
    probabilities.astype("<f4").tofile(output_dir / "speech-probabilities.f32")
    speech_frames = int((probabilities >= 0.5).sum())
    print(f"wrote {output_dir} ({len(speech) / SAMPLE_RATE:.1f} s, {speech_frames} frames >= 0.5)")


if __name__ == "__main__":
    main()
