# Transcriber 架构设计

macOS 原生字幕生成工具。把 [Faster-Whisper-TransWithAI-ChickenRice](https://github.com/TransWithAI/Faster-Whisper-TransWithAI-ChickenRice) v1.10 的推理链路移植到 Apple Silicon：whisper.cpp（Metal）做识别，Core ML 跑 VAD，其余链路用 Swift 重写；末端增加 OpenRouter LLM 润色/翻译。

## 1. 已确定的决策

| 项目 | 决定 |
| --- | --- |
| UI 框架 | AppKit（NSViewController / NSView），MVVM |
| 最低系统 | macOS 15 |
| 分发 | Developer ID 签名 + 公证，直接下载，Sparkle 更新，**不开沙盒** |
| 识别引擎 | **whisper.cpp（Metal）**，通过 C API 调用；保留 `SpeechRecognizer` 协议 |
| VAD | **TransWithAI ASMR VAD 转 Core ML**；不使用 whisper.cpp 自带的 Silero VAD |
| 链路 | 解码、VAD、智能切块、语音拼接、时间戳映射、温度回退、后处理全部在 Swift 中实现，whisper.cpp 只接收 PCM |
| 模型 | **App 不内置模型**。我们自己转换（ggml + Core ML）并单独分发；App 下载到用户指定的模型目录。现阶段不公开，转换产物放在本仓库的 `Models/`（已 gitignore） |
| 目标硬件 | 高端 Mac 优先；16GB 机器用 q8_0 模型。开发与性能基线机：**M5 Max / 64GB** |
| 移植策略 | 默认行为与原项目一致，可选改进项单独开关；用对拍集量化验证（见 §9） |
| LLM | OpenRouter，两种模式：A 润色海南鸡中文输出 / B 日文转写 → 翻译到任意语言 |
| 首版范围 | 批处理队列 + 进度 + 视频/音频与字幕对照预览 + 导出 |

> 当前 Xcode 工程是 SwiftUI 模板（部署目标 macOS 27、开启沙盒），需按上表调整，见 §10 Phase 0。

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
| `MediaDecoding` | `MediaDecoder` | 解码 → 16 kHz mono float32。AVFoundation 优先；mkv/flv/wmv 等交给内置 FFmpeg（见 §5.4） | `decode_audio` |
| `AudioFeatures` | `LogMelSpectrogram` | vDSP 实现 VAD 用的 80-mel 前端，与 HF `WhisperFeatureExtractor` 逐元素一致 | `WhisperFeatureExtractor` |
| `SpeechDetection` | `VoiceActivityDetector` | Core ML 跑 ASMR VAD；`SpeechSegmenter` 是纯函数，实现带滞回的阈值分段 | `vad_manager.py` |
| `WhisperCpp` | `SpeechRecognizer` | 封装 whisper.cpp C API：模型加载、参数映射、logits 回调、state 池（见 §5.1） | CTranslate2 + faster-whisper |
| `TranscriptionPipeline` | `TranscriptionPipeline` | 编排：解码 → 外层 VAD → 智能切块 → 内层 VAD 拼接 → 识别（含温度回退）→ 时间映射 → 后处理；用 `AsyncThrowingStream<PipelineEvent>` 报告进度 | `infer.py` + faster-whisper `transcribe.py` |
| `SubtitlePostProcessing` | 纯函数集合 | `enforceTimeline`、`mergeSegments` | `enforce_segment_timeline`, `merge_segments` |
| `LLMTranslation` | `SubtitleTranslator` | OpenRouter 客户端；模式 A 润色、模式 B 翻译；JSON Schema 保证按 `id` 一一返回；滑动窗口携带上下文；术语表 | 新增 |
| `SubtitleExport` | `SubtitleWriter` | SRT / VTT（修正为 `WEBVTT` 头）/ LRC / ASS / TXT | `SubWriter` |
| `ModelStore` | `ModelStore` | 模型目录管理：从我们的仓库下载（断点续传、校验 SHA-256）、导入、删除、编译 Core ML | `download_models.py` |
| `JobQueue` | `JobQueue`（actor） | 调度 Job，支持取消与重试，向外发布状态快照 | 批处理循环 |

### 5.1 WhisperCpp 模块

```
WhisperCpp/
├─ WhisperModel              持有 whisper_context*（共享权重，Metal 开启）
├─ WhisperDecoderPool        N 个 whisper_state*，每个 chunk 借用一个；chunk 之间无上下文依赖，可并行
├─ WhisperParameters         DecodingSettings → whisper_full_params 的唯一映射点
├─ RepetitionPenaltyFilter   logits_filter_callback 的 Swift 实现
├─ WhisperDecodeResult       从 state 读出 segments、token、plog、no_speech_prob
└─ WhisperCppRecognizer      实现 SpeechRecognizer
```

**并行：** 原项目 `condition_on_previous_text = False`，各 chunk 相互独立。高端 Mac 上开多个 `whisper_state` 共享同一份权重并发解码，弥补 whisper.cpp 不支持跨段 batch 的问题。并发数按统一内存大小自适应，在 Phase 0 实测确定。

### 5.2 参数映射（faster-whisper → whisper.cpp）

| faster-whisper（原项目实际值） | whisper.cpp | 说明 |
| --- | --- | --- |
| `language="ja"` | `language = "ja"` | |
| `task="translate"` / `"transcribe"` | `translate = true / false` | 海南鸡把 translate 任务改训成输出中文，whisper.cpp 只负责放 task token，不限制输出语言 |
| `beam_size=1` | `WHISPER_SAMPLING_GREEDY` | |
| `best_of=5`（仅温度 > 0 时） | `greedy.best_of = 5` | |
| `condition_on_previous_text=False` | `no_context = true` | |
| `max_initial_timestamp=30` | `max_initial_ts = 30` | **whisper.cpp 默认 1.0，不改会导致片段开头时间轴错误** |
| `repetition_penalty=1.1` | 无，用 `logits_filter_callback` 实现 | 见 §5.3 |
| `without_timestamps=False` | `no_timestamps = false` | |
| `suppress_blank=True` | `suppress_blank = true` | |
| `suppress_tokens=[-1]` | `suppress_nst` + 回调补齐 | 需核对两边抑制列表完全一致（模型 `config.json` 的 `suppress_ids` 是基准） |
| `temperature=[0,0.2,…,1.0]` + `compression_ratio_threshold=2.4` | **关闭内置回退**（`temperature_inc = 0`），在 Swift 中实现 | whisper.cpp 的回退判据是 token 熵（`entropy_thold`），不是 gzip 压缩比；要一致只能自己做，见 §5.3 |
| `log_prob_threshold=-1.0`、`no_speech_threshold=0.6` | Swift 回退逻辑中判断 | 用 `whisper_full_get_segment_no_speech_prob` 与 token `plog` 计算 |
| `vad_filter=True` | `vad = false` | VAD 全在 Swift 侧完成，whisper.cpp 只收拼接好的 PCM |

### 5.3 需要自己实现、且最容易出偏差的三处

1. **重复惩罚。** CTranslate2 公式：对已出现过的 token，logit > 0 时除以 1.1，logit < 0 时乘以 1.1。Phase 0 必须核对两点：
   - 哪些 token 算“已出现”（是否包含 SOT/语言/任务等前缀 token）；
   - 惩罚与 suppress、时间戳规则的先后顺序，与 whisper.cpp 中 `logits_filter_callback` 的调用位置是否一致。
2. **温度回退。** 按 faster-whisper `generate_with_fallback` 逐行移植：每个温度调用一次 `whisper_full`，用 zlib 压缩比、平均 logprob、no_speech 概率决定是否接受。边界情况：faster-whisper 按 30 s 窗口回退，而 whisper.cpp 在一次调用内可能因 seek 解码第二个短窗口；用对拍集确认影响。
3. **时间映射。** 内层 VAD 把语音拼接后送入 whisper.cpp，返回的时间是“紧凑时间”，需经 `SpeechTimeline` 映射回原始时间，再加 chunk 偏移。逻辑照搬 faster-whisper `SpeechTimestampsMap`。

### 5.4 媒体解码

AVFoundation 不支持 mkv，而这类工具的用户经常拖入 mkv。方案：自行构建仅含音频的 FFmpeg（libavformat + libavcodec + libswresample），LGPL 配置、动态链接、打成 xcframework 随 App 分发。只启用常用的 demuxer（matroska、avi、flv、asf、mov、mpegts）与音频 decoder（aac、mp3、opus、vorbis、flac、ac3、eac3、wma、pcm）。在关于窗口附上 LGPL 声明与源码获取方式。

## 6. 模型

### 6.1 由我们转换并托管的模型

| 产物 | 来源 | 转换方式 | 许可证 |
| --- | --- | --- | --- |
| 海南鸡 v0.2 ggml（f16 / q8_0） | `chickenrice0721/whisper-large-v2-translate-zh-v0.2-st`（HF safetensors） | whisper.cpp `convert-h5-to-ggml.py` → `quantize` | Apache-2.0，可再分发（需署名） |
| whisper-ja-1.5B ggml（f16 / q8_0） | `efwkjn/whisper-ja-1.5B` | 同上，需确认转换脚本正确处理 128 mel | 开放使用（已确认） |
| ASMR VAD Core ML | `TransWithAI/Whisper-Vad-EncDec-ASMR-onnx` | coremltools 已不支持 ONNX：用 `onnx2torch` 转 PyTorch，或按 `TransWithAI/whisper-vad` 源码重建模型并载入权重，再导出 `.mlpackage` | MIT |

- ggml 从 HF safetensors 版转换，而不是 `-ct2` 版：CT2 是单向格式，两者权重相同。
- whisper.cpp 自己计算 mel，并处理 80 / 128 维的差异；Swift 侧的 mel 只服务于 VAD。
- VAD 的 mel 也可以放进 Core ML 模型内部；首版放在 Swift（vDSP）里，便于单独测试。
- VAD 的 `.mlpackage` 下载后由 `ModelStore` 调用 `MLModel.compileModel(at:)`，把 `.mlmodelc` 存进用户的模型目录。设备专属的 ANE 优化缓存仍由系统管理，无法指定位置。

转换脚本放在 `Tools/model-conversion/`，产物输出到仓库根目录的 `Models/`（gitignore，不入库）。每个产物附带 SHA-256 与转换参数记录，可复现。开发期间 App 的模型目录直接指向 `Models/`；正式分发渠道日后再定。

### 6.2 模型目录结构

```
<用户选择的目录>/
├─ whisper/
│   ├─ chickenrice-v0.2-f16.bin
│   └─ chickenrice-v0.2-q8_0.bin
├─ vad/
│   ├─ whisper-vad-asmr.mlpackage
│   └─ whisper-vad-asmr.mlmodelc     （本机编译产物）
└─ manifest.json                      版本、校验和、来源、许可证
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

CT2 的 float16 / int8 与 ggml 的 f16 / q8_0 数值不同，结果不会逐字一致，所以用指标衡量，而不是要求完全相同。

- **基准：** 用原 Python 版对 10–20 个文件生成 SRT，覆盖 ASMR、动画、长静音、背景音乐、多人对话、mkv 等场景；同时保存中间结果（VAD 帧概率、切块边界、原始 segments）。
- **指标：** 与基准逐条匹配（按时间重叠 IoU），计算字符错误率（CER）、BLEU、起止时间平均偏移、漏条/多条数。
- **分层比对：** mel（容差 1e-4）、VAD 帧概率（1e-3）、切块边界（完全一致）能逐项精确比对；只有识别文本使用统计指标。
- **流程：** `transcriber-cli parity Fixtures/` 一条命令输出报告；每次改动链路都要跑，指标退化视为回归。

## 10. 路线图

### Phase 0：去风险

1. ✅ 工程调整：改为 AppKit 生命周期，部署目标 macOS 15，关闭沙盒，Swift 6 语言模式；新建本地 Swift Package `TranscriberKit` 与 `transcriber-cli`；引入 whisper.cpp xcframework（v1.9.5，取自同一提交的构建发布 b5454，因为 v1.9.5 标签本身没有附件）。
2. 对拍基准：在本机运行原 Python 项目，生成 §9 的基准数据。
3. 模型转换：海南鸡、whisper-ja-1.5B → ggml f16 / q8_0；ASMR VAD → Core ML，并与 ONNX 输出比对。产物写入 `Models/`。
4. `AudioFeatures` + `SpeechDetection`：VAD 帧概率与原项目一致。
5. `WhisperCpp`：加载 ggml，按 §5.2 映射参数，实现重复惩罚回调，解码一个 30 s 片段并与原项目比对；核对 §5.3 第 1 点的两个问题。
   - **已知风险：** 官方 xcframework 运行时报告 `COREML = 1`，而 `WHISPER_COREML_ALLOW_FALLBACK` 默认关闭。若模型旁没有 `-encoder.mlmodelc`，`whisper_init_state` 可能直接失败。处理方式二选一：自行构建 xcframework（关闭 Core ML，或开启 fallback）；或者顺势为每个模型转换 Core ML 编码器，让编码器跑在 ANE 上、解码器跑在 Metal 上。
6. 性能（M5 Max / 64GB）：测并发 state 数 = 1 / 2 / 4 / 8 的实时倍率与峰值内存，f16 与 q8_0 各测一次，据此定默认并发数。

### Phase 1：完整链路（CLI 可用）

智能切块、内层 VAD 拼接与时间映射、Swift 温度回退、后处理、导出、FFmpeg 解码；对拍集全量通过。

### Phase 2：AppKit 应用

JobQueue、JobDetail 预览、Settings、ModelLibrary（下载与导入）、拖放、通知、Sparkle。

### Phase 3：LLM

OpenRouter 客户端、模式 A/B、术语表、失败重试与断点续跑。

## 11. 待定事项

- 正式的模型分发渠道（现阶段只在本地 `Models/`）。
