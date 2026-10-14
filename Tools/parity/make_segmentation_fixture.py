# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["av>=11,<16", "faster-whisper==1.2.1"]
# ///
"""Write reference cases for timestamp segmentation, VAD time mapping and Python rounding.

Uses faster-whisper 1.2.1's own code:
  - WhisperModel._split_segments_by_timestamps on generated token sequences;
  - collect_chunks and SpeechTimestampsMap on generated speech spans;
  - Python's round(x, 2) on values that stress half-way cases.

Usage:
    uv run --script make_segmentation_fixture.py OUTPUT_JSON
"""

import json
import random
import sys
import types
from pathlib import Path

import numpy as np
from faster_whisper.transcribe import WhisperModel
from faster_whisper.vad import SpeechTimestampsMap, collect_chunks

TIMESTAMP_BEGIN = 50364
END_OF_TEXT = 50257
SAMPLE_RATE = 16_000


def split_cases(generator: random.Random) -> list:
    model = types.SimpleNamespace(time_precision=0.02, input_stride=2)
    tokenizer = types.SimpleNamespace(timestamp_begin=TIMESTAMP_BEGIN)
    cases = []
    for _ in range(300):
        tokens, position = [], generator.randint(0, 100)
        for _ in range(generator.randint(0, 6)):
            tokens.append(TIMESTAMP_BEGIN + position)
            tokens += [generator.randrange(END_OF_TEXT) for _ in range(generator.randint(0, 5))]
            position += generator.randint(0, 300)
            if generator.random() < 0.8:
                tokens.append(TIMESTAMP_BEGIN + min(position, 1500))
        if generator.random() < 0.3 and tokens:
            tokens = tokens[:-generator.randint(1, len(tokens))]
        seek = generator.choice([0, generator.randint(1, 5000)])
        segment_size = generator.randint(1, 3000)
        time_offset = seek * 0.01
        segments, new_seek, single_ending = WhisperModel._split_segments_by_timestamps(
            model, tokenizer, tokens, time_offset, segment_size, segment_size * 0.01, seek
        )
        cases.append({
            "tokens": tokens, "seek": seek, "segment_size": segment_size,
            "expected_segments": [{"start": s["start"], "end": s["end"], "tokens": s["tokens"]} for s in segments],
            "expected_seek": new_seek, "expected_single_timestamp_ending": single_ending,
        })
    return cases


def timeline_cases(generator: random.Random) -> list:
    cases = []
    for _ in range(100):
        spans, position = [], generator.randint(0, 3 * SAMPLE_RATE) // 320 * 320
        for _ in range(generator.randint(0, 8)):
            start = position
            end = start + generator.randint(1, 8 * SAMPLE_RATE) // 320 * 320
            spans.append({"start": start, "end": end})
            position = end + generator.randint(0, 3 * SAMPLE_RATE) // 320 * 320
        audio_length = (position + generator.randint(-SAMPLE_RATE, SAMPLE_RATE)) if spans else SAMPLE_RATE
        audio_length = max(1, audio_length)
        audio = np.arange(audio_length, dtype=np.float32)
        chunks, _ = collect_chunks(audio, spans)
        concatenated = np.concatenate(chunks)
        queries = []
        if spans:
            time_map = SpeechTimestampsMap(spans, SAMPLE_RATE)
            total = sum(s["end"] - s["start"] for s in spans) / SAMPLE_RATE
            times = [round(generator.uniform(0, total + 1), 2) for _ in range(20)]
            # Chunk ends in concatenated time exercise the is_end lookup.
            times += [end / SAMPLE_RATE for end in time_map.chunk_end_sample]
            for time in times:
                queries.append({
                    "time": time,
                    "start": time_map.get_original_time(time),
                    "end": time_map.get_original_time(time, is_end=True),
                })
        cases.append({
            "spans": spans, "audio_length": audio_length,
            "expected_source_ranges": source_ranges(concatenated.astype(int).tolist()),
            "queries": queries,
        })
    return cases


def source_ranges(source_indices: list) -> list:
    """Runs of consecutive source sample indices as [start, end) pairs."""
    ranges = []
    for index in source_indices:
        if ranges and ranges[-1][1] == index:
            ranges[-1][1] = index + 1
        else:
            ranges.append([index, index + 1])
    return ranges


def rounding_cases(generator: random.Random) -> list:
    values = [2.675, 0.125, 0.135, 1.005, 0.0, 12.345, 59.995, 3599.985]
    values += [generator.randint(0, 400_000) * 0.005 for _ in range(500)]
    values += [generator.randint(0, 3000) * 0.02 + generator.randint(0, 100) * 0.01 for _ in range(500)]
    return [{"value": value, "rounded": round(value, 2), "milliseconds": int(round(value * 1000))} for value in values]


def main() -> None:
    generator = random.Random(23)
    output = {
        "split_cases": split_cases(generator),
        "timeline_cases": timeline_cases(generator),
        "rounding_cases": rounding_cases(generator),
    }
    Path(sys.argv[1]).write_text(json.dumps(output, separators=(",", ":")))
    print(f"wrote {sys.argv[1]}: " + ", ".join(f"{len(v)} {k}" for k, v in output.items()))


if __name__ == "__main__":
    main()
