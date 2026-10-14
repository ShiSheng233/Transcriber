# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["av>=11,<16", "ctranslate2", "faster-whisper==1.2.1", "numpy>=1.24"]
# ///
"""Record faster-whisper's per-window decoding results, for comparing the Swift decoder.

Runs WhisperModel.transcribe with ChickenRice's decoding options and VAD off
(this compares decoding only), wrapping generate_with_fallback to record what
each 30 s window produced.

Usage:
    uv run --script capture_faster_whisper_windows.py CT2_MODEL_DIR SAMPLES_F32 TASK OUTPUT_JSON
    (SAMPLES_F32: raw little-endian float32, 16 kHz mono)
"""

import json
import sys
from pathlib import Path

import numpy as np
from faster_whisper import WhisperModel


def main() -> None:
    model_dir, samples_path, task, output_path = sys.argv[1:5]
    audio = np.fromfile(samples_path, dtype="<f4")
    model = WhisperModel(model_dir, device="cpu", compute_type="float32")

    windows = []
    original = model.generate_with_fallback

    def recording_generate_with_fallback(encoder_output, prompt, tokenizer, options):
        result, avg_logprob, temperature, compression_ratio = original(encoder_output, prompt, tokenizer, options)
        windows.append({
            "prompt": list(prompt),
            "tokens": list(result.sequences_ids[0]),
            "average_log_probability": avg_logprob,
            "no_speech_probability": result.no_speech_prob,
            "temperature": temperature,
            "compression_ratio": compression_ratio,
        })
        return result, avg_logprob, temperature, compression_ratio

    model.generate_with_fallback = recording_generate_with_fallback
    segments, _ = model.transcribe(
        audio, language="ja", task=task, beam_size=1, condition_on_previous_text=False,
        max_initial_timestamp=30, repetition_penalty=1.1, vad_filter=False,
    )
    segments = [{"start": s.start, "end": s.end, "text": s.text, "tokens": list(s.tokens)} for s in segments]

    Path(output_path).write_text(json.dumps({"windows": windows, "segments": segments}, ensure_ascii=False, indent=1))
    for window in windows:
        print(f"window: T={window['temperature']} avg={window['average_log_probability']:.4f} "
              f"no_speech={window['no_speech_probability']:.4f} tokens={window['tokens']}")
    for segment in segments:
        print(f"[{segment['start']:.2f} -> {segment['end']:.2f}] {segment['text']}")


if __name__ == "__main__":
    main()
