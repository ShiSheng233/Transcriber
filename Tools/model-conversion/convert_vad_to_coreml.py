# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = [
#     "coremltools>=8.3",
#     "numpy>=1.24",
#     "onnx>=1.17",
#     "onnx2torch>=1.5.15",
#     "onnxruntime>=1.20",
#     "torch==2.7.*",  # newest version coremltools is tested against
# ]
# ///
"""Convert TransWithAI's Whisper-VAD-EncDec-ASMR ONNX model to Core ML.

coremltools no longer reads ONNX, so the model goes ONNX -> PyTorch (onnx2torch)
-> Core ML. Each step is checked against ONNX Runtime, which is what the
original ChickenRice pipeline runs:

    model input:  input_features [1, 80, 3000]  Whisper log-mel, 30 s of audio
    model output: logits         [1, 1500]      one per 20 ms frame; sigmoid -> probability

Usage:
    uv run --script convert_vad_to_coreml.py MODEL_ONNX OUTPUT_MLPACKAGE [--precision float16|float32]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import onnxruntime
import torch
from onnx2torch import convert as onnx_to_torch

INPUT_SHAPE = (1, 80, 3000)
INPUT_NAME = "input_features"
OUTPUT_NAME = "logits"
# Whisper log-mel features are scaled to roughly [-1, 1.5]; (x + 4) / 4 after
# clamping to max - 8 means values never go below about -1.
FEATURE_RANGE = (-1.0, 1.5)
VALIDATION_SAMPLE_COUNT = 8
# A probability error above this could flip a frame across the 0.5 / 0.35 thresholds.
MAX_PROBABILITY_ERROR = 0.01


def sigmoid(logits: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-logits))


def make_validation_inputs() -> list[np.ndarray]:
    """Silence, a constant tone-like band and random noise at feature scale."""
    generator = np.random.default_rng(seed=0)
    silence = np.full(INPUT_SHAPE, FEATURE_RANGE[0], dtype=np.float32)
    band = silence.copy()
    band[:, 10:30, 500:2500] = 1.0
    noise = [
        generator.uniform(*FEATURE_RANGE, size=INPUT_SHAPE).astype(np.float32)
        for _ in range(VALIDATION_SAMPLE_COUNT - 2)
    ]
    return [silence, band, *noise]


def clear_reshape_allowzero(model: onnx.ModelProto) -> int:
    """Set allowzero=0 on every Reshape, which onnx2torch requires.

    allowzero only changes behavior when a target shape contains 0. All target
    shapes here are constants or come from Shape of tensors with a fixed batch of
    1, so none contain 0; the ONNX-vs-PyTorch comparison below confirms it.
    """
    cleared = 0
    for node in model.graph.node:
        if node.op_type != "Reshape":
            continue
        for attribute in node.attribute:
            if attribute.name == "allowzero" and attribute.i == 1:
                attribute.i = 0
                cleared += 1
    return cleared


def run_onnx(session: onnxruntime.InferenceSession, features: np.ndarray) -> np.ndarray:
    input_name = session.get_inputs()[0].name
    return session.run(None, {input_name: features})[0]


def max_probability_error(reference_logits: list[np.ndarray], candidate_logits: list[np.ndarray]) -> float:
    return max(
        float(np.abs(sigmoid(reference) - sigmoid(candidate)).max())
        for reference, candidate in zip(reference_logits, candidate_logits)
    )


def convert(onnx_path: Path, output_path: Path, precision: str) -> dict:
    onnx_model = onnx.load(str(onnx_path))
    session = onnxruntime.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    inputs = make_validation_inputs()
    reference = [run_onnx(session, features) for features in inputs]

    clear_reshape_allowzero(onnx_model)
    torch_model = onnx_to_torch(onnx_model).eval()
    with torch.no_grad():
        torch_outputs = [torch_model(torch.from_numpy(features)).numpy() for features in inputs]
        traced_model = torch.jit.trace(torch_model, torch.from_numpy(inputs[0]))
    torch_error = max_probability_error(reference, torch_outputs)

    compute_precision = ct.precision.FLOAT16 if precision == "float16" else ct.precision.FLOAT32
    coreml_model = ct.convert(
        traced_model,
        inputs=[ct.TensorType(name=INPUT_NAME, shape=INPUT_SHAPE, dtype=np.float32)],
        outputs=[ct.TensorType(name=OUTPUT_NAME, dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=compute_precision,
        minimum_deployment_target=ct.target.macOS15,
    )
    coreml_model.short_description = "TransWithAI Whisper-VAD-EncDec-ASMR: per-20 ms speech logits for 30 s of audio"
    coreml_model.license = "MIT"
    coreml_outputs = [coreml_model.predict({INPUT_NAME: features})[OUTPUT_NAME] for features in inputs]
    coreml_error = max_probability_error(reference, coreml_outputs)

    if coreml_error > MAX_PROBABILITY_ERROR:
        raise SystemExit(f"error: Core ML probabilities differ from ONNX by {coreml_error:.4f}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    coreml_model.save(str(output_path))
    return {
        "source": onnx_path.name,
        "precision": precision,
        "max_probability_error_torch_vs_onnx": torch_error,
        "max_probability_error_coreml_vs_onnx": coreml_error,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("onnx_model", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--precision", choices=["float16", "float32"], default="float16")
    arguments = parser.parse_args()

    report = convert(arguments.onnx_model, arguments.output, arguments.precision)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
