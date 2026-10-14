# Transcriber 架构设计

macOS 原生字幕生成工具。把 [Faster-Whisper-TransWithAI-ChickenRice](https://github.com/TransWithAI/Faster-Whisper-TransWithAI-ChickenRice) v1.10 的推理链路移植到 Apple Silicon：Whisper 由 whisper.cpp（Metal）或 MLX 运行，Core ML 跑 VAD，解码逻辑和其余链路用 Swift 重写；末端增加 OpenRouter LLM 润色/翻译。

## 1. 已确定的决策

| 项目 | 决定 |
| --- | --- |
| UI 框架 | AppKit（NSViewController / NSView），MVVM |
| 最低系统 | macOS 15 |
| 分发 | Developer ID 签名 + 公证，直接下载，Sparkle 更新，**不开沙盒** |
| 识别引擎 | **两个后端：whisper.cpp（Metal）与 MLX（参考 mlx-whisper）**。后端只负责编码和单步解码；与 CTranslate2 / faster-whisper 等价的解码逻辑在 Swift 中只写一份，两个后端共用（见 §5.1）。默认后端由 Phase 0 的实测决定 |
| VAD | **TransWithAI ASMR VAD 转 Core ML**；不使用 whisper.cpp 自带的 Silero VAD |
| 链路 | 媒体解码、VAD、智能切块、语音拼接、时间戳映射、逐步 logits 处理、温度回退、分段、后处理全部在 Swift 中实现；后端只做张量计算 |
| 模型 | **App 不内置模型**。我们自己转换（ggml、MLX、Core ML）并单独分发；App 下载到用户指定的模型目录。现阶段不公开，转换产物放在本仓库的 `Models/`（已 gitignore） |
| 目标硬件 | 高端 Mac 优先，**模型保持原精度（f16），默认不量化**；量化目标保留在 Makefile 中但不构建。开发与性能基线机：**M5 Max / 64GB** |
| 移植策略 | 默认行为与原项目一致，可选改进项单独开关；用对拍集量化验证（见 §9） |
| LLM | OpenRouter，两种模式：A 润色海南鸡中文输出 / B 日文转写 → 翻译到任意语言 |
| 首版范围 | 批处理队列 + 进度 + 视频/音频与字幕对照预览 + 导出 |

> Xcode 工程已改为 AppKit、macOS 15、无沙盒（Phase 0 第 1 步）。

## 2. 代码清晰度约定（Code Clarity）

这些规则优先于个人习惯，Code Review 以此为准。

1. **名字说明意图和单位。** `SpeechSegment`、`startSample`、`durationSeconds`，不写 `seg`、`t`、`ms`。跨模块传递时间统一用 `AudioTime`（见 §4），不传裸 `Int` 毫秒或裸采样数。
2. **一个文件一个主类型，文件名 = 类型名。** 扩展按职责拆为 `Type+Purpose.swift`。
3. **没有魔法数字。** 原项目的每个参数都放进 `ChickenRiceDefaults`，注释写明出处（文件与行）。算法代码只读配置。
4. **算法写成纯函数。** VAD 分段、智能切块、时间轴修正、合并规则等不持有状态、不做 I/O，输入输出都是值类型，可直接单元测试。
5. **依赖从 `init` 注入。** 模块边界用协议；模块内部没有第二个实现时不为了抽象而抽象。
6. **分层单向依赖。** View → ViewModel → Service → Domain。下层不 import 上层；Domain 与 Service 不 import AppKit。
7. **并发规则显式。** ViewModel 是 `@MainActor`；重计算放在 actor 或 `nonisolated` 函数里；所有长任务支持 `Task` 取消并定期 `try Task.checkCancellation()`。
8. **错误类型化。** 每个模块定义自己的 `Error` enum；转成用户可读文字只在 ViewModel 做。
9. **注释解释“为什么”。** 尤其是为了与原项目一致而保留的怪异行为（例如 `max_initial_ts = 30`），必须注明原因。
10. **C 互操作集中封装。** 所有 `whisper_*` 调用、指针与回调只出现在 `WhisperCpp` 模块内部，对外只暴露 Swift 值类型。
11. **不强制解包、不用隐式全局状态。** 测试代码除外。

## 3. 分层总览

```
┌──────────────────────── App target (Transcriber) ────────────────────────┐
│ View        NSWindowController / NSViewController / NSView               │
│               只负责布局、把用户操作转发给 ViewModel、渲染 ViewModel 状态   │
│ ViewModel   @Observable @MainActor final class                           │
│               持有界面状态，暴露 intent 方法，调用 Service，不 import AppKit │
│ Composition AppEnvironment：创建并注入全部 Service                        │
└──────────────────────────────────────────────────────────────────────────┘
                 │ 只依赖协议
┌──────────────────────── TranscriberKit (Swift Package) ──────────────────┐
│ Service     Pipeline、Recognizer、VAD、ModelStore、JobQueue、LLM、Export  │
│ Domain      值类型：AudioTime、SpeechSpan、Subtitle、Job、各种 Settings     │
└──────────────────────────────────────────────────────────────────────────┘
```

### 3.1 MVVM 在 AppKit 中的落地

- **Model**：TranscriberKit 中的 Domain 值类型与 Service。
- **ViewModel**：`@Observable`（Observation 框架）。只暴露两类成员：
  - 只读状态：`private(set) var`
  - 用户意图：动词命名的方法，例如 `addFiles(_:)`、`startQueue()`、`cancel(jobID:)`
- **View**：通过一个小工具 `ObservationBinder` 订阅 ViewModel。它封装 `withObservationTracking`，状态变化时在主线程回调 `render()`。View 不直接修改 ViewModel 的状态。
- **导航**：由 `MainWindowController` 负责组装子 ViewController 并注入各自的 ViewModel，ViewModel 之间不互相持有。

```swift
// View 侧的标准形态
final class JobQueueViewController: NSViewController {
    private let viewModel: JobQueueViewModel
    private var binder: ObservationBinder?

    init(viewModel: JobQueueViewModel) { ... }

    override func viewDidLoad() {
        super.viewDidLoad()
        binder = ObservationBinder { [weak self] in self?.render() }
    }

    private func render() {
        tableView.reloadData()                     // 读 viewModel.rows
        startButton.isEnabled = viewModel.canStart
    }

    @objc private func startButtonClicked(_ sender: NSButton) {
        viewModel.startQueue()
    }
}
```

## 4. Domain（TranscriberCore）

只有值类型，全部 `Sendable`、`Equatable`，必要时 `Codable`。

| 类型 | 说明 |
| --- | --- |
| `AudioTime` | 以 16 kHz 采样数为内部单位，提供 `seconds`、`init(seconds:)`；避免毫秒/帧/采样混用 |
| `AudioBuffer` | 16 kHz 单声道 `[Float]` 加时长 |
| `SpeechSpan` | VAD 输出的语音区间（start/end: `AudioTime`） |
| `AudioChunk` | 智能切块结果：区间 + 在原音频中的偏移 |
| `SpeechTimeline` | 内层 VAD 拼接后的“紧凑时间 → 原始时间”映射（对应 faster-whisper `SpeechTimestampsMap`） |
| `TranscriptSegment` | 识别输出：区间、文本、avgLogProb、compressionRatio、noSpeechProb、temperature |
| `Subtitle` / `SubtitleTrack` | 最终字幕条目（带稳定 `id`，供 LLM 对齐）与整条轨道 |
| `TranscriptionTask` | `.translateToChinese`（海南鸡）或 `.transcribeJapanese` |
| `VADSettings`、`ChunkingSettings`、`DecodingSettings`、`MergeSettings` | 对应 `generation_config.json5` 的结构化配置 |
| `ChickenRiceDefaults` | 上述 Settings 的原项目默认值，逐项注明出处 |
| `Job` / `JobStatus` | 队列任务与状态机（见 §7） |

## 5. Service 模块（TranscriberKit 内的 target）

每个模块对外只暴露一个入口协议和它需要的 Domain 类型。

| 模块 | 入口 | 职责 | 对应原项目 |
| --- | --- | --- | --- |
| `MediaDecoding` | `MediaDecoder` | FFmpeg 解码并用 libswresample 转 16 kHz mono s16 → float（见 §5.5） | `decode_audio` |
| `AudioFeatures` | `LogMelSpectrogram` | vDSP 实现 Whisper 前端：VAD 用的 HF `WhisperFeatureExtractor` 版本，以及识别用的 faster-whisper `FeatureExtractor` 版本（填充与归一化范围不同） | `WhisperFeatureExtractor`, `feature_extractor.py` |
| `SpeechDetection` | `VoiceActivityDetector` | Core ML 跑 ASMR VAD；`SpeechSegmenter` 是纯函数，实现带滞回的阈值分段 | `vad_manager.py` |
| `WhisperDecoding` | `WhisperBackend`（协议）、`WindowTranscriber` | 与后端无关的解码：prompt、no_speech、逐步 logits 处理、采样、温度回退、时间戳分段、seek 循环、分词器（见 §5.1–5.3） | CTranslate2 `whisper.cc` / `decoding.cc` + faster-whisper `transcribe.py` |
| `WhisperCpp` | 实现 `WhisperBackend` | whisper.cpp 低层 API：`set_mel` / `encode` / `decode`；多个 `whisper_state` 并行处理不同 chunk | — |
| `WhisperMLX` | 实现 `WhisperBackend` | mlx-swift 上的 Whisper 模型，原生 batch 维度：多个 chunk、best_of 的多条假设一次前向 | — |
| `TranscriptionPipeline` | `TranscriptionPipeline` | 编排：解码 → 外层 VAD → 智能切块 → 内层 VAD 拼接 → 识别 → 时间映射 → 后处理；用 `AsyncThrowingStream<PipelineEvent>` 报告进度 | `infer.py` |
| `SubtitlePostProcessing` | 纯函数集合 | `SegmentTimeline`、`SegmentMerger` | `enforce_segment_timeline`, `merge_segments` |
| `LLMTranslation` | `SubtitleTranslator` | OpenRouter 客户端；模式 A 润色、模式 B 翻译；JSON Schema 保证按 `id` 一一返回；滑动窗口携带上下文；术语表 | 新增 |
| `SubtitleExport` | `SubtitleRenderer` | SRT / VTT（修正为 `WEBVTT` 头）/ LRC / ASS / TXT | `SubWriter` |
| `ModelStore` | `ModelStore` | 模型目录管理：下载（断点续传、校验 SHA-256）、导入、删除、编译 Core ML | `download_models.py` |
| `JobQueue` | `JobQueue`（actor） | 调度 Job，支持取消与重试，向外发布状态快照 | 批处理循环 |

### 5.1 识别：一份解码逻辑，两个后端

调研结论（faster-whisper v1.2.1、CTranslate2 v4.8.3、whisper.cpp v1.9.5 源码逐行对照）：whisper.cpp 的 `whisper_full` 即使调整全部参数，仍有 7 处行为无法与 faster-whisper 对齐（no_speech 的计算位置、带温度的时间戳概率规则、avg_logprob 的算法、224 步上限、接近音频末尾提前停止、分段与 seek 规则等）。因此**不用 `whisper_full`，在 Swift 里自己写解码循环**，后端只提供张量计算：

```swift
protocol WhisperBackend {
    var configuration: WhisperModelConfiguration { get }   // 层数、mel 数、词表、特殊 token
    /// 编码一批 30 s 窗口（每个 [melBands x 3000]）。
    func encode(_ windows: [LogMelFeatures]) async throws -> EncodedAudioBatch
    /// 每条序列追加若干 token，返回各序列最后一个位置的 logits；KV 缓存由后端管理，可回退到前缀。
    func decode(_ step: DecodeStep, audio: EncodedAudioBatch) async throws -> [[Float]]
}
```

```
WhisperDecoding/
├─ Tokenization/   WhisperTokenizer（HF tokenizer.json，字节级解码，特殊 token），NonSpeechTokens（faster-whisper 的抑制列表）
├─ Logits/         LogitsProcessor 协议；RepetitionPenalty、SuppressTokens、SuppressBlank、TimestampRules（CTranslate2 版本）
├─ Sampling/       GreedySampler、TemperatureSampler（全词表）
├─ DecodingTask    一个窗口：SOT 处的 no_speech、prompt、最多 224 步、best_of
├─ FallbackDecoder generate_with_fallback：温度序列、压缩比（zlib 格式）、avg_logprob、无语音判定
├─ SegmentSplitter _split_segments_by_timestamps
├─ WindowSeeker    seek 循环（30 s 窗口、末尾短窗口、无语音跳过）
└─ SpeechTimeline  内层 VAD 拼接后的时间映射（SpeechTimestampsMap）
```

**后端对比：**

| | whisper.cpp（`WhisperCpp`） | MLX（`WhisperMLX`） |
| --- | --- | --- |
| 模型格式 | ggml f16 | MLX safetensors f16（mlx-whisper `convert.py` 的 `hf_to_pt` 路径） |
| 并行方式 | 多个 `whisper_state` 共享权重，各自解码一个 chunk | batch 维度：N 个 chunk（以及 best_of 的 5 条假设）一次前向，权重读一次服务 N 条序列 |
| 解码阶段瓶颈 | 内存带宽，并发 state 只能部分缓解 | 内存带宽，batch 直接摊薄，理论上更适合高端 Mac |
| Core ML 编码器 | 可选（用户开关，§5.4） | 无 |
| 成熟度 | 高 | Swift 侧需自己移植模型，或评估 mlx-audio-swift 的 `MLXAudioSTT` Whisper（需读源码确认能否加载本地微调模型、返回段级时间戳、支持 batch） |

### 5.2 以 CTranslate2 为准，以 mlx-whisper 为结构参考

mlx-whisper 是 OpenAI `whisper/decoding.py`、`transcribe.py` 的近乎逐行移植（约 3300 行 Python），`LogitFilter`（输入 logits 与已生成 token，输出修改后的 logits）的抽象很干净，Swift 的 `LogitsProcessor` 照它的结构写。但原项目跑的是 CTranslate2，**行为以 CTranslate2 为准**，与 OpenAI/mlx-whisper 的已知差异：

| 行为 | CTranslate2 / faster-whisper（目标） | OpenAI / mlx-whisper |
| --- | --- | --- |
| 重复惩罚 | 1.1，作用于本次生成的 token（含时间戳 token，不含 prompt），对原始 logits，每个 id 只惩罚一次 | 无 |
| 每步处理顺序 | 惩罚 → 抑制列表 → 首步抑制（220、EOT）→ 时间戳规则 → 屏蔽 → log_softmax → 采样 | 相同思路，无惩罚 |
| 时间戳概率规则 | 用未除以温度的 logits；首步、时间戳成对之后不检查 | 同样用原始 logits |
| `max_initial_timestamp=30` | 索引 1500，相当于不限制 | 同 |
| 抑制列表 | `non_speech_tokens` + transcribe/translate/sot/sot_prev/sot_lm/no_speech；语言 token 不抑制 | 同一来源 |
| no_speech_prob | SOT 位置的原始 logits softmax | 同 |
| 分数与 avg_logprob | 未除温度的 log 概率，含 EOT 求和；`avg = sum / (len + 1)`，len 不含 EOT | `sum / len`，选择假设时用长度惩罚 |
| best_of | 温度 > 0 时 5 条全词表采样，取归一化分数最高者 | 同思路 |
| 最大长度 | 224 步 | 224 |
| 回退失败时 | 在压缩比合格的结果中取 avg_logprob 最高者 | 取最后一次 |

### 5.3 两个后端的 Phase 0 风险

- **whisper.cpp：** 低层 `whisper_decode_with_state` 只用 seq 0；best_of 的 5 条假设需要回退 KV 缓存逐条跑。若开销太大，考虑多 state。
- **MLX：** mlx-whisper 的 `transcribe()` 主循环逐段串行；跨 chunk batch 要我们自己写（`WindowSeeker` 本来就要自己写）。M5 的 GPU Neural Accelerator 已被 MLX 支持，需实测。

### 5.4 Core ML 编码器（仅 whisper.cpp，可选）

whisper.cpp 以 `WHISPER_COREML=ON` + `WHISPER_COREML_ALLOW_FALLBACK=ON` 自行构建（`make whisper-xcframework`）。**默认关闭**：模型通过读取回调加载，whisper.cpp 拿不到模型路径，就找不到 `-encoder.mlmodelc`，编码器跑在 Metal 上。用户开启后按路径加载，编码器走 Core ML（ANE）；缺少编码器文件时直接报错，而不是悄悄回退。

### 5.5 媒体解码

**全部格式都用 FFmpeg**（不再优先 AVFoundation）：原项目通过 PyAV 用 FFmpeg 解码，用 libswresample 默认参数转成 16 kHz mono s16。用同一套库可以得到逐样本相同的结果（PCM 已验证完全一致；AAC 只有末尾填充的裁剪不同，FFmpeg 9 会裁掉，PyAV 自带的 FFmpeg 7.1 不裁）。FFmpeg 9.0.2 以 LGPL 配置自行构建（`make ffmpeg-xcframeworks`），只含 file 协议、常用 demuxer 和音频 decoder，动态 framework 随 App 分发；关于窗口附 LGPL 声明与源码获取方式。

## 6. 模型

### 6.1 由我们转换并托管的模型

| 产物 | 来源 | 转换方式 | 状态 |
| --- | --- | --- | --- |
| 海南鸡 v0.2 ggml f16 | `chickenrice0721/whisper-large-v2-translate-zh-v0.2-st`（HF safetensors，bf16） | `Tools/model-conversion/convert_whisper_to_ggml.py` | ✅ 已转换并在 whisper.cpp 中加载 |
| whisper-ja-1.5B ggml f16 | `efwkjn/whisper-ja-1.5B`（f32/f16 混合，128 mel） | 同上 | 下载中 |
| 海南鸡 / whisper-ja MLX f16 | 同上两个 HF 仓库 | mlx-whisper `convert.py`（`hf_to_pt`） | 待做 |
| ASMR VAD Core ML（fp16） | `TransWithAI/Whisper-Vad-EncDec-ASMR-onnx` | `convert_vad_to_coreml.py`：ONNX → onnx2torch → Core ML；与 ONNX Runtime 概率误差 0.0035 | ✅ |

- 用自己写的转换器而不是 whisper.cpp 的 `convert-h5-to-ggml.py`：后者依赖 PyTorch，处理不了 bf16 的 `.numpy()`，会把小张量先压到 f16 再转回 f32，而且遇到不与词嵌入绑定的 `proj_out` 会静默丢弃。我们的转换器只依赖 NumPy，并且对未绑定的 `proj_out` 报错（海南鸡单独存了 `proj_out`，已验证与词嵌入完全相同）。
- 都从 HF safetensors 版转换，不从 `-ct2` 版：CT2 是单向格式，权重相同。
- 默认不量化；`make whisper-models-q8_0` 保留但不构建。

转换由 Makefile 驱动（`make whisper-models`、`make vad-model`），所有上游版本钉死到提交哈希。产物进 `Models/`（gitignore），下载与缓存在 `.build-tools/`（`make clean-tools` 一次清空）。

### 6.2 模型目录结构

```
<用户选择的目录>/
├─ whisper/
│   ├─ chickenrice-v0.2.bin                  ggml f16
│   ├─ chickenrice-v0.2-encoder.mlmodelc     可选 Core ML 编码器
│   ├─ whisper-ja-1.5b.bin
│   └─ SHA256SUMS
├─ mlx/
│   ├─ chickenrice-v0.2/                     config + safetensors
│   └─ whisper-ja-1.5b/
├─ vad/
│   ├─ whisper-vad-asmr.mlpackage
│   └─ whisper-vad-asmr.mlmodelc             本机编译产物
└─ manifest.json                             版本、校验和、来源、许可证
```

## 7. Job 状态机

```
queued → decodingAudio → detectingSpeech → recognizing(progress)
       → postProcessing → [refiningWithLLM(progress)] → exporting → completed
任意阶段 → failed(JobError) | cancelled
```

`JobStatus` 是 enum，ViewModel 把它映射为行标题、进度与按钮可用性。

## 8. App target 结构

```
Transcriber/
├─ App/            AppDelegate, AppEnvironment（依赖组装）, main.swift
├─ Shared/         ObservationBinder, 通用 NSView 组件
├─ Features/
│   ├─ JobQueue/       JobQueueViewController, JobQueueViewModel, JobRowView
│   ├─ JobDetail/      JobDetailViewController, JobDetailViewModel（播放器 + 字幕列表同步高亮）
│   ├─ Settings/       SettingsWindowController, SettingsViewModel（模式、语言、导出格式、VAD/解码高级参数）
│   ├─ ModelLibrary/   ModelLibraryViewController, ModelLibraryViewModel（模型目录、下载进度、磁盘占用）
│   └─ LLMSettings/    LLMSettingsViewController, LLMSettingsViewModel（OpenRouter Key 存 Keychain、模型选择、术语表）
└─ Resources/
```

ViewModel 的单元测试放在 `TranscriberTests`，用假的 Service 实现驱动，不启动 UI。

## 9. 对拍集（Parity Suite）

不同推理引擎、不同精度的数值不同，识别文本不会逐字一致，所以分两层验证：

- **确定性部分逐项精确比对（单元测试，已在用）：** 每个移植的函数都用脚本从原项目源码中抽出原函数，在相同输入上生成期望输出（`make parity-fixtures`）。目前覆盖：mel（误差 < 1e-4）、VAD 分段（28 例，完全一致）、Core ML VAD 概率（误差 < 0.01）、智能切块（40 例，完全一致）、时间轴修正与合并（60 例，完全一致）、字幕写出（逐字节一致）、媒体解码（PCM 逐样本一致）。
- **识别结果用统计指标：** 与基准逐条匹配（按时间重叠 IoU），计算字符错误率（CER）、BLEU、起止时间平均偏移、漏条/多条数。`transcriber-cli parity` 一条命令出报告，指标退化视为回归。

两个基准：

- **基准 A（原版）：** 在本机用原 Python 项目（CTranslate2 CPU）对 10–20 个文件生成 SRT，覆盖 ASMR、动画、长静音、背景音乐、多人对话、mkv 等；同时保存中间结果（VAD 区间、切块边界、每个窗口的原始 segments）。
- **基准 B（MLX 原型）：** mlx-whisper + 原项目的 VAD（onnxruntime）+ 原项目的切块与合并代码 + 约 10 行的 RepetitionPenalty LogitFilter。先确认“换了推理引擎质量没掉”（B 对 A），之后 Swift 版在本机就有参照；VAD 拼接、时间映射等逻辑也先在 Python 里调通再翻译成 Swift。

## 10. 路线图

### Phase 0：去风险

1. ✅ 工程调整：AppKit 生命周期、macOS 15、arm64、无沙盒、Swift 6；本地 Swift Package `TranscriberKit` 与 `transcriber-cli`。
2. ✅ 自行构建依赖：whisper.cpp v1.9.5（Metal + Core ML fallback，`make whisper-xcframework`）、FFmpeg 9.0.2（`make ffmpeg-xcframeworks`）。
3. 模型转换：✅ 海南鸡 ggml、✅ ASMR VAD Core ML；whisper-ja-1.5B ggml（下载中）；两个模型的 MLX 版本。
4. ✅ 确定性模块，均已对原项目逐项验证：`AudioFeatures`（VAD 前端）、`SpeechDetection`、`ChunkPlanner`、`SubtitlePostProcessing`、`SubtitleExport`、`MediaDecoding`。
5. 基准 A：在本机跑原 Python 项目，生成对拍基准。
6. 基准 B：mlx-whisper Python 原型，对比基准 A；顺带测 M5 Max 上的 MLX 速度。
7. `WhisperDecoding`：faster-whisper 版 mel、分词器、CTranslate2 版逐步 logits 处理、采样、回退、分段、seek、时间映射；先接 whisper.cpp 后端，单窗口与基准 A 比对。
8. `WhisperMLX` 后端：先读 mlx-audio-swift 源码决定复用还是自己移植；跨 chunk batch 解码。
9. 性能（M5 Max / 64GB）：whisper.cpp 并发 state 数 1 / 2 / 4 / 8 对比 MLX batch 1 / 4 / 8，测实时倍率与峰值内存，据此定默认后端与并发。

### Phase 1：完整链路（CLI 可用）

`TranscriptionPipeline` 串起全部模块；`transcriber-cli transcribe` 与 `transcriber-cli parity`；对拍集全量通过。

### Phase 2：AppKit 应用

JobQueue、JobDetail 预览、Settings（含后端选择、Core ML 编码器开关）、ModelLibrary（下载与导入）、拖放、通知、Sparkle。

### Phase 3：LLM

OpenRouter 客户端、模式 A/B、术语表、失败重试与断点续跑。

## 11. 待定事项

- 正式的模型分发渠道（现阶段只在本地 `Models/`）。
- 默认识别后端（whisper.cpp 或 MLX），由 Phase 0 第 9 步的实测决定。
