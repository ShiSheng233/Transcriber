# /// script
# requires-python = ">=3.9"
# ///
"""Check that a tokenizer.json has exactly the vocabulary of vocab.json + added_tokens.json.

Some checkpoints (e.g. litagin/anime-whisper) ship only the slow tokenizer
files. The Swift decoder reads tokenizer.json, so we borrow the one of the
model they were fine-tuned from, but only if it maps every token to the same id.

Usage:
    uv run --script check_tokenizer_vocabulary.py TOKENIZER_JSON VOCAB_JSON ADDED_TOKENS_JSON
"""

import json
import sys
from pathlib import Path


def main() -> None:
    tokenizer_path, vocab_path, added_path = map(Path, sys.argv[1:4])
    tokenizer = json.loads(tokenizer_path.read_text(encoding="utf-8"))
    expected = json.loads(vocab_path.read_text(encoding="utf-8"))
    expected.update(json.loads(added_path.read_text(encoding="utf-8")))

    actual = dict(tokenizer["model"]["vocab"])
    actual.update({token["content"]: token["id"] for token in tokenizer.get("added_tokens", [])})

    if actual != expected:
        missing = sorted(set(expected) - set(actual))[:5]
        extra = sorted(set(actual) - set(expected))[:5]
        moved = sorted(t for t in set(actual) & set(expected) if actual[t] != expected[t])[:5]
        sys.exit(f"error: vocabularies differ (missing {missing}, extra {extra}, different ids {moved})")
    print(f"{tokenizer_path}: {len(actual)} tokens, same ids as {vocab_path.name} + {added_path.name}")


if __name__ == "__main__":
    main()
