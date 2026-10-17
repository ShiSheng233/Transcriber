# Model configurations

Each installed model is a folder in the models folder:

```
Models/
  <id>/
    model.json        this configuration
    ggml.bin          whisper.cpp weights
    tokenizer.json    Hugging Face tokenizer
    mlx/              mlx-whisper weights (optional)
  vad/                shared VAD models
```

`make whisper-models mlx-models` copies `<id>.json` here to `Models/<id>/model.json`.
The app lists every folder with a `model.json`; nothing about a model is built in.

Required keys: `id`, `name`, `language` (Whisper language code), `task`
(`translate` or `transcribe`: the Whisper task token the model was trained
with) and `llm_mode` (`polish` the output, or `translate` it to the user's
language). Optional: `summary`, `source`, `license`, `files`, and the sections
below. Anything left out takes the original ChickenRice pipeline's value
(`ChickenRiceDefaults.swift`).

```json
"files":    { "whisper_cpp": "ggml.bin", "mlx": "mlx", "tokenizer": "tokenizer.json" },
"whisper_cpp": { "encoder": "coreml" },
"decoding": { "temperatures": [0.0, 0.2], "compression_ratio_threshold": 2.4,
              "log_prob_threshold": -1.0, "no_speech_threshold": 0.6, "best_of": 5,
              "repetition_penalty": 1.0, "suppress_blank": true,
              "max_initial_timestamp": 1.0, "max_new_tokens": null },
"vad":      { "model": "whisper-vad-asmr", "threshold": 0.5, "neg_threshold": 0.35,
              "min_speech_duration_ms": 250, "max_speech_duration_s": 30,
              "min_silence_duration_ms": 100, "speech_pad_ms": 30 },
"chunking": { "enabled": true, "target_chunk_duration_s": 30, "split_window_factor": 0.8 },
"merge":    { "enabled": true, "max_gap_ms": 500, "max_duration_ms": 2000 },
"segmentation": { "mode": "chunks" },
"cleanup":  { "drop_ellipsis_only": false, "collapse_repeats": false, "append_period": false }
```

Text-only models (trained without timestamp tokens, e.g. anime-whisper) set
`"decoding": { "timestamps": false }` and `"segmentation": { "mode": "vad_groups" }`:
neighbouring VAD spans closer than `group_gap_ms` are grouped up to
`group_max_ms`, each group is decoded alone after `leading_silence_ms` of
silence, and becomes one subtitle timed by the VAD. `no_repeat_ngram_size`
blocks repeated n-grams (0 = off). `"no_speech_threshold": 1.0` never treats a
piece as silence. See `anime-whisper.json`, which follows WhisperJAV's
ChronosJAV pipeline ("balanced" settings).

`whisper_cpp.encoder` is `metal` (default) or `coreml`: whisper.cpp then runs
the encoder through Core ML (Neural Engine) from `ggml-encoder.mlmodelc` next
to the weights (`make coreml-encoders`), and on Metal when that file is
missing. Set it only after measuring recognition parity: the Neural Engine
computes in float16.

The values above are examples of the format; see `ChickenRiceDefaults.swift`
for the actual defaults.
