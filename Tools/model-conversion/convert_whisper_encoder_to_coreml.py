# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = [
#     "coremltools>=8.3",
#     "numpy>=1.24",
#     "openai-whisper==20250625",
#     "safetensors>=0.4",
#     "torch==2.7.*",  # newest version coremltools is tested against
# ]
# ///
"""Convert a Hugging Face Whisper checkpoint's audio encoder to Core ML, as
the `<model>-encoder.mlpackage` whisper.cpp runs instead of its Metal encoder.

Same model and I/O as whisper.cpp's models/convert-whisper-to-coreml.py
(openai-whisper's AudioEncoder, traced, ML Program):

    input:  logmel_data [1, n_mels, 3000]   30 s of log-mel
    output: output      [1, 1500, n_state]  encoder states

The weights are read from model.safetensors directly (HF names mapped to
openai-whisper's) instead of going through transformers. The result is
checked against the same encoder in PyTorch float32 on real-looking inputs and
the conversion fails if they drift apart.

Usage:
    uv run --script convert_whisper_encoder_to_coreml.py HF_MODEL_DIR OUTPUT_MLPACKAGE [--precision float16|float32]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import whisper.model
from safetensors.torch import load_file
from whisper.model import AudioEncoder

# Attention written out rather than torch's scaled_dot_product_attention,
# which coremltools does not convert reliably (as in whisper.cpp's script).
whisper.model.MultiHeadAttention.use_sdpa = False

INPUT_NAME = "logmel_data"
OUTPUT_NAME = "output"
FRAME_COUNT = 3000
# Log-mel features after Whisper's normalization lie in about [-1, 1.5].
FEATURE_RANGE = (-1.0, 1.5)
VALIDATION_SAMPLE_COUNT = 4
# float16 on the Neural Engine against float32 PyTorch. Recognition parity is
# measured separately (make ours / parity-report); this only catches a broken
# conversion.
MIN_COSINE_SIMILARITY = 0.999

# Hugging Face → openai-whisper parameter names, encoder only (the mapping
# whisper.cpp's convert-h5-to-coreml.py uses).
NAME_MAPPING = [
    ("model.encoder.", ""),
    ("embed_positions.weight", "positional_embedding"),
    ("layers.", "blocks."),
    (".self_attn.q_proj", ".attn.query"),
    (".self_attn.k_proj", ".attn.key"),
    (".self_attn.v_proj", ".attn.value"),
    (".self_attn.out_proj", ".attn.out"),
    (".self_attn_layer_norm", ".attn_ln"),
    (".fc1", ".mlp.0"),
    (".fc2", ".mlp.2"),
    (".final_layer_norm", ".mlp_ln"),
    ("layer_norm.", "ln_post."),
]


def load_encoder(model_dir: Path) -> tuple[AudioEncoder, dict]:
    config = json.loads((model_dir / "config.json").read_text())
    dims = {
        "n_mels": config["num_mel_bins"],
        "n_ctx": config["max_source_positions"],
        "n_state": config["d_model"],
        "n_head": config["encoder_attention_heads"],
        "n_layer": config["encoder_layers"],
    }
    encoder = AudioEncoder(**dims)

    weights = load_file(str(model_dir / "model.safetensors"))
    state = {}
    for name, tensor in weights.items():
        if not name.startswith("model.encoder."):
            continue
        for old, new in NAME_MAPPING:
            name = name.replace(old, new)
        state[name] = tensor.float()
    encoder.load_state_dict(state, strict=True)
    return encoder.eval(), dims


def make_validation_inputs(n_mels: int) -> list[torch.Tensor]:
    """Silence, a band of energy and noise, at feature scale."""
    generator = np.random.default_rng(seed=0)
    shape = (1, n_mels, FRAME_COUNT)
    silence = np.full(shape, FEATURE_RANGE[0], dtype=np.float32)
    band = silence.copy()
    band[:, 20:60, 500:2500] = 1.0
    noise = [
        generator.uniform(*FEATURE_RANGE, size=shape).astype(np.float32)
        for _ in range(VALIDATION_SAMPLE_COUNT - 2)
    ]
    return [torch.from_numpy(features) for features in [silence, band, *noise]]


def cosine_similarity(reference: np.ndarray, candidate: np.ndarray) -> float:
    reference = reference.ravel().astype(np.float64)
    candidate = candidate.ravel().astype(np.float64)
    return float(reference @ candidate / (np.linalg.norm(reference) * np.linalg.norm(candidate)))


def convert(model_dir: Path, output_path: Path, precision: str) -> dict:
    encoder, dims = load_encoder(model_dir)
    inputs = make_validation_inputs(dims["n_mels"])
    with torch.no_grad():
        reference = [encoder(features).numpy() for features in inputs]
        traced = torch.jit.trace(encoder, inputs[0])

    coreml_model = ct.convert(
        traced,
        inputs=[ct.TensorType(name=INPUT_NAME, shape=tuple(inputs[0].shape), dtype=np.float32)],
        outputs=[ct.TensorType(name=OUTPUT_NAME, dtype=np.float32)],
        convert_to="mlprogram",
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT16 if precision == "float16" else ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS15,
    )
    coreml_model.short_description = f"Whisper audio encoder of {model_dir.name}, for whisper.cpp"

    similarities = []
    largest_differences = []
    for features, expected in zip(inputs, reference):
        actual = coreml_model.predict({INPUT_NAME: features.numpy()})[OUTPUT_NAME]
        similarities.append(cosine_similarity(expected, actual))
        largest_differences.append(float(np.abs(expected - actual).max()))
    if min(similarities) < MIN_COSINE_SIMILARITY:
        raise SystemExit(f"error: Core ML encoder output drifts from PyTorch (cosine {min(similarities):.5f})")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    coreml_model.save(str(output_path))
    return {
        "source": model_dir.name,
        "precision": precision,
        "dimensions": dims,
        "min_cosine_similarity_coreml_vs_torch": min(similarities),
        "max_abs_difference_coreml_vs_torch": max(largest_differences),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("model_dir", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--precision", choices=["float16", "float32"], default="float16")
    arguments = parser.parse_args()

    report = convert(arguments.model_dir, arguments.output, arguments.precision)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
