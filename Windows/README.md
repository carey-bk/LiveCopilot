# LiveCopilot Windows：Core、本地推理、平台层与聆听会话（第 5 线）

本目录承接 Swift 版本中可独立测试的领域模型、配置、分析预设、状态存储及本地 ASR / embedding，使用 C# 12 / .NET 8。第 4 线增加 WASAPI 音频、WPF 浮窗壳和全局快捷键；第 5 线通过可测试的 `ListeningSession` 连接双路采集与本地语音识别，宿主可手动开始/停止并显示实时转写。云端听写、回答推理和完整客户端 UI 尚未接入。原有 `StealthApp/` 源码与资源保持不变。

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
│   ├── LiveCopilot.Platform/              # net8.0，可注入音频/快捷键/浮窗逻辑及聆听会话
│   ├── LiveCopilot.Platform.Windows/      # net8.0-windows，NAudio WASAPI、Win32、WPF 壳
│   └── LiveCopilot.App/                   # net8.0-windows，手动开始/停止的薄宿主
├── tests/
│   ├── LiveCopilot.Core.Tests/            # xUnit，临时目录及合成提供器
│   ├── LiveCopilot.LocalInference.Tests/  # 无权重契约测试 + 可跳过的真实模型测试
│   └── LiveCopilot.Platform.Tests/        # net8.0 / net8.0-windows，假源测试 + 显式跳过桌面探针
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
cd /workspace/livecopilot-windows-session/Windows

set -o pipefail
dotnet build LiveCopilot.Windows.sln -c Release 2>&1 | tee /workspace/codex/livecopilot-windows/validation/Build.Release.line5.log
dotnet test tests/LiveCopilot.Core.Tests/LiveCopilot.Core.Tests.csproj -c Release \
  --logger 'trx;LogFileName=Core.Release.line5.trx' \
  --results-directory /workspace/codex/livecopilot-windows/validation
dotnet test tests/LiveCopilot.LocalInference.Tests/LiveCopilot.LocalInference.Tests.csproj -c Release \
  --logger 'trx;LogFileName=LocalInference.Release.line5.trx' \
  --results-directory /workspace/codex/livecopilot-windows/validation
dotnet test tests/LiveCopilot.Platform.Tests/LiveCopilot.Platform.Tests.csproj -c Release -f net8.0 \
  --logger 'trx;LogFileName=Platform.Release.line5.trx' \
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

桌面运行验证需安装 .NET 8 SDK 的 Windows；包含 WPF 的编译也可在启用 Windows targeting 的 Linux 上完成。Windows 构建命令如下：

```powershell
cd Windows
dotnet restore LiveCopilot.Windows.sln
dotnet build LiveCopilot.Windows.sln -c Release --no-restore
dotnet test tests/LiveCopilot.Core.Tests/LiveCopilot.Core.Tests.csproj -c Release --no-build
# 本地 Windows 启动聆听宿主（启动应用不会自动采集）：
dotnet run --project src/LiveCopilot.App/LiveCopilot.App.csproj -c Release
```

Linux 可以交叉编译 WPF，但不能运行窗口；假源测试通过不构成真实桌面、声卡、会议共享或 Windows 原生能力验收。本批不添加 CI 工作流，也不签名或打包发布。

## 第 5 线：聆听会话与宿主操作

启动后显示主窗口与浮窗，状态为“未开始聆听”，不创建语音提供器、不加载模型、不采集声音。点击“开始聆听”才加载本地语音并启动系统与麦克风两路；点击“停止”先停止两路采集，再等待识别器 flush，最后把有正式转写的会话保存到 `%LOCALAPPDATA%/LiveCopilot/sessions`。重复开始/停止不会重复连接或重复保存；关闭主窗口也会停止、保存并释放快捷键与浮窗。保存错误会显示在主窗口和浮窗，关闭时也会提示；本批没有历史浏览或保存重试 UI。

宿主使用持久化的 `AppSettings`（默认 Zipformer）；没有设置页。模型应预先放在 `%LOCALAPPDATA%/LiveCopilot/Models`，按上文清单及 receipt 安装；独立宿主/测试可向 `LocalLiveProvider` 注入其它 root。本批 UI 不下载模型、不预热 embedding、不强制 CPU。缺失、损坏、运行库错误都会明确显示失败；只有 provider 发出 Ready 后才读取并展示实际 `Backend`，未就绪时不宣称 GPU/CPU 成功。OpenAI 或 Apple 听写选择会在打开音频源之前被拒绝，提示“云端听写尚未接入”。

`ListeningSession` 位于纯 `net8.0` Platform，依赖音频工厂、`ILiveProvider` 工厂、设置快照、独占的 `TranscriptStore` 以及可选 `SessionStore` / `ICaptureClock`。Platform 仅引用 Core，不引用 LocalInference、sherpa、LLamaSharp、NAudio 或 WPF。WPF 宿主注入 `WasapiAudioSourceFactory`，每次开始为 Them / You 各创建一个新的 `LocalLiveProvider`；单次使用的 provider 在断开后不复用。`ListeningProvider` 的可选能力委托提供热词配置与已观察到的后端信息，避免向 Platform 泄漏原生实现。

两路在启动前都配置为 16000 Hz。Zipformer 在 Connect 前收到 `ProfessionalTerms`；Paraformer 不调用不支持的 `UpdateTerms`。会话等待两路 Ready 后启动采集。系统 PCM 只发给 Them，麦克风 PCM 只发给 You，均为单声道 PCM16 LE；回调直接交给 provider 快速复制/入队，不为每个音频块创建任务。正式转写用 `TranscriptStore.Ingest` 保留合并/修订规则，partials 按路径更新，停止时继续接受两路 flush 的最终片段再保存，未定稿内容不冒充正式转写。

任一路准备、模型加载或采集启动失败都会回滚整次启动；运行中 provider / 音频错误也会停止两路，保留首个原因。停止和错误处理不在 PCM 回调中同步等待，避免等待自身；启动中也能点击停止以取消等待。另一条路径仍会断开和 flush，保存失败不会阻止释放资源。失败后重新开始会清空本次显示并创建新 provider，旧会话的迟到事件不进入新转写。

快照包含 Idle / Starting / Listening / Failed / Stopped、停止中标记、错误、两路采集状态和 `SourceDescription`、后端、正式转写、partials、语音活动及最近建议模式。`Changed` 可从工作线程触发，订阅者必须快速返回，不能同步等待生命周期方法；宿主合并通知并通过 `Dispatcher.BeginInvoke` 读取最新快照。浮窗显示状态、最近 8 行 Them / You 转写及双方未定稿文本，内容变化重新测量并调用 `ContentHeightChanged`，超出高度时可滚动；保留置顶、不抢焦点、贴边隐藏与捕获排除逻辑。

Ctrl+Alt+Space / Ctrl+Alt+S / Ctrl+Alt+X 分别记录回答/总结/追问请求，并显示“已请求…，推理服务尚未接入”；不会调用 `IReasoningProvider`、网络或生成假答案。禁用模式不响应，Alt+H 仍控制浮窗显示/隐藏。构造、打开浮窗和按建议快捷键均不会自动开始采集。

## 第 4 线：音频契约与 WASAPI

`LiveCopilot.Platform` 不引用原生包，`LiveCopilot.Platform.Windows` 固定引用官方 [NAudio.Wasapi 2.3.0](https://www.nuget.org/packages/NAudio.Wasapi/2.3.0)（依赖 NAudio.Core 2.3.0）。Core / LocalInference 不增加 NAudio、WPF 或 Win32 依赖。

```csharp
var factory = new WasapiAudioSourceFactory();
await using var system = new AudioCaptureManager(factory, AudioInput.System);
await using var mic = new AudioCaptureManager(factory, AudioInput.Microphone);
system.Configure(settings.ListeningService.SampleRate());
mic.Configure(settings.ListeningService.SampleRate());
system.Pcm16Available += pcm => ConsumeSystemPcmPromptly(pcm);
mic.Pcm16Available += pcm => ConsumeMicPcmPromptly(pcm);
await system.StartAsync();
await mic.StartAsync();
// 检查 IsCapturing / LastError / SourceDescription，并把 Error 通知转到 UI Dispatcher。
await mic.StopAsync();
await system.StopAsync();
```

以上保留底层采集 API 的独立用法；第 5 线宿主由 `ListeningSession` 接管这些操作，`Consume*` 对应各自 provider 的 `SendAudio`。每路转换器独立，默认 16000 Hz，运行及恢复期间 `Configure` 不生效；停止后可改为 24000 Hz。输出单声道 PCM16 little-endian：16 kHz 每毫秒 32 字节，24 kHz 每毫秒 48 字节。`ListeningService.SampleRate()` 按 Windows 契约：Zipformer / Paraformer 16000，其余 24000；本批会话只接受前两者。Apple 只是保留枚举，没有实现 AppleSpeech。当前 Swift 的 `isLocal` 还包含 Apple，Windows 在这一保留值上遵循本批要求。

转换支持 PCM16/24/32 和 float32，等权下混，再用 128 tap Blackman-windowed sinc 滤波重采样，避免直接抽点混叠。分块边界可落在单个采样字节中；状态跨块保留，停止/重置与转换互斥。重采样有约 63.5 个输入帧的固定滤波延迟（48 kHz 约 1.32 ms），停止时丢弃滤波尾部和不完整输入帧，不在停止后补发音频。同步回调不创建音频队列；消费者应快速返回，不能在回调内同步等待 `StopAsync`。若消费过慢导致 WASAPI discontinuity，明确报错而不是把缺失段伪装成静音。

麦克风使用默认 Capture / Console endpoint 的 shared-mode WASAPI；系统音频在 Windows build 20348+ 优先通过 `ActivateAudioInterfaceAsync` + `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK` + `EXCLUDE_TARGET_PROCESS_TREE` 排除当前进程及子进程，再用 NAudio `AudioClient` / `AudioCaptureClient` 读取。这个公开模式跨所有 render endpoints，而不是只绑定默认输出；见 [Microsoft Application Loopback 示例](https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/)。旧系统或激活/初始化失败时，回退到默认 Render / Console endpoint 的 WASAPI loopback，**包含本程序音频**；`SourceDescription` 写明模式与回退原因，不声称排除成功，也不以合成静音代替采集。进程激活最多等待 5 秒，迟到的 COM 结果会释放；本批没有虚拟声卡依赖。

原生源用单个 MTA worker 拥有 COM client 和事件句柄，启动返回前实际完成 `IAudioClient.Start`，停止等待 worker 退出并释放资源。endpoint 通知和 device-invalidated 错误触发设备变更：麦克风在滚动 30 秒内最多恢复 3 次，每次先重开；失败后等待 500 ms，仅再试一次。拒绝隐私权限不重试；超限/再次失败明确停止并提示检查设置后重新开始。系统设备变化直接报错停止。麦克风 5 秒无任何数据包也进入有界恢复；系统 loopback 在没有播放声音时不产生包是正常状态。无设备、隐私拒绝、启动失败、数据丢失都有可读错误。

## 第 4 线：浮窗与快捷键

`OverlayWindow` 是可复用壳：Topmost、透明无边框卡片、`ShowActivated=false`，HWND 增加 `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`，`WM_MOUSEACTIVATE` 返回 `MA_NOACTIVATE`。默认工作区右上方 24 DIP 边距，尺寸属性 min 400×240 / max 700×1000。所有定位/自动高度/贴边经过已有 `OverlayLayout.Fitted`，因此自动拟合保留 Core 的 900 高度上限；没有修改 Core 几何常量。DIP 与 Win32 物理像素按窗口 DPI 转换，Y 轴通过 `yCore = -top - height` 翻转，支持负坐标显示器。宿主 manifest 启用 PerMonitorV2；独立宿主也应声明 DPI awareness。

`Configure(AppSettings)` 应在偏好变化时由 UI 线程调用，`ContentHeightChanged` 接受卡片内容高度，第 5 线增加 `SetContent(OverlayContent)` 用于状态和转写。贴边隐藏复用 `OverlayHoverState`，右边缘停留 0.16 秒显示、离开 0.9 秒隐藏，交互重置计时；隐藏保留 HWND 和轮询以便跨显示器唤回。贴边关闭时允许拖动，打开时禁用自由拖动。卡片没有完整对话区、设置页、分栏 UI 或手动缩放手柄；既有 `OverlayLayout.Panes` 保留供未来完整 UI 使用。

捕获排除由 `ExcludeOverlayFromCapture` 显式选择，默认 false。HWND 建立后调用 `SetWindowDisplayAffinity(hwnd, 0x00000011)`；关闭则调用 `WDA_NONE (0)`，DPI/显示器变化和句柄初始化时重新应用。`CaptureProtectionStatus` 暴露 HWND、请求标志、真实 BOOL 返回值和错误码；未有 HWND 时返回值为 null。API 成功只说明请求被接受，**没有证明 Teams / Zoom / 腾讯会议的共享画面隐藏成功**。Windows 10 2004 前的兼容行为也不同，见 [SetWindowDisplayAffinity 官方说明](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity)。需在真实会议客户端分别验收整屏/窗口共享；Topmost/tool-window 不等价于 Mac `canJoinAllSpaces`，不会自动固定到所有虚拟桌面，也不保证覆盖独占全屏、UAC 安全桌面或更高权限窗口。

`HotkeyStore(IPreferenceStore)` 使用原键 `hotkeyCombos.v1` / `overlayHotkey.v1`，JSON 的角色名为 `reply` / `recap` / `followUp`，组合字段为 `keyCode` / `modifiers`。数值是 Windows VK / MOD，不是 Carbon 物理键码，不自动导入 Mac 数值。默认 Reply Ctrl+Alt+Space、Recap Ctrl+Alt+S、FollowUp Ctrl+Alt+X、显示/隐藏 Alt+H。跨全部角色检查唯一性；reset 仅在默认键空闲时生效；损坏或冲突的持久化快照回退默认值且读取不写盘。

`Win32HotkeyRegistrar` 在运行 Dispatcher 的线程创建 message-only HWND；`WM_HOTKEY` 在该线程调用回调，设置 `MOD_NOREPEAT`。Store 改动自动整组重建，recording 时全部注销，禁用全部 conversation modes 后仍保留 overlay。注册冲突会撤销本次已成功的注册，给出组合和 Win32 错误码；Dispose 注销全部并销毁 HWND。重建换用新 ID，拒绝旧消息。详情见 [RegisterHotKey 官方说明](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey)。真实快捷键手感、焦点保持和与会议软件冲突不能靠 CI 验收。

## 假源测试与已有 CI

测试通过 `IAudioSourceFactory` 注入已知 PCM，不访问声卡；覆盖 16/24 kHz 字节时长、整数/float、下混、1 kHz 保真与高频混叠抑制、任意分块、同步发出、独立转换器、停止竞态和有界恢复。`ICaptureClock` 假时钟控制 500 ms 重试及 30 秒预算，不用真实等待。快捷键用假 registrar 验证收到的组合、no-repeat、整组回滚和回调；窗口用假 display-affinity API 验证 HWND/标志/错误，纯几何测试覆盖 DPI、负坐标、悬停时序。

2026-11-12 第 4 线 Linux 最终验证：完整 solution Release 构建 **0 warnings / 0 errors**；Core **164 通过、0 跳过**，LocalInference **61 通过、2 个缺模型跳过**，Platform **72 通过、2 个 Windows 桌面探针跳过**，全部 0 失败。新增采样率测试位于 Platform.Tests，以保留原 Core 164 项回归测试。构建日志及三套 TRX 位于 `/workspace/codex/livecopilot-windows/validation/`，文件名均带 `line4`，没有覆盖 line1–3 日志。

`Platform.Tests` 同时编译 net8.0 / net8.0-windows。Linux 只运行 `-f net8.0`，两项 HWND / RegisterHotKey 探针显式 skip。Windows CI 可运行 `-f net8.0-windows`，假源测试同样不需要麦克风；默认不设置 `LIVECOPILOT_WINDOWS_INTEGRATION`，两项交互探针也 skip。真机可设置该变量为 `1`，运行 `--filter FullyQualifiedName~WindowsIntegrationTests`；特殊 Ctrl+Alt+Shift+F24 探针被外部程序占用时会给出明确 Win32 失败信息，需关闭冲突程序。此变量不应在无交互桌面的 runner 中启用。本批未添加真实 WASAPI 集成测试，声卡、隐私弹窗、切换设备和进程排除均留待真机验收。

第 5 线会话测试复用音频假源并加入可控制 Ready、PCM、Failed、Closed 与 flush 的 `FakeLiveProvider`，不需要声卡、WPF runtime 或权重。覆盖无自动启动、16 kHz 路由（10 ms = 320 字节）、两路身份与合并、热词调用顺序、异步模型失败、初始化异常、采集回滚、PCM 回调失败不死锁、幂等/取消/重启、停止顺序、最终片段落盘、空会话不写盘、保存/停止错误及诚实的快捷键请求。临时会话目录在测试结束后删除。

2026-11-12 第 5 线 Linux 验收：完整 solution Release 构建 **0 warnings / 0 errors**（包括 WPF App 和 Platform.Tests 的两个目标）；Core **164 通过、0 跳过**，LocalInference **61 通过、2 个缺模型跳过**，Platform `net8.0` **109 通过、2 个 Windows 桌面探针跳过**，全部 0 失败。Platform 为原有 72 项加 37 项会话测试。证据为 validation 目录中的 `Build.Release.line5.log`、`Core.Release.line5.trx`、`LocalInference.Release.line5.trx`、`Platform.Release.line5.trx`，报告位于 `/workspace/codex/livecopilot-windows/REPORT_SESSION.md`。

本批**未编辑 `.github/workflows/`**。接受的合并已经包含第 2 线 Core / LocalInference / Platform 测试及可选 App build；新增会话测试位于原 Platform.Tests 项目，已有 CI 会自动发现。以下为本地 Windows 复现命令（PowerShell，工作目录 `Windows`），不是新增工作流：

```powershell
$env:LIVECOPILOT_INFERENCE_CPU = "1"
dotnet restore LiveCopilot.Windows.sln
dotnet build LiveCopilot.Windows.sln -c Release --no-restore
dotnet test tests/LiveCopilot.Core.Tests/LiveCopilot.Core.Tests.csproj -c Release --no-build --logger "trx;LogFileName=Core.Release.line5.trx" --results-directory TestResults
dotnet test tests/LiveCopilot.LocalInference.Tests/LiveCopilot.LocalInference.Tests.csproj -c Release --no-build --logger "trx;LogFileName=LocalInference.Release.line5.trx" --results-directory TestResults
dotnet test tests/LiveCopilot.Platform.Tests/LiveCopilot.Platform.Tests.csproj -c Release -f net8.0-windows --no-build --logger "trx;LogFileName=Platform.Windows.Release.line5.trx" --results-directory TestResults
```

以上本地命令将 TRX 写到 `Windows/TestResults`；不要下载模型或在无交互桌面时启用真机探针。Linux 本轮独立证据使用前文 validation 目录中的 `line5` 文件，保留 `line4` 及更早产物。

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

- 不实现完整 OverlayView 对话 UI、设置、入门或文档导入 UI；第 5 线只增加聆听控制与转写卡片。
- Laya / MLX、决策模型分类器、AppCoordinator、云 Live providers 与回答推理留待后续；本批仅接入本地语音识别。
- WASAPI 真机设备/权限/进程排除、会议共享隐藏和全局快捷键体验尚未验收；没有签名、安装器或发行打包。
- 不翻译 `AppleSpeech*`、`AppleLiveProvider`、`Laya*`、`AudioFlowMonitor`、`EchoMonitor`、`AppCoordinator`。
- 不新增 `OnboardingStore` 或 `DocumentImport`，不实现真实服务凭据管理。既有设置中的云服务兼容字段不代表真实网络服务已经接入。
- 不修改 Mac 源码或资源，不进行签名、推送、PR、远程配置修改。
