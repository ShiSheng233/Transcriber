# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = []
# ///
"""Write reference subtitle files for SubtitleExportTests with the original SubWriter.

Extracts SubWriter and Segment from ChickenRice's infer.py and writes one
segment list as srt, vtt, lrc and txt. Files are written with newline="\\n"
so they compare byte for byte on any OS.

Usage:
    uv run --script make_subtitle_fixture.py INFER_PY OUTPUT_DIR
"""

import ast
import builtins
import json
import sys
from dataclasses import dataclass
from pathlib import Path

SEGMENTS = [
    (0, 1_234, "こんにちは"),
    (1_234, 5_009, "第二行：结束时间等于下一行开始"),
    (5_010, 9_999, "毫秒不是 10 的倍数"),
    (3_599_990, 3_600_010, "跨越一小时"),
    (6_000_000, 6_061_005, "超过 99 分钟的 LRC 分钟数"),
    (36_000_000, 36_000_500, "十小时"),
]


def load_original(infer_path: Path) -> dict:
    module = ast.parse(infer_path.read_text(encoding="utf-8"))
    wanted = [node for node in module.body if isinstance(node, ast.ClassDef) and node.name in {"Segment", "SubWriter"}]
    namespace = {"dataclass": dataclass}
    exec(compile(ast.Module(body=wanted, type_ignores=[]), str(infer_path), "exec"), namespace)
    return namespace


def main() -> None:
    infer_path, output_dir = Path(sys.argv[1]), Path(sys.argv[2])
    original = load_original(infer_path)
    segments = [original["Segment"](start, end, text) for start, end, text in SEGMENTS]
    output_dir.mkdir(parents=True, exist_ok=True)

    real_open = builtins.open
    builtins.open = lambda path, mode="r", **kwargs: real_open(path, mode, newline="\n", **kwargs)
    try:
        for format_name in ["srt", "vtt", "lrc", "txt"]:
            getattr(original["SubWriter"], format_name)(segments, str(output_dir / f"expected.{format_name}"))
    finally:
        builtins.open = real_open

    (output_dir / "segments.json").write_text(
        json.dumps([{"start": s, "end": e, "text": t} for s, e, t in SEGMENTS], ensure_ascii=False)
    )
    print(f"wrote {output_dir}")


if __name__ == "__main__":
    main()
