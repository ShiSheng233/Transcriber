# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["sacrebleu>=2.4"]
# ///
"""Compare our subtitles with the original's (baseline A) and print a parity report.

For every SRT under BASELINE_DIR with a counterpart (same file name) under
OURS_DIR:
  - CER of the whole text (whitespace and punctuation removed), via edit distance;
  - character-level BLEU (sacrebleu, tokenize="char");
  - segments matched by time overlap (IoU >= 0.3): mean start/end offset,
    and how many baseline segments are missing or extra on our side.

Usage:
    uv run --script compare_subtitles.py BASELINE_DIR OURS_DIR
"""

import re
import sys
import unicodedata
from pathlib import Path

import sacrebleu

MATCH_IOU = 0.3
TIME_PATTERN = re.compile(r"(\d+):(\d+):(\d+),(\d+) --> (\d+):(\d+):(\d+),(\d+)")


def read_srt(path: Path) -> list[tuple[int, int, str]]:
    segments = []
    for block in path.read_text(encoding="utf-8").strip().split("\n\n"):
        lines = block.splitlines()
        match = next((TIME_PATTERN.match(line) for line in lines if TIME_PATTERN.match(line)), None)
        if not match:
            continue
        h1, m1, s1, ms1, h2, m2, s2, ms2 = map(int, match.groups())
        start = ((h1 * 60 + m1) * 60 + s1) * 1000 + ms1
        end = ((h2 * 60 + m2) * 60 + s2) * 1000 + ms2
        text = " ".join(line for line in lines[lines.index(match.string) + 1:])
        segments.append((start, end, text))
    return segments


def normalized(text: str) -> str:
    return "".join(c for c in text if not c.isspace() and not unicodedata.category(c).startswith("P"))


def edit_distance(a: str, b: str) -> int:
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def iou(a: tuple, b: tuple) -> float:
    overlap = max(0, min(a[1], b[1]) - max(a[0], b[0]))
    union = max(a[1], b[1]) - min(a[0], b[0])
    return overlap / union if union > 0 else 0.0


def compare(baseline: list, ours: list) -> dict:
    reference = normalized("".join(s[2] for s in baseline))
    hypothesis = normalized("".join(s[2] for s in ours))
    cer = edit_distance(reference, hypothesis) / max(len(reference), 1)
    bleu = sacrebleu.corpus_bleu([hypothesis], [[reference]], tokenize="char").score

    start_offsets, end_offsets, missing = [], [], 0
    matched_ours = set()
    for segment in baseline:
        best = max(range(len(ours)), key=lambda i: iou(segment, ours[i]), default=None)
        if best is None or iou(segment, ours[best]) < MATCH_IOU:
            missing += 1
            continue
        matched_ours.add(best)
        start_offsets.append(abs(segment[0] - ours[best][0]))
        end_offsets.append(abs(segment[1] - ours[best][1]))
    mean = lambda values: sum(values) / len(values) if values else 0.0
    return {
        "segments": (len(baseline), len(ours)),
        "cer": cer, "bleu": bleu,
        "start_offset_ms": mean(start_offsets), "end_offset_ms": mean(end_offsets),
        "missing": missing, "extra": len(ours) - len(matched_ours),
    }


def main() -> None:
    baseline_dir, ours_dir = Path(sys.argv[1]), Path(sys.argv[2])
    ours_by_name = {path.name: path for path in ours_dir.rglob("*.srt")}
    print(f"{'file':40} {'segs (A/ours)':>14} {'CER':>7} {'BLEU':>6} {'Δstart':>7} {'Δend':>7} {'miss':>5} {'extra':>5}")
    for baseline_path in sorted(baseline_dir.rglob("*.srt")):
        ours_path = ours_by_name.get(baseline_path.name)
        if ours_path is None:
            print(f"{baseline_path.name:40} (no output of ours)")
            continue
        r = compare(read_srt(baseline_path), read_srt(ours_path))
        print(f"{baseline_path.name[:40]:40} {r['segments'][0]:>6}/{r['segments'][1]:<7} {r['cer']:>7.2%} {r['bleu']:>6.1f} "
              f"{r['start_offset_ms']:>5.0f}ms {r['end_offset_ms']:>5.0f}ms {r['missing']:>5} {r['extra']:>5}")


if __name__ == "__main__":
    main()
