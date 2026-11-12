# LiveCopilot Windows：Core / Stores 与本地推理（第 3 线）

本目录承接 Swift 版本中可独立测试的领域模型、配置、分析预设、状态存储及本地 ASR / embedding，使用 C# 12 / .NET 8。WPF 项目目前只有一个空窗口，尚不是可用的 Windows 客户端。原有 `StealthApp/` 源码与资源保持不变。

## 解决方案结构

```text
Windows/
├── Directory.Build.props                 # Nullable、警告视为错误、Windows targeting
├── LiveCopilot.Windows.sln
├── src/
│   ├── LiveCopilot.Core/                  # net8.0，不依赖 WPF / Apple 框架
│   │   ├── Domain/                       # 领域类型、回答策略、问题状态机
│   │   ├── Analysis/                     # 模型能力、58 项预设、价格与性能参考
│   │   ├── Preferences/                  # AppSettings、可注入的偏好存储
│   │   ├── Providers/                    # 提供器接口与事件类型
│   │   ├── Localization/                 # 界面翻译与可替换的语言检测接口
│   │   ├── Stores/                       # 会话、转写、建议、异步转写翻译
│   │   ├── Knowledge/                    # SQLite 索引、文本解析、分块与检索
│   │   ├── Support/                      # JSON、值语义集合、原子文件写入等
│   │   └── Resources/                    # 嵌入式 JSON 字典、提示词和分析数据
│   ├── LiveCopilot.LocalInference/        # net8.0，sherpa-onnx / LLamaSharp，独立于 Core
│   └── LiveCopilot.App/                   # net8.0-windows，WPF 空壳
├── tests/
│   ├── LiveCopilot.Core.Tests/            # xUnit，临时目录及合成提供器
│   └── LiveCopilot.LocalInference.Tests/  # 无权重契约测试 + 可跳过的真实模型测试
└── tools/import-localization.py          # 从 Swift 只读导入界面字典的维护工具
```

Core 使用 `Microsoft.Data.Sqlite 8.0.22`。界面 JSON 资源显式设置 `WithCulture="false"`，统一嵌入 Core 程序集，避免文件名中的 `zh-Hans` / `zh-Hant` 被自动拆到卫星程序集。常规构建直接使用已提交的资源，不需要运行导入脚本；该维护脚本需要 Python 3 和 Linux ICU。

## Linux 上构建与测试

本工作区的 SDK 为 `/home/box/.dotnet` 下的 .NET SDK 8.0.428。首次恢复需要访问 nuget.org：

```bash
export PATH="/home/box/.dotnet:$PATH"
export DOTNET_ROOT="/home/box/.dotnet"
export DOTNET_EnableWindowsTargeting=true
export DOTNET_CLI_HOME="/tmp/dotnet-home"
export DOTNET_NOLOGO=1
export LIVECOPILOT_INFERENCE_CPU=1
cd /workspace/livecopilot-windows-inference/Windows

/home/box/.dotnet/dotnet restore LiveCopilot.Windows.sln
/home/box/.dotnet/dotnet build src/LiveCopilot.Core/LiveCopilot.Core.csproj -c Release
/home/box/.dotnet/dotnet test tests/LiveCopilot.Core.Tests/LiveCopilot.Core.Tests.csproj -c Release \
  --logger 'trx;LogFileName=Core.Release.line3.trx' \
  --results-directory /workspace/codex/livecopilot-windows/validation
/home/box/.dotnet/dotnet build src/LiveCopilot.LocalInference/LiveCopilot.LocalInference.csproj -c Release
/home/box/.dotnet/dotnet test tests/LiveCopilot.LocalInference.Tests/LiveCopilot.LocalInference.Tests.csproj -c Release \
  --logger 'trx;LogFileName=LocalInference.Release.line3.trx' \
  --results-directory /workspace/codex/livecopilot-windows/validation
```

`Directory.Build.props` 也设置了 `EnableWindowsTargeting=true`；需要显式指定 MSBuild 属性时，可在命令末尾加 `-p:EnableWindowsTargeting=true`。它允许 Linux 恢复含 Windows 项目的解决方案，不代表 Linux 可以运行 WPF。其它机器请按实际 SDK 和仓库位置调整路径。

必跑测试使用合成文本、可控制完成时机的假提供器和独立临时目录，不调用付费服务、不下载模型、不读写用户真实会话。覆盖领域模型与序列化、回答语言/引用策略、全部分析配置，以及会话读写和导出、旧会话只读加载、转写修订与长归档、异步取消/超时后丢弃旧结果、SQLite 检索与失败回滚。

## 本地推理与模型目录

`LiveCopilot.LocalInference` 引用 Core，Core 不反向依赖原生包。固定依赖为 `org.k2fsa.sherpa.onnx 1.13.8`、`LLamaSharp 0.27.0` 及同版本的 `LLamaSharp.Backend.Cpu`、`LLamaSharp.Backend.Cuda12`、`LLamaSharp.Backend.Vulkan`；GPU 包始终保留，不以 Linux 测试条件裁掉。

- `LocalLiveProvider` 实现 `ILiveProvider` 与统计接口。默认 streaming Paraformer-zh-en INT8 + Silero VAD；`contextual: true` 使用 Zipformer、`decoder.onnx`、`joiner.int8.onnx`、`bpe.vocab`，`UpdateTerms` 支持最多 100 条、每条最多 100 个 UTF-16 单元，与 Mac 一致。热词只作用于下一段新建的识别流。
- 输入为单声道 16 kHz、16-bit little-endian PCM，32 bytes = 1 ms；采集层负责重采样。500 ms 分块送入引擎，未处理及正在推理的音频合计上限 12 秒；溢出显式 failed，不丢音频后假报 finalized。引擎直接调用单次最大 15 秒。空输入用于 flush，停止会处理短尾块并给 recognizer 添加 1 秒零填充。
- VAD 固定 sample_rate=16000、threshold=0.5、min_silence=0.65 s、min_speech=0.2 s、max_speech=12 s、window=512、buffer=30 s、num_threads=1；ASR feature_dim=80、num_threads=2。预览可替换，只有 VAD 分段或停止 flush 产生正式转写。事件为 ready、partialTranscript、transcript、speechActivity、failed、closed，不产生问题分类或 delegation。
- `LocalEmbeddingProvider` 实现 `ILocalEmbeddingPreparing`，`PrepareAsync` 做一次真实 warmup。BGE-M3 Q8_0 GGUF 固定 CLS pooling、L2 归一化、1024 维，单条最多 8192 tokens / 100000 UTF-8 bytes；context/batch/microbatch 按 512 至 8192 的二次幂增长。结果拒绝 NaN、Infinity、全零及维数错误。identity 保持 `local:bge-m3:q8_0:950f4a8e5e19:cls:l2:v1`。逐条完成后回调 progress(1..N)，条目间释放串行队列；取消传递到校验、LLama 权重加载及推理，progress 中也能插入交互查询。

默认模型根目录为 `%LOCALAPPDATA%/LiveCopilot/Models`，构造参数可注入其它目录；构造提供器不下载模型。子目录及清单来自 `LocalModels`：

| 用途 | 子目录 | 大小 |
| --- | --- | --- |
| 默认 ASR | `paraformer-streaming-zh-en-int8-v1` | 约 238 MB |
| 术语 ASR | `zipformer-streaming-zh-en-hotwords-v1` | 约 200 MB |
| Embedding | `bge-m3-q8-v1` | 约 635 MB |

`IsInstalled(root)` 与 Mac 一样检查 `installed.json` 的完整文件名集合、正数长度和实际文件长度；不把 receipt 当作密码学证明。安装及每次原生引擎加载前还校验固定 SHA-256，拦住同长度损坏文件。缺失、损坏或运行失败显式报错，绝不静默转云端。可选安装 helper 示例（调用方自行提供取消令牌，同一根目录的安装/删除需串行）：

```csharp
using var http = new HttpClient();
await LocalModelInstaller.InstallAsync(LocalModelKind.StreamingSpeech, root,
    (item, path, ct) => LocalModelInstaller.DownloadAsync(http, item, path, ct), cancellationToken);
```

helper 依次尝试发行地址、镜像和原站，校验成功后才发布下载文件；整包使用同文件系统的 staging、旧目录备份、移动与失败回滚，写入 receipt 后才生效。不是断点续传器，也不承诺断电时跨两次目录移动的事务性。权重及 native DLL 均不进 Git。

## 硬件后端与部署

| 引擎 | 自动选择顺序 | CPU 强制方式 |
| --- | --- | --- |
| sherpa / ONNX Runtime | NVIDIA CUDA → Windows DirectML → CPU | `new InferenceOptions { ForceCpu = true }` |
| LLamaSharp | CUDA → Vulkan → CPU | 同左；CPU 时 `GpuLayerCount=0`，GPU 时 99 |

`LIVECOPILOT_INFERENCE_CPU=1` 也可强制 CPU；正常产品环境应移除此变量。`IHardwareProbe` 可注入能力集合，必跑测试覆盖 CUDA、仅 DirectML、仅 CPU。系统探测使用 CUDA driver/device count、D3D12 设备及 Vulkan loader；加载器进一步判断运行库是否可用。提供器和实际引擎公开 `Backend` / `BackendAttempts`，可观察选择与回退。VAD 固定 CPU；选中 GPU provider 不保证 INT8 图的所有算子都在 GPU 执行，需在目标 Windows 硬件上测量。

LLamaSharp 已通过 NuGet 引入 CPU、CUDA 12、Vulkan 原生后端；按其加载策略优先 CUDA，再 Vulkan，再 CPU。GPU 模型分配或推理失败时重新以 0 GPU layers 加载；取消不会触发重试。运行库选择是进程级的，首次加载后切换运行库需重启；后续会话仍可要求 CPU 计算。

sherpa 官方 C# 包带来的 Windows runtime 是 CPU 发行物，**仅安装该 NuGet 包不会自动获得 CUDA / DirectML**。C# 配置的 `Provider` 交给 sherpa 链接的 ONNX Runtime；不能只多加一个 ORT NuGet 包就让 CPU sherpa 启用编译期开关。GPU 部署应放置完整且版本一致的 sherpa 1.13.8 native 发行物：

```text
<host output>/native/sherpa/
├── cuda/       # sherpa-onnx-c-api.dll、对应 onnxruntime.dll、provider/shared DLL 及所需依赖
└── directml/   # 启用 SHERPA_ONNX_ENABLE_DIRECTML 的 sherpa DLL、对应 ORT 与 DirectML.dll
```

也可通过 `InferenceOptions.SherpaRuntimeRoot` 指定该根目录。CUDA 12 / cuDNN 9 的官方 [1.13.8 发行包](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.8) 文件名为 `sherpa-onnx-v1.13.8-cuda-12.x-cudnn-9.x-onnxruntime1.28.2-win-x64-cuda.tar.bz2`，约 595 MB，SHA-256 为 `066c5b54dbafaa1388001a9c9837ac1374dbba6d6678f193ca06aa0d8e94d8c3`。将其中匹配 x64 的 DLL 集合及 CUDA/cuDNN 运行依赖部署至 `cuda`，不要混入 CPU ORT。下载与 GPU 发行打包不由单元测试执行。

DirectML 必须使用启用该后端的 sherpa build；参见固定版本的 [DirectML CMake](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/cmake/onnxruntime-win-x64-directml.cmake)。Windows 开发者可使用 VS 2022 C++ 工具、CMake，以及仓库外已解压的官方 v1.13.8 源码构建（不编译本仓库的 `LocalInference.mm`）：

```powershell
cmake -S C:\deps\sherpa-onnx-1.13.8 -B .\obj\sherpa-directml -A x64 `
  -DBUILD_SHARED_LIBS=ON -DSHERPA_ONNX_ENABLE_DIRECTML=ON `
  -DSHERPA_ONNX_ENABLE_GPU=OFF -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF `
  -DSHERPA_ONNX_ENABLE_TESTS=OFF -DSHERPA_ONNX_ENABLE_C_API=ON
cmake --build .\obj\sherpa-directml --config Release
```

复制该构建的配套 DLL 到 `directml`，保留第三方 license。此步骤需要 Windows；本轮 Linux 验证没有宣称完成 CUDA / DirectML 真机验收。

加载器先用同目录 ORT 的官方 `OrtGetApiBase` v8 ABI 查询 provider 并检查 CUDA/DML append 状态，再加载对应 sherpa；不再依赖不存在的自定义 probe 导出。只接受 sherpa 1.13.8，候选不可用时记录原因并继续回退。使用官方 C# 配置布局及结果类型，薄 C API 适配器补齐动态热词、空 handle 检查、Windows UTF-8 模型路径；所有推理在进程内完成。运行库在进程内常驻，host 应在其它 ORT 使用者之前配置本地推理，不混载不同 ORT 发行物。原生调用卡住时无法安全强杀线程；15 秒停止期限后报告失败并抑制迟到结果，由原工作任务在返回时释放资源。

## 可选真实模型验收

必跑测试不依赖仓库内权重，不要求 GPU / 麦克风，包含包内 CPU sherpa 加载和 ORT provider 探测。真实模型测试默认读取 `/workspace/livecopilot-models`，或 `LIVECOPILOT_MODEL_ROOT` 指定的根目录，按上述目录布局及 receipt 安装：

```bash
export LIVECOPILOT_MODEL_ROOT=/workspace/livecopilot-models
export LIVECOPILOT_INFERENCE_CPU=1
# 可选：原始单声道 PCM16 LE / 16 kHz 语音文件；无此项时 ASR 验证静音和 flush。
# export LIVECOPILOT_ASR_PCM=/external/fixtures/speech.pcm
dotnet test tests/LiveCopilot.LocalInference.Tests/LiveCopilot.LocalInference.Tests.csproj \
  -c Release --filter 'Category=Integration'
```

模型目录缺失时明确 skip；目录存在但内容损坏时 fail。ASR 测试实际处理 PCM 并 flush，提供语音 fixture 时要求非空转写；embedding 测试执行 warmup、检查有限非零 1024 维单位向量，并比较相关/不相关句子的相似度。2026-11-12 Linux 验证：Core 164 通过；LocalInference 61 通过、2 跳过；Release 构建 0 warnings / 0 errors。外部模型缓存为空，本轮未下载约 873 MB 的默认 ASR + embedding 权重，因此不能把无权重测试视为识别精度、真实向量或 Windows GPU 性能验收。

## Windows 完整构建

包含 WPF 的完整构建和运行验证需在安装 .NET 8 SDK 的 Windows，或 GitHub Actions 的 `windows-latest` runner 上进行：

```powershell
cd Windows
dotnet restore LiveCopilot.Windows.sln
dotnet build LiveCopilot.Windows.sln -c Release --no-restore
dotnet test tests/LiveCopilot.Core.Tests/LiveCopilot.Core.Tests.csproj -c Release --no-build
# 本地 Windows 可启动空窗口：
dotnet run --project src/LiveCopilot.App/LiveCopilot.App.csproj -c Release
```

Linux 的 Core 测试通过不构成 WPF 编译、桌面交互或 Windows 原生能力验收。本批不添加 CI 工作流，也不签名或打包发布。

## 存储和适配边界

- `SessionStore(root)`、`FilePreferenceStore(root)`、`KnowledgeIndex(directory, parser)` 支持注入数据根目录。构造时不创建目录或写盘；`SessionStore` 只读取已有 JSON，KnowledgeIndex 在首次数据库操作时初始化。其它 Store 只保存内存状态。
- 偏好保留 Swift UserDefaults 的键名；文件偏好不用于保存 API 密钥。默认根目录来自 `LocalApplicationData/LiveCopilot`，测试全部显式指定临时目录。
- 会话保留 Swift JSON 字段与枚举值，日期采用 ISO 8601；普通领域 JSON 日期采用 Swift 的 2001-01-01 参考时间。旧会话缺少 answers/schemaVersion 时保持旧语义，不在加载时迁移写回。未完成的命名只在内存中标为失败。
- `AnswerPolicy.swift` 的语义分布在 `AnswerLanguage`、`KnowledgeMode`、`QuestionScope`、`CitationPolicy` 和 `AnswerRequest` 等类型中，没有重复添加 `AnswerPolicy` 类。
- 同步 Store 由调用方串行调用，对应 Swift 的 MainActor 约束。`TranscriptTranslationStore` 自行同步异步状态，并用取消与代次检查丢弃过期结果；其通知可能来自工作线程，未来 UI 适配层需要转到 Dispatcher。
- `IReasoningProvider`、`IEmbeddingProvider`、`ILiveProvider` 在 Core 中只定义契约。LocalInference 实现本地语音与 embedding；没有实现网络服务或音频采集。分析模型、价格和性能数据是仓库内 Swift 版本的快照，不进行在线刷新。
- `TextDocumentParser` 内置 TXT / Markdown（UTF-8、UTF-16）解析；PDF / DOCX 留给 `IDocumentParser` 适配器，没有引入 PDF 原生依赖。保留现有 KnowledgeIndex 的导入、重建和检索逻辑，没有新增 DocumentImport 编排层。
- 界面简体字典与繁体转换快照保留原文边界，不转换用户文档或对话。自动回答语言使用可注入的 `ITextLanguageDetector`，默认实现为跨平台启发式，与 Apple NaturalLanguage 的统计结果不保证逐句一致。

## 明确不在本批范围

- 不实现 WASAPI、全局快捷键、悬浮窗、`SetWindowDisplayAffinity` 或其它桌面原生集成。现有 `OverlayLayout` 仅为纯几何与状态计算。
- 不移植或接入 Laya / MLX、决策模型分类器；不启动第 4 线。第 3 线只提供可调用的本地推理库，尚未接入 WPF 空壳。
- 不翻译 `AppleSpeech*`、`AppleLiveProvider`、`Laya*`、`AudioFlowMonitor`、`EchoMonitor`、`AppCoordinator`。
- 不新增 `OnboardingStore` 或 `DocumentImport`，不实现真实服务凭据管理。既有设置中的云服务兼容字段不代表真实网络服务已经接入。
- 不修改 Mac 源码或资源，不进行签名、推送、PR、远程配置修改。
