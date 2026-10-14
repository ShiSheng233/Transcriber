# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["numpy>=1.24"]
# ///
"""Write reference cases for SpeechSegmenterTests from the original VAD segmenter.

Extracts get_speech_timestamps_onnx from ChickenRice's vad_manager.py and runs
it unchanged on generated frame probabilities, feeding them through a stub
model so no ONNX model or audio is needed.

Probabilities are rounded to 3 decimals and stored as float32, so the JSON
values parse to exactly the floats the Python code compared.

Usage:
    uv run --script make_segmenter_fixture.py VAD_MANAGER_PY OUTPUT_JSON
"""

import ast
import json
import sys
from pathlib import Path
from typing import Callable

import numpy as np

FRAME_DURATION_MS = 20
FRAMES_PER_CHUNK = 1500
FUNCTION_NAME = "get_speech_timestamps_onnx"

# ChickenRice's generation_config.json5 values, and variants that exercise the
# maximum-duration cut, a long minimum silence and an explicit neg_threshold.
SETTINGS_VARIANTS = {
    "chickenrice": dict(threshold=0.5, neg_threshold=None, min_speech_duration_ms=300,
                        max_speech_duration_s=float("inf"), min_silence_duration_ms=100, speech_pad_ms=200),
    "max-duration": dict(threshold=0.5, neg_threshold=None, min_speech_duration_ms=300,
                         max_speech_duration_s=3.0, min_silence_duration_ms=100, speech_pad_ms=200),
    "long-silence": dict(threshold=0.4, neg_threshold=None, min_speech_duration_ms=250,
                         max_speech_duration_s=float("inf"), min_silence_duration_ms=2000, speech_pad_ms=400),
    "explicit-negative": dict(threshold=0.6, neg_threshold=0.2, min_speech_duration_ms=100,
                              max_speech_duration_s=float("inf"), min_silence_duration_ms=60, speech_pad_ms=30),
}


def load_original_function(vad_manager_path: Path) -> Callable:
    source = vad_manager_path.read_text(encoding="utf-8")
    module = ast.parse(source)
    function = next(node for node in module.body if isinstance(node, ast.FunctionDef) and node.name == FUNCTION_NAME)
    namespace = {"np": np, "Callable": Callable}
    exec(compile(ast.Module(body=[function], type_ignores=[]), str(vad_manager_path), "exec"), namespace)
    return namespace[FUNCTION_NAME]


class StubModel:
    """Stands in for WhisperVADOnnxWrapper: returns fixed frame probabilities."""

    frame_duration_ms = FRAME_DURATION_MS

    def __init__(self, probabilities: np.ndarray):
        self.probabilities = probabilities

    def reset_states(self) -> None:
        pass

    def audio_forward(self, audio: np.ndarray, sampling_rate: int) -> np.ndarray:
        return self.probabilities


def quantize(values: np.ndarray) -> np.ndarray:
    return np.round(np.clip(values, 0.0, 1.0), 3).astype(np.float32)


def make_probability_sequences() -> dict[str, np.ndarray]:
    generator = np.random.default_rng(seed=7)
    sequences = {}

    # Speech bursts of random length separated by gaps, with noise near the thresholds.
    for index in range(4):
        frame_count = FRAMES_PER_CHUNK * (index + 1)
        levels = np.zeros(frame_count)
        position = 0
        while position < frame_count:
            gap = int(generator.integers(2, 120))
            burst = int(generator.integers(3, 400))
            levels[position + gap : position + gap + burst] = generator.uniform(0.45, 0.95)
            position += gap + burst
        noise = generator.normal(0.0, 0.12, frame_count)
        sequences[f"bursts-{index}"] = quantize(levels + noise)

    # Exact threshold values: 0.5 starts speech (>=), 0.35 is not below neg_threshold.
    edges = np.zeros(400)
    edges[10:40] = 0.5
    edges[40:45] = 0.35
    edges[45:60] = 0.34
    edges[60:61] = 0.5
    edges[61:70] = 0.2
    edges[100:300] = 0.9
    edges[300:302] = 0.1
    edges[302:390] = 0.8
    sequences["threshold-edges"] = quantize(edges)

    # Speech running to the very last frame.
    trailing = np.zeros(FRAMES_PER_CHUNK)
    trailing[1400:] = 0.9
    sequences["trailing-speech"] = quantize(trailing)

    sequences["silence"] = quantize(np.zeros(FRAMES_PER_CHUNK))
    return sequences


def main() -> None:
    vad_manager_path, output_path = map(Path, sys.argv[1:3])
    get_speech_timestamps = load_original_function(vad_manager_path)

    cases = []
    for sequence_name, probabilities in make_probability_sequences().items():
        for settings_name, settings in SETTINGS_VARIANTS.items():
            spans = get_speech_timestamps(
                audio=np.zeros(1),
                model=StubModel(probabilities),
                sampling_rate=16_000,
                return_seconds=False,
                **settings,
            )
            cases.append({
                "name": f"{sequence_name}/{settings_name}",
                "settings": {key: (None if value == float("inf") else value) for key, value in settings.items()},
                "probabilities": [round(float(value), 3) for value in probabilities],
                "expected_spans": [{"start": int(span["start"]), "end": int(span["end"])} for span in spans],
            })

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps({"source_function": FUNCTION_NAME, "cases": cases}, separators=(",", ":")))
    print(f"wrote {output_path} ({len(cases)} cases)")


if __name__ == "__main__":
    main()
