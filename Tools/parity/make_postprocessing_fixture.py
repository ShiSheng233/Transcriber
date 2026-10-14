# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = []
# ///
"""Write reference cases for chunk planning and subtitle post-processing tests.

Extracts the original functions from ChickenRice's infer.py and runs them
unchanged:
  - create_contiguous_chunks (smart split of the audio into <= 30 s chunks)
  - enforce_segment_timeline + merge_segments + enforce_segment_timeline
    (the order infer.py applies them before writing subtitles)

Usage:
    uv run --script make_postprocessing_fixture.py INFER_PY CHUNK_CASES_JSON POSTPROCESSING_CASES_JSON
"""

import ast
import json
import random
import sys
from dataclasses import dataclass
from pathlib import Path

DEFINITIONS = [
    "Segment", "SpeechSpan", "AudioChunk", "SegmentMergeOptions",
    "_normalize_merge_text", "create_contiguous_chunks", "_max_segment_end",
    "enforce_segment_timeline", "merge_segments",
]
SAMPLE_RATE = 16_000


def load_original(infer_path: Path) -> dict:
    module = ast.parse(infer_path.read_text(encoding="utf-8"))
    wanted = [
        node for node in module.body
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in DEFINITIONS
    ]
    assert {node.name for node in wanted} == set(DEFINITIONS)
    namespace = {"dataclass": dataclass, "Any": object}
    exec(compile(ast.Module(body=wanted, type_ignores=[]), str(infer_path), "exec"), namespace)
    return namespace


def make_chunk_cases(original: dict, generator: random.Random) -> list:
    SpeechSpan = original["SpeechSpan"]
    create_contiguous_chunks = original["create_contiguous_chunks"]
    cases = []
    for index in range(40):
        total_samples = generator.choice([
            generator.randint(1, 30 * SAMPLE_RATE),          # fits in one chunk
            30 * SAMPLE_RATE,                                # exactly 30 s
            generator.randint(31 * SAMPLE_RATE, 1_800 * SAMPLE_RATE),
        ])
        spans_in_samples = []
        position = generator.randint(0, 5 * SAMPLE_RATE)
        while position < total_samples:
            length = generator.randint(SAMPLE_RATE // 10, 25 * SAMPLE_RATE)
            # VAD spans are multiples of 320 samples (one 20 ms frame).
            start = position // 320 * 320
            end = min(total_samples + 30 * SAMPLE_RATE, position + length) // 320 * 320
            if end > start:
                spans_in_samples.append((start, end))
            position = end + generator.choice([0, 320, 1_600, generator.randint(0, 6 * SAMPLE_RATE)])
        spans = [SpeechSpan(start / SAMPLE_RATE, end / SAMPLE_RATE) for start, end in spans_in_samples]
        total_duration = total_samples / SAMPLE_RATE
        chunks = create_contiguous_chunks(spans, 30.0, total_duration, 0.4)
        cases.append({
            "name": f"chunks-{index}",
            "total_samples": total_samples,
            "speech_spans": [{"start": start, "end": end} for start, end in spans_in_samples],
            "expected_chunks": [{"start": chunk.start, "end": chunk.end} for chunk in chunks],
        })
    return cases


TEXT_POOL = [
    "こんにちは", "こんにちは、元気？", "元気", "おはようございます", "  こんにちは  ",
    "我爱你", "我爱你，真的", "真的", "你好　世界", "你好 世界", "你好世界",
    "ok", "OK ok", " ", "", "　", "é", "é", "嗯", "嗯嗯", "嗯嗯嗯",
]


def make_segment_cases(original: dict, generator: random.Random) -> list:
    Segment = original["Segment"]
    SegmentMergeOptions = original["SegmentMergeOptions"]
    enforce = original["enforce_segment_timeline"]
    merge = original["merge_segments"]
    options = SegmentMergeOptions()
    cases = []
    for index in range(60):
        segments = []
        position = generator.randint(0, 5_000)
        for _ in range(generator.randint(0, 40)):
            start = position + generator.randint(-3_000, 4_000)
            end = start + generator.choice([0, generator.randint(-500, 25_000), generator.randint(100, 3_000)])
            segments.append(Segment(start=max(0, start), end=max(0, end), text=generator.choice(TEXT_POOL)))
            position = max(position, end)
        result = enforce(segments, options.max_duration_ms)
        result = merge(result, options)
        result = enforce(result, options.max_duration_ms)
        cases.append({
            "name": f"segments-{index}",
            "segments": [{"start": s.start, "end": s.end, "text": s.text} for s in segments],
            "expected": [{"start": s.start, "end": s.end, "text": s.text} for s in result],
        })
    return cases


def main() -> None:
    infer_path, chunk_cases_path, postprocessing_cases_path = map(Path, sys.argv[1:4])
    original = load_original(infer_path)
    generator = random.Random(11)

    chunk_cases = make_chunk_cases(original, generator)
    chunk_cases_path.parent.mkdir(parents=True, exist_ok=True)
    chunk_cases_path.write_text(json.dumps({"cases": chunk_cases}, separators=(",", ":")))

    segment_cases = make_segment_cases(original, generator)
    postprocessing_cases_path.parent.mkdir(parents=True, exist_ok=True)
    postprocessing_cases_path.write_text(
        json.dumps({"cases": segment_cases}, ensure_ascii=False, separators=(",", ":"))
    )
    print(f"wrote {len(chunk_cases)} chunk cases and {len(segment_cases)} post-processing cases")


if __name__ == "__main__":
    main()
