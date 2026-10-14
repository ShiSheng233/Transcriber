"""Convert a Hugging Face Whisper checkpoint to mlx-whisper's format at any dtype.

mlx-whisper's convert.py only offers float16 and float32 on its command line,
but its convert() works with any MLX dtype. This calls it with the requested
dtype (bfloat16 keeps ChickenRice at its trained precision) and saves the
result exactly as convert.py's main block does.

Run inside an environment with the pinned mlx-whisper (see the Makefile):
    python convert_whisper_to_mlx.py CONVERT_PY MODEL_DIR OUTPUT_DIR DTYPE
"""

import importlib.util
import json
import sys
from dataclasses import asdict
from pathlib import Path

import mlx.core as mx
from mlx.utils import tree_flatten


def load_converter(path: Path):
    spec = importlib.util.spec_from_file_location("mlx_whisper_convert", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> None:
    converter_path, model_dir, output_dir, dtype_name = sys.argv[1:5]
    converter = load_converter(Path(converter_path))
    model = converter.convert(model_dir, getattr(mx, dtype_name))

    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)
    mx.save_safetensors(str(output / "model.safetensors"), dict(tree_flatten(model.parameters())))
    config = asdict(model.dims)
    config["model_type"] = "whisper"
    (output / "config.json").write_text(json.dumps(config, indent=4))
    print(f"wrote {output} ({dtype_name})")


if __name__ == "__main__":
    main()
