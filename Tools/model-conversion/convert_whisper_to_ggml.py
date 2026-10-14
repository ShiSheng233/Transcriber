# /// script
# requires-python = ">=3.9"
# dependencies = ["numpy>=1.24"]
# ///
"""Convert a Hugging Face Whisper checkpoint (safetensors) to whisper.cpp's ggml format.

Writes the same file layout as whisper.cpp's models/convert-h5-to-ggml.py, with
three differences:

- Reads safetensors directly with NumPy (including bfloat16), so PyTorch and
  transformers are not needed.
- Small tensors that ggml keeps in float32 (biases, layer norms, positional
  embeddings) are written from the source values instead of being rounded
  through float16 first.
- Refuses checkpoints whose proj_out.weight differs from the token embedding.
  whisper.cpp always computes logits with the token embedding, so an untied
  proj_out cannot be represented and the official script drops it silently.

Usage:
    uv run --script convert_whisper_to_ggml.py MODEL_DIR MEL_FILTERS_NPZ OUTPUT_FILE
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path
from typing import BinaryIO, Dict, Tuple

import numpy as np

GGML_MAGIC = 0x67676D6C
GGML_FTYPE_FLOAT32 = 0
GGML_FTYPE_FLOAT16 = 1

# Hugging Face module names -> whisper.cpp tensor names, from convert-h5-to-ggml.py.
LAYER_MODULE_NAMES = {
    "self_attn.k_proj": "attn.key",
    "self_attn.q_proj": "attn.query",
    "self_attn.v_proj": "attn.value",
    "self_attn.out_proj": "attn.out",
    "self_attn_layer_norm": "attn_ln",
    "encoder_attn.q_proj": "cross_attn.query",
    "encoder_attn.k_proj": "cross_attn.key",
    "encoder_attn.v_proj": "cross_attn.value",
    "encoder_attn.out_proj": "cross_attn.out",
    "encoder_attn_layer_norm": "cross_attn_ln",
    "fc1": "mlp.0",
    "fc2": "mlp.2",
    "final_layer_norm": "mlp_ln",
}
TOP_LEVEL_NAMES = {
    "encoder.layer_norm.bias": "encoder.ln_post.bias",
    "encoder.layer_norm.weight": "encoder.ln_post.weight",
    "encoder.embed_positions.weight": "encoder.positional_embedding",
    "decoder.layer_norm.bias": "decoder.ln.bias",
    "decoder.layer_norm.weight": "decoder.ln.weight",
    "decoder.embed_positions.weight": "decoder.positional_embedding",
    "decoder.embed_tokens.weight": "decoder.token_embedding.weight",
}
CONV_BIAS_NAMES = {"encoder.conv1.bias", "encoder.conv2.bias"}
FLOAT32_TENSOR_NAMES = CONV_BIAS_NAMES | {
    "encoder.positional_embedding",
    "decoder.positional_embedding",
}
TOKEN_EMBEDDING = "model.decoder.embed_tokens.weight"
OUTPUT_PROJECTION = "proj_out.weight"


def read_safetensors(path: Path) -> Dict[str, np.ndarray]:
    """Map every tensor in a safetensors file to a float32 NumPy array."""
    with path.open("rb") as file:
        (header_size,) = struct.unpack("<Q", file.read(8))
        header = json.loads(file.read(header_size))
    header.pop("__metadata__", None)
    data_start = 8 + header_size
    raw = np.memmap(path, dtype=np.uint8, mode="r")

    tensors = {}
    for name, entry in header.items():
        begin, end = entry["data_offsets"]
        tensors[name] = decode_tensor(raw[data_start + begin : data_start + end], entry["dtype"], entry["shape"])
    return tensors


def decode_tensor(buffer: np.ndarray, dtype: str, shape: list) -> np.ndarray:
    if dtype == "F32":
        values = buffer.view(np.float32)
    elif dtype == "F16":
        values = buffer.view(np.float16).astype(np.float32)
    elif dtype == "BF16":
        # bfloat16 is the upper half of a float32.
        values = (buffer.view(np.uint16).astype(np.uint32) << 16).view(np.float32)
    else:
        raise ValueError(f"unsupported tensor dtype {dtype}")
    return values.reshape(shape)


def ggml_tensor_name(hf_name: str) -> str:
    """model.encoder.layers.3.self_attn.k_proj.weight -> encoder.blocks.3.attn.key.weight"""
    parts = hf_name.split(".")[1:]  # drop the leading "model."
    if parts[1] == "layers":
        stack, _, layer_index = parts[:3]
        module = ".".join(parts[3:-1])
        return ".".join([stack, "blocks", layer_index, LAYER_MODULE_NAMES[module], parts[-1]])
    short_name = ".".join(parts)
    return TOP_LEVEL_NAMES.get(short_name, short_name)


def require_tied_output_projection(tensors: Dict[str, np.ndarray]) -> None:
    projection = tensors.pop(OUTPUT_PROJECTION, None)
    if projection is None:
        return
    if not np.array_equal(projection, tensors[TOKEN_EMBEDDING]):
        sys.exit(f"error: {OUTPUT_PROJECTION} differs from {TOKEN_EMBEDDING}; whisper.cpp cannot represent it")


def bytes_to_unicode() -> Dict[int, str]:
    """GPT-2 byte <-> unicode table used by Whisper's vocab.json."""
    printable = (
        list(range(ord("!"), ord("~") + 1))
        + list(range(ord("¡"), ord("¬") + 1))
        + list(range(ord("®"), ord("ÿ") + 1))
    )
    characters = printable[:]
    extra = 0
    for byte in range(256):
        if byte not in printable:
            printable.append(byte)
            characters.append(256 + extra)
            extra += 1
    return dict(zip(printable, map(chr, characters)))


def write_header(file: BinaryIO, config: dict) -> None:
    # n_text_ctx: the official script reads max_length, which is null in some
    # fine-tunes; max_target_positions is the actual decoder context.
    fields = [
        GGML_MAGIC,
        config["vocab_size"],
        config["max_source_positions"],
        config["d_model"],
        config["encoder_attention_heads"],
        config["encoder_layers"],
        config["max_target_positions"],
        config["d_model"],
        config["decoder_attention_heads"],
        config["decoder_layers"],
        config["num_mel_bins"],
        GGML_FTYPE_FLOAT16,
    ]
    file.write(struct.pack(f"{len(fields)}i", *fields))


def write_mel_filters(file: BinaryIO, filters: np.ndarray) -> None:
    file.write(struct.pack("ii", *filters.shape))
    file.write(filters.astype(np.float32).tobytes())


def write_vocabulary(file: BinaryIO, vocabulary: Dict[str, int]) -> None:
    byte_decoder = {character: byte for byte, character in bytes_to_unicode().items()}
    file.write(struct.pack("i", len(vocabulary)))
    for token, _ in sorted(vocabulary.items(), key=lambda item: item[1]):
        text = bytes(byte_decoder[character] for character in token)
        file.write(struct.pack("i", len(text)))
        file.write(text)


def write_tensor(file: BinaryIO, name: str, values: np.ndarray) -> None:
    values = values.squeeze()
    if name in CONV_BIAS_NAMES:
        values = values.reshape(values.shape[0], 1)

    keep_float32 = values.ndim < 2 or name in FLOAT32_TENSOR_NAMES
    if keep_float32:
        data, ftype = values.astype(np.float32), GGML_FTYPE_FLOAT32
    else:
        data, ftype = values.astype(np.float16), GGML_FTYPE_FLOAT16
        if not np.isfinite(data).all():
            sys.exit(f"error: {name} overflows float16")

    encoded_name = name.encode("utf-8")
    file.write(struct.pack("iii", data.ndim, len(encoded_name), ftype))
    file.write(struct.pack(f"{data.ndim}i", *reversed(data.shape)))
    file.write(encoded_name)
    file.write(np.ascontiguousarray(data).tobytes())


def convert(model_dir: Path, mel_filters_path: Path, output_path: Path) -> Tuple[int, int]:
    config = json.loads((model_dir / "config.json").read_text(encoding="utf-8"))
    vocabulary = json.loads((model_dir / "vocab.json").read_text(encoding="utf-8"))
    mel_band_count = config["num_mel_bins"]
    with np.load(mel_filters_path) as filters_archive:
        mel_filters = filters_archive[f"mel_{mel_band_count}"]

    tensors = read_safetensors(model_dir / "model.safetensors")
    require_tied_output_projection(tensors)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    partial_path = output_path.with_suffix(output_path.suffix + ".partial")
    with partial_path.open("wb") as file:
        write_header(file, config)
        write_mel_filters(file, mel_filters)
        write_vocabulary(file, vocabulary)
        for hf_name, values in tensors.items():
            write_tensor(file, ggml_tensor_name(hf_name), values)
    partial_path.rename(output_path)
    return len(tensors), mel_band_count


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    model_dir, mel_filters_path, output_path = map(Path, sys.argv[1:])
    tensor_count, mel_band_count = convert(model_dir, mel_filters_path, output_path)
    print(f"wrote {output_path} ({tensor_count} tensors, {mel_band_count} mel bands)")


if __name__ == "__main__":
    main()
