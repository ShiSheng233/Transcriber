# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["av>=11,<16", "faster-whisper==1.2.1"]
# ///
"""Write reference tokenizer data for WhisperDecodingTests with faster-whisper's Tokenizer.

For each model's tokenizer.json (the one shipped with its CTranslate2 model):
  - special token ids as faster-whisper looks them up (Japanese, translate/transcribe);
  - the suppressed tokens for suppress_tokens=[-1] (get_suppressed_tokens);
  - decoding cases: random token sequences below <|endoftext|>, including ones
    that cut multi-byte characters, decoded by tokenizers (lossy UTF-8).

Usage:
    uv run --script make_tokenizer_fixture.py OUTPUT_JSON NAME=TOKENIZER_JSON...
"""

import json
import random
import sys
from pathlib import Path

import tokenizers
from faster_whisper.tokenizer import Tokenizer
from faster_whisper.transcribe import get_suppressed_tokens

DECODE_CASE_COUNT = 200
SAMPLE_TEXTS = ["こんにちは、今日はいい天気ですね。", "我爱你，真的！", "♪♪ 字幕 (笑) 「はい」", "Hello -- 'world'"]


def describe(name: str, tokenizer_path: Path, generator: random.Random) -> dict:
    hf_tokenizer = tokenizers.Tokenizer.from_file(str(tokenizer_path))
    tokenizer = Tokenizer(hf_tokenizer, multilingual=True, task="translate", language="ja")
    specials = {
        "sot": tokenizer.sot,
        "eot": tokenizer.eot,
        "japanese": tokenizer.language,
        "translate": tokenizer.translate,
        "transcribe": tokenizer.transcribe,
        "sot_prev": tokenizer.sot_prev,
        "sot_lm": tokenizer.sot_lm,
        "no_speech": tokenizer.no_speech,
        "no_timestamps": tokenizer.no_timestamps,
        "timestamp_begin": tokenizer.timestamp_begin,
        "vocabulary_size": hf_tokenizer.get_vocab_size(),
    }

    cases = []
    for text in SAMPLE_TEXTS:
        tokens = tokenizer.encode(text)
        cases.append({"tokens": tokens, "text": tokenizer.decode(tokens)})
        cases.append({"tokens": tokens[1:], "text": tokenizer.decode(tokens[1:])})
    for _ in range(DECODE_CASE_COUNT):
        tokens = [generator.randrange(tokenizer.eot) for _ in range(generator.randint(0, 12))]
        cases.append({"tokens": tokens, "text": tokenizer.decode(tokens)})

    return {
        "name": name,
        "specials": specials,
        "non_speech_tokens": list(tokenizer.non_speech_tokens),
        "suppressed_tokens": list(get_suppressed_tokens(tokenizer, [-1])),
        "decode_cases": cases,
    }


def main() -> None:
    output_path = Path(sys.argv[1])
    generator = random.Random(5)
    models = []
    for argument in sys.argv[2:]:
        name, path = argument.split("=", 1)
        models.append(describe(name, Path(path), generator))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps({"models": models}, ensure_ascii=False, separators=(",", ":")))
    print(f"wrote {output_path}: " + ", ".join(f"{m['name']} ({len(m['suppressed_tokens'])} suppressed)" for m in models))


if __name__ == "__main__":
    main()
