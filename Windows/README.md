# LiveCopilot Windows：未签名安装包与 CI 冒烟截图（第 9 线）

本目录承接 Swift 版本中可独立测试的领域模型、配置、分析预设、状态存储及本地 ASR / embedding，使用 C# 12 / .NET 8。第 4 线增加 WASAPI 音频、WPF 浮窗壳和全局快捷键；第 5 线通过可测试的 `ListeningSession` 连接双路采集与本地语音识别。第 6 线接入手动云端回答 / 总结 / 追问、流式浮窗正文及 Windows 凭据存储；第 7 线增加文档导入、知识库检索和浮窗来源；第 8 线增加中文分页设置窗口，集中管理通用、服务、知识库与快捷键配置。第 13 线接入 OpenAI 云端实时转写与语义提问自动回答。原有 `StealthApp/` 源码与资源保持不变。

## 安装与首次运行

1. 打开仓库 **Actions → Windows unsigned packages and smoke**，选择成功的运行。在页面底部 Artifacts 下载 `LiveCopilot-win-arm64-<run number>` 或 `LiveCopilot-win-x64-<run number>`。产物保留 **14 天**，过期后重新运行 workflow；这里不创建 GitHub Release 或 tag。
2. Windows 11 ARM（包括 Mac M4 Max 上的 Windows ARM 虚拟机）优先选 **win-arm64**；普通 Intel/AMD Windows 选 **win-x64**。ARM 虚拟机遇到本地依赖或驱动问题时，可使用 Windows 的 x64 仿真运行 x64 包。两个架构使用相同安装标识，切换前退出应用并卸载旧架构；临时对比可分别解压便携包，避免同时运行。
3. 解压 Actions artifact，运行其中的 `*Setup.exe`，按当前用户安装，无需预装 .NET。安装包和程序**未签名**；SmartScreen 拦截时，确认下载自该仓库 Actions，再点击 **“更多信息”→“仍要运行”**。无需申请或安装证书。也可解压其中的 `*Portable.zip`，在解压目录运行 `LiveCopilot.App.exe`；不要直接从 zip 内运行。
4. 首次启动不会自动开始聆听、下载模型或检查更新。打开“设置”查看六个页面；模型不随包分发，没安装模型时会显示提示。“关于”页的更新开关默认关闭；本版本没有更新源，开启或点击“检查更新”也不联网。云端服务只有在配置凭据并主动使用功能时才会请求；OpenAI 云端听写在第 13 线接入，选择引擎与打开设置本身不会连接。

安装目录为 `%LOCALAPPDATA%\LiveCopilot.Windows`，与数据目录 **`%LOCALAPPDATA%\LiveCopilot`** 分开。安装版与便携版均使用此数据目录，内含 `preferences`、`Models`、知识库和会话记录；便携包不会把用户数据写在程序旁边。服务密钥独立保存于 Windows 凭据管理器，未写入偏好文件。

卸载：先退出 LiveCopilot，在 Windows **设置 → 应用 → 已安装的应用 → LiveCopilot Windows → 卸载**；便携版删除解压目录即可。卸载保留用户数据。需要彻底清理时，先备份所需会话和文档，再手动删除 `%LOCALAPPDATA%\LiveCopilot`，并在 Windows 凭据管理器中删除 LiveCopilot 对应条目。

两个架构的安装包均只包含 CPU 本地推理后端，无需安装 CUDA / Vulkan。固定版本 sherpa-onnx 1.13.8 和 LLamaSharp CPU 0.27.0 均提供 Windows ARM64 DLL；NAudio.Wasapi 2.3.0 通过系统 WASAPI/COM 工作，无需额外的架构原生包。“关于”页说明本地听写与嵌入默认使用 CPU；若 ARM64 原生运行库缺失或不兼容，对应设置页与操作错误提示重新安装对应架构的完整 Windows 包。包内有 DLL 不代表 ARM 虚拟机的音频、模型推理已经通过验收，需在目标机器手动验证。

### 安装包体积（第 10b 线）

Release 发布继续包含 .NET 8 / Windows Desktop Runtime（self-contained），无需用户预装 .NET。已移除 `LLamaSharp.Backend.Cuda12` 与 `LLamaSharp.Backend.Vulkan`；打包前检查禁止这些 GPU 资产进入 Setup / Portable 包。2026-11-15 Linux 本地发布测得：

| 架构 | 之前目录占用（约） | 当前目录占用（`du -sh`） | 当前文件字节总和 |
| --- | ---: | ---: | ---: |
| win-x64 | 779M | 211M | 209.80 MiB（219,987,749 字节） |
| win-arm64 | 212M | 212M | 210.36 MiB（220,575,688 字节） |

x64 目录占用减少约 568 MiB / 73%；ARM64 原先已排除 GPU 后端，因此基本不变。以上是**未压缩发布目录**，不代表 Setup.exe 或 Portable.zip 的下载体积；本轮没有在 Linux 生成 Windows 安装器，也没有随包加入模型。

产品项目原本已只启用 WPF；独立冒烟工具的 `UseWindowsForms` 已移除，窗口/桌面截图改用 Win32 GDI 与 WPF PNG 编码，保留空白截图检查。PowerShell watchdog 使用 Win32 读取屏幕范围，独立截图仍使用 PowerShell 自带的 System.Drawing。self-contained 的 .NET 8 Windows Desktop Runtime 仍随包带有 `System.Windows.Forms*.dll`，删除项目开关不会裁掉这些框架资产；本批保留完整框架并继续禁用 trimming，避免破坏 WPF 的动态加载。参见 [Microsoft 的 WPF trimming 限制](https://learn.microsoft.com/en-us/dotnet/core/deploying/trimming/incompatibilities#wpf)。

### 本地打包和 CI 截图

在 Windows PowerShell 7、.NET 8 SDK 环境运行：

```powershell
./Windows/tools/Package-Windows.ps1
# 可指定预发布编号：-RunNumber 123；输出目录必须是新目录。
dotnet build Windows/tests/LiveCopilot.App.Smoke/LiveCopilot.App.Smoke.csproj -c Release
./Windows/tools/Smoke-Windows.ps1
```

版本唯一来源为 `Directory.Build.props` 的 `Version`，CI 附加 `-ci.<GITHUB_RUN_NUMBER>`，例如 `0.1.0-ci.123`；vpk CLI 与应用 Velopack 包共用 `VelopackVersion`。每个 RID 独立 self-contained 发布，产物在 `Windows/artifacts/package/releases/<RID>`（Setup、Portable zip、Velopack 元数据和 SHA256SUMS）；不签名、不指定需要联网安装的运行时。

新 workflow 只由手动、push 到 `windows` 分支或相关文件的 PR 触发，权限仅 `contents: read`，无 secrets。它发布两个架构并上传包，在同一 Windows job 启动 x64 发布目录的实际 exe。`LIVECOPILOT_SMOKE=1` 使用唯一的 `%TEMP%\LiveCopilot-smoke-<GUID>` 数据目录和内存凭据，拒绝 HTTP、音频与模型调用，不注册全局快捷键、不打开浏览器；正常退出后清理临时数据。

独立 UI Automation / Win32 驱动要求主窗口在 **30 秒**内就绪，切换通用、服务、知识库、历史记录、快捷键、关于六页，每页实际选中后调用 `PrintWindow` 保存 PNG，再通过取消设置和关闭主窗口正常退出。截图 artifact `LiveCopilot-smoke-<run number>` 含七张 PNG、`result.json` 和日志，保留 14 天。窗口不出现、页面遗漏、空白截图、非零退出码或超时均失败；外层 150 秒 watchdog 处理原生调用挂起。Linux 运行该独立项目只报告 Skip，不影响三个既有测试套件；可用 `-p:BuildWindowsSmoke=true` 在 Linux 编译 Windows 驱动，但不能执行 WPF 截图。

## 解决方案结构

```text
Windows/
├── Directory.Build.props                 # Nullable、警告视为错误、Windows targeting
├── LiveCopilot.Windows.sln
├── src/
│   ├── LiveCopilot.Core/                  # net8.0，不依赖 WPF / Apple 框架
│   │   ├── Domain/                       # 领域类型、回答策略、问题状态机
│   │   ├── Analysis/                     # 模型能力、58 项预设、价格与性能参考
│   │   ├── Preferences/                  # AppSettings、偏好存储、ICredentialStore / 内存凭据
│   │   ├── Providers/                    # 接口、Responses / Chat Completions、HTTP / SSE
│   │   ├── Localization/                 # 界面翻译与可替换的语言检测接口
│   │   ├── Stores/                       # 会话、转写、建议、异步转写翻译
│   │   ├── Knowledge/                    # SQLite 索引、文本解析、分块与检索
│   │   ├── Support/                      # JSON、值语义集合、原子文件写入等
│   │   └── Resources/                    # 嵌入式 JSON 字典、提示词和分析数据
│   ├── LiveCopilot.LocalInference/        # net8.0，sherpa-onnx / LLamaSharp，独立于 Core
│   ├── LiveCopilot.Platform/              # net8.0，音频/快捷键/浮窗逻辑、聆听会话及设置 ViewModel
│   ├── LiveCopilot.Platform.Windows/      # net8.0-windows，WASAPI、Win32、WPF、Credential Manager
│   └── LiveCopilot.App/                   # net8.0-windows，聆听宿主与纯 WPF 分页设置窗口
├── tests/
│   ├── LiveCopilot.Core.Tests/            # xUnit，临时目录及合成提供器
│   ├── LiveCopilot.LocalInference.Tests/  # 无权重契约测试 + 可跳过的真实模型测试
│   └── LiveCopilot.Platform.Tests/        # net8.0 / net8.0-windows，假源测试 + 显式跳过桌面探针
└── tools/import-localization.py          # 从 Swift 只读导入界面字典的维护工具
```

Core 使用 `Microsoft.Data.Sqlite 8.0.22`。界面 JSON 资源显式设置 `WithCulture="false"`，统一嵌入 Core 程序集，避免文件名中的 `zh-Hans` / `zh-Hant` 被自动拆到卫星程序集。常规构建直接使用已提交的资源，不需要运行导入脚本；该维护脚本需要 Python 3 和 Linux ICU。

## Linux 上构建与测试

本工作区的 SDK 为 `/home/box/.dotnet` 下的 .NET SDK 8.0.428。以下命令使用已有恢复结果与依赖缓存，不发起包恢复；新环境需先另行准备依赖：

```bash
export PATH="/home/box/.dotnet:$PATH"
export DOTNET_ROOT="/home/box/.dotnet"
export DOTNET_EnableWindowsTargeting=true
export DOTNET_CLI_HOME="/tmp/dotnet-home"
export DOTNET_NOLOGO=1
export LIVECOPILOT_INFERENCE_CPU=1
cd /workspace/livecopilot-windows-settings/Windows

set -o pipefail
dotnet build LiveCopilot.Windows.sln -c Release --no-restore 2>&1 | tee /workspace/codex/livecopilot-windows/validation/Build.Release.line8.log
dotnet test tests/LiveCopilot.Core.Tests/LiveCopilot.Core.Tests.csproj -c Release --no-build --no-restore \
  --logger 'trx;LogFileName=Core.Release.line8.trx' \
  --results-directory /workspace/codex/livecopilot-windows/validation
dotnet test tests/LiveCopilot.LocalInference.Tests/LiveCopilot.LocalInference.Tests.csproj -c Release --no-build --no-restore \
  --logger 'trx;LogFileName=LocalInference.Release.line8.trx' \
  --results-directory /workspace/codex/livecopilot-windows/validation
dotnet test tests/LiveCopilot.Platform.Tests/LiveCopilot.Platform.Tests.csproj -c Release -f net8.0 --no-build --no-restore \
  --logger 'trx;LogFileName=Platform.Release.line8.trx' \
  --results-directory /workspace/codex/livecopilot-windows/validation
```

`Directory.Build.props` 也设置了 `EnableWindowsTargeting=true`；需要显式指定 MSBuild 属性时，可在命令末尾加 `-p:EnableWindowsTargeting=true`。它允许 Linux 恢复含 Windows 项目的解决方案，不代表 Linux 可以运行 WPF。其它机器请按实际 SDK 和仓库位置调整路径。

必跑测试使用合成文本、可控制完成时机的假提供器和独立临时目录，不调用付费服务、不下载模型、不读写用户真实会话。覆盖领域模型与序列化、回答语言/引用策略、全部分析配置，以及会话读写和导出、旧会话只读加载、转写修订与长归档、异步取消/超时后丢弃旧结果、SQLite 检索与失败回滚。

## 本地推理与模型目录

`LiveCopilot.LocalInference` 引用 Core，Core 不反向依赖原生包。固定依赖为 `org.k2fsa.sherpa.onnx 1.13.8`、`LLamaSharp 0.27.0` 及同版本的 `LLamaSharp.Backend.Cpu`。所有构建和测试均不再引用 LLamaSharp CUDA / Vulkan 包；发布阶段过滤其它 RID 的原生文件，x64 保留 noavx / AVX / AVX2 / AVX512 CPU 变体，ARM64 保留其 CPU DLL。

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

## 第 10 线：设置页本地模型下载管理

首次安装后，在 **设置 → 服务** 的听写引擎下下载 Zipformer（约 200 MB，支持术语）或 Paraformer（约 238 MB）；两张卡片都包含相应的 Silero VAD。使用本地知识库时，在 **设置 → 知识库** 的嵌入服务下下载 BGE-M3 Q8 GGUF（约 635 MB）。只需下载实际使用的模型，应用启动和打开设置不会自动下载。

卡片显示名称、大小、未安装/下载中/校验中/已安装/失败状态、字节进度、下载速度与进度条，提供下载、取消、继续下载/重试、校验和删除。失败原因使用中文；“校验”读取已安装文件并核对大小和 SHA256，不调用推理、不发起下载。ARM64 沿用 `NativeRuntimeSupport` 的 CPU 与缺失原生运行库提示；对应运行库不可用时禁用下载。

模型操作立即执行，无需先保存设置，也不随底部“取消”撤销。关闭设置会取消并等待未完成操作，保留已经下载的数据；再次打开后可继续。下载期间可切换设置页查看其他模型。删除会移除该模型的安装目录及下载缓存，不删除文档、向量索引、会话或其他模型；若文件正被聆听或文档任务使用，操作失败会提示停止这些任务后重试。

安装完成后，无需重启应用：听写需保存所选引擎并**重新开始聆听**；本地嵌入可直接导入或重新索引（修改嵌入服务时仍需先保存设置）。模型状态提示会刷新，不覆盖未保存的设置草稿。

实现放在已有的纯 `net8.0` 类库 `LiveCopilot.LocalInference`：`LocalModelManager` 负责状态、每模型操作互斥、取消、空间预检、校验与删除；`ResumableModelDownloader` 使用可注入 `HttpClient`。这两类不依赖 WPF、不加载原生推理库，可在 Linux 用假下载器/假 `HttpMessageHandler` 测试；Platform 仍只引用 Core，App 负责卡片绑定与 Dispatcher 通知，无需增加新项目。

- 下载严格遵循现有 `CandidateUrls` 的发行源、镜像、原站顺序；URL、SHA256 和模型清单不变。每个文件保存在 `Models/.downloads/<模型目录>/<文件名>.partial`，重试发送 HTTP Range；服务器忽略或拒绝 Range、返回不符的 Content-Range 时从头下载。网络中断/取消保留部分数据，SHA256 或大小校验失败删除临时文件。
- SHA256 通过后，同目录原子移动 `.partial` 到已校验缓存文件；全部文件就绪后复用 `LocalModelInstaller` 的暂存安装与失败回滚，完成后清理缓存。安装失败保留原有模型及可重用的已校验缓存；不承诺跨目录移动的断电事务性。
- 开始下载前检查“剩余下载量 + 完整安装副本 + 16 MiB 余量”的可用磁盘空间。同一模型的下载、校验与删除互斥，另有文件锁阻止使用同一根目录的多个管理器同时操作；不同模型可分别下载。

新增测试全部使用临时目录、4 字节合成内容和假网络，覆盖进度/速度、取消后跨管理器续传、取消校验、HTTP/校验失败时镜像回退、Range 支持/忽略/拒绝/错误范围、SHA 不符清理、空间不足、删除、并发保护、关闭收尾及安装后立即可用。不访问真实模型地址。第 9 线冒烟驱动新增服务页两张语音卡片和知识库页嵌入卡片的可见性、初始状态及下载禁用断言；仍保存原有七张截图，不触发下载。

本线 Linux 验证日志、TRX 与文件清单位于 `/workspace/codex/livecopilot-windows/validation/`，文件名含 `line10`；完整报告为 `/workspace/codex/livecopilot-windows/REPORT_MODELS.md`。Linux 可编译 WPF App 与 `-p:BuildWindowsSmoke=true` 的 Windows 冒烟驱动，不能执行 Windows 桌面截图；截图、真实模型推理和 ARM64 真机行为仍需在 Windows 验证。

## 硬件后端与部署

| 引擎 | 安装包默认后端 | CPU 强制方式 |
| --- | --- | --- |
| sherpa / ONNX Runtime | CPU（另行部署兼容运行库时才尝试 CUDA / DirectML） | `new InferenceOptions { ForceCpu = true }` |
| LLamaSharp | CPU | 同左；CPU 时 `GpuLayerCount=0` |

`LIVECOPILOT_INFERENCE_CPU=1` 也可强制 CPU；安装包不依赖此变量即可使用 CPU。`IHardwareProbe` 可注入能力集合，必跑测试覆盖 CUDA、仅 DirectML、仅 CPU。系统探测使用 CUDA driver/device count、D3D12 设备及 Vulkan loader；检测到硬件不代表后端运行库存在。提供器和实际引擎公开 `Backend` / `BackendAttempts`，可观察选择与回退。VAD 固定 CPU。

LLamaSharp 仅随包带有 CPU 原生后端。保留加载器的 `WithAutoFallback(true)`：即使检测到 GPU，缺少 CUDA / Vulkan 后端也会正常加载 CPU，不会要求用户补装 GPU 依赖。无模型回归测试显式设 `ForceCpu=false`、模拟所有 GPU 能力并实际加载原生库，确认所选后端为 CPU、未启用 GPU offload。已有的 GPU 分配/推理失败后以 0 GPU layers 重载逻辑和取消行为保留；运行库选择仍是进程级的。

sherpa 官方 C# 包带来的 Windows runtime 是 CPU 发行物。以下仅为开发者自定义 GPU 运行库的说明，标准安装包无需执行，也不随包分发这些文件。C# 配置的 `Provider` 交给 sherpa 链接的 ONNX Runtime；不能只多加一个 ORT NuGet 包就让 CPU sherpa 启用编译期开关。自定义 GPU 部署需要完整且版本一致的 sherpa 1.13.8 native 发行物：

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

宿主使用持久化的 `AppSettings`（默认 Zipformer）；第 8 线可通过主窗口「设置」修改。模型应预先放在 `%LOCALAPPDATA%/LiveCopilot/Models`，按上文清单及 receipt 安装；独立宿主/测试可向 `LocalLiveProvider` 注入其它 root。本批 UI 不下载模型、不预热 embedding、不强制 CPU。缺失、损坏、运行库错误都会明确显示失败；只有 provider 发出 Ready 后才读取并展示实际 `Backend`，未就绪时不宣称 GPU/CPU 成功。第 13 线支持 OpenAI 云端听写；缺少共享密钥或选择 Apple 听写时在打开音频源之前拒绝启动。

`ListeningSession` 位于纯 `net8.0` Platform，依赖音频工厂、`ILiveProvider` 工厂、设置快照、独占的 `TranscriptStore` 以及可选 `SessionStore` / `ICaptureClock`。Platform 仅引用 Core，不引用 LocalInference、sherpa、LLamaSharp、NAudio 或 WPF。WPF 宿主注入 `WasapiAudioSourceFactory`，每次开始为 Them / You 各创建一个新的 `LocalLiveProvider`；单次使用的 provider 在断开后不复用。`ListeningProvider` 的可选能力委托提供热词配置与已观察到的后端信息，避免向 Platform 泄漏原生实现。

两路在启动前都配置为 16000 Hz。Zipformer 在 Connect 前收到 `ProfessionalTerms`；Paraformer 不调用不支持的 `UpdateTerms`。会话等待两路 Ready 后启动采集。系统 PCM 只发给 Them，麦克风 PCM 只发给 You，均为单声道 PCM16 LE；回调直接交给 provider 快速复制/入队，不为每个音频块创建任务。正式转写用 `TranscriptStore.Ingest` 保留合并/修订规则，partials 按路径更新，停止时继续接受两路 flush 的最终片段再保存，未定稿内容不冒充正式转写。

任一路准备、模型加载或采集启动失败都会回滚整次启动；运行中 provider / 音频错误也会停止两路，保留首个原因。停止和错误处理不在 PCM 回调中同步等待，避免等待自身；启动中也能点击停止以取消等待。另一条路径仍会断开和 flush，保存失败不会阻止释放资源。失败后重新开始会清空本次显示并创建新 provider，旧会话的迟到事件不进入新转写。

快照包含 Idle / Starting / Listening / Failed / Stopped、停止中标记、错误、两路采集状态和 `SourceDescription`、后端、正式转写、partials、语音活动及最近建议模式。`Changed` 可从工作线程触发，订阅者必须快速返回，不能同步等待生命周期方法；宿主合并通知并通过 `Dispatcher.BeginInvoke` 读取最新快照。浮窗显示状态、最近 8 行 Them / You 转写及双方未定稿文本，内容变化重新测量并调用 `ContentHeightChanged`，超出高度时可滚动；保留置顶、不抢焦点、贴边隐藏与捕获排除逻辑。

第 5 线的 Ctrl+Alt+Space / Ctrl+Alt+S / Ctrl+Alt+X 只记录回答/总结/追问请求；第 6 线宿主现已提供真实推理工厂，行为见下文。独立使用 `ListeningSession` 而不注入推理工厂时，仍准确显示“已请求回答，推理服务尚未接入”等提示，正文为空。禁用模式不响应，Alt+H 仍控制浮窗显示/隐藏。构造、打开浮窗和按建议快捷键均不会自动开始采集。

## 第 6 线：手动云端建议与 API 密钥

第 8 线已将主窗口密钥行迁移到「设置 → 服务」，默认推理服务仍为 SharedOpenAI。输入 PasswordBox 后点击设置页底部「保存」，密钥经 `ICredentialStore` 写入当前 Windows 用户的 **Windows Credential Manager generic credential**；输入框随即清空，仅显示保存状态和末 4 位，长度不超过 4 的值完全遮罩。「清除」先标记待清除，保存后才删除；留空输入不删除已保存密钥。「取消」丢弃待保存或待清除操作。凭据目标仍为 `LiveCopilot-Credentials-v1/` 加 `reference.Service + "|" + reference.Account`，不写明文文件、偏好 JSON、诊断文本或日志。Credential Manager 失败会显示安全错误，未采用 DPAPI 文件回退。Core 的 `MemoryCredentialStore` 仅保存进程内数据，供 Linux 和测试使用。

仅在当前凭据账户没有密钥时，宿主工厂才读取环境变量：SharedOpenAI / SeparateOpenAI 使用 `OPENAI_API_KEY`，DeepSeek 使用 `DEEPSEEK_API_KEY`。环境值不会自动保存；清除已保存密钥后，已有环境变量仍可作为回退。Qwen / GLM / Kimi / compatible 没有环境变量回退，不读取 Live 的密钥。不要把密钥写进命令记录、设置 JSON 或仓库。缺少密钥时提示“请先配置分析服务 API 密钥”，缺少模型或无效 endpoint 明确失败，不切换服务。

`ReasoningProviderFactory` 支持：

| 设置服务 | HTTP 协议与配置 |
| --- | --- |
| SharedOpenAI / SeparateOpenAI | `https://api.openai.com/v1/responses`，分别使用 Live / 独立分析账户；显式发送 `store: false`、`service_tier` 和规范化 effort |
| DeepSeek | `https://api.deepseek.com/chat/completions`，独立密钥及 `DeepSeekEffort` |
| Qwen / GLM / Kimi | 使用现有 preset connection 的 endpoint / model / thinking；只发送该厂商字段，Kimi K3 不发送 K2.x thinking 开关 |
| Compatible | 使用设置中的 HTTPS base URL、API path 与 model，默认不附加厂商 thinking 或采样字段 |

开始聆听并获得正式转写或 Them 未定稿文本后，按回答 / 总结 / 追问快捷键发起请求。Reply 使用最新 Them / partial 文本的简单启发式；另外两种使用 Mac 同款任务提示词。请求复用 `RetrievalQuery` 和 `AnswerRequest`，携带场景、语言、双语及附加指令；关闭 `IncludeConversation` 时不会把对话上下文放入请求或检索语义字段，但仍要求本地有可回答内容。空对话提示“还没有对话。先开始听写，或等有转写后再请求。”，不调用工厂或网络。

每次请求有独立的 `SuggestionStore`，使用 `AppendDelta` 的引用清理，并通过同一会话锁发布不可变快照。浮窗按 `AnswerFontSize` 显示状态及逐步到达的答案正文，不显示 `reasoning_content` 或思考正文。新请求会取消并隔离旧请求；停止、释放和重新开始聆听也会取消旧建议。90 秒超时显示“回答超时，请手动重试。”，保留已到达的部分正文，迟到增量不会覆盖新答案。主窗口“停止”也可取消停止聆听后发起的建议。启动应用不自动聆听、不发送建议请求；即使设置中的 `AutomaticSuggestions` 为 true，本批也只响应手动快捷键。

第 6 线验收时尚未接入文档 RAG，Sources 始终为空；第 7 线已按下节接入。无证据时，General / Hybrid 的 `AnswerRequest.Input` 仍明确告知 `No local evidence retrieved.`；KnowledgeBaseOnly 使用既有 `AnswerLanguage.MissingEvidence`（支持双语）并结束，不创建分析提供器、不调用回答模型。建议正文当前仅在浮窗中以纯文本显示，不解析 Markdown，也不写入会话回答历史；原有正式转写保存保持不变。

Core 的 `IHttpTransport` 可注入，真实 `HttpClientTransport` 使用 90 秒期限并在流式非 2xx 时最多读取 8192 字节错误体。UTF-8 framer 保留 LF / CRLF / CR 和空行，SSE 按空行分发、多 `data:` 行以换行拼接，单个事件最多 1,048,576 字节。无效 UTF-8、超大事件、缺少完成信号和中断都有明确错误；HTTP / in-stream 服务错误统一使用现有 `ServiceHTTPFailure` 安全分类，不展示服务原始错误体。

Core.Tests 使用 fake transport / fake `HttpMessageHandler` 和固定字节，不发真实 HTTP；测试请求字段、各厂商差异、密钥路由、环境回退、SSE、错误和内存凭据。Platform.Tests 使用可控制增量及故意忽略取消的 fake provider，验证流式快照、旧流隔离、停止 / 释放、超时、空对话和无证据路径。新增测试均在已有项目，CI 自动发现，无需修改 `.github/workflows/`。Windows Credential Manager 和 WPF 仅完成交叉编译，本批未运行真实 Windows 凭据 / 桌面验收，也未调用云服务或下载权重。

2026-11-13 第 6 线 Linux 验收：solution Release **0 warnings / 0 errors**；Core **241 通过**（原 164 + 新增 77），LocalInference **61 通过、2 跳过**，Platform `net8.0` **129 通过、2 跳过**（原 109 + 新增 20），全部 **0 失败**。证据位于 `/workspace/codex/livecopilot-windows/validation/` 的 `Build.Release.line6.log`、`Core.Release.line6.trx`、`LocalInference.Release.line6.trx`、`Platform.Release.line6.trx`；未覆盖 `line5` 或更早产物。详细命令和限制见 `/workspace/codex/livecopilot-windows/REPORT_REASONING.md`。

## 第 7 线：文档导入与知识库检索

1. 第 8 线从主窗口「设置 → 知识库」选择回答模式：通用、混合或仅知识库。选择 OpenAI 或本地 BGE-M3 embedding，并配置 OpenAI 嵌入模型和检索数量；点击「保存」后经已有 `AppSettings` / `FilePreferenceStore` 持久化，重启后恢复。OpenAI 默认模型为 `text-embedding-3-small`，当前模型身份显示在下方。
2. OpenAI embedding 使用「设置 → 服务」中的共享 OpenAI 密钥 `CredentialReference.Live`，缺失时回退 `OPENAI_API_KEY`。独立推理密钥不用于 embedding。密钥仍存 Windows Credential Manager，不写入偏好文件。清除保存的密钥不会清除进程环境变量。
3. 点击「导入文档」多选本地 PDF、MD、Markdown、TXT、DOCX。文档列表显示名称、状态、分块数和 embedding 模型；操作期间禁用导入、重建、删除和知识库选项，显示当前文件与进度。选中文档可重新索引或删除；删除仅移除知识库内的副本和索引，不删除外部原文件。多文件批次按顺序处理，某个文件失败时停止后续导入，之前成功的文件保留。
4. 开始聆听并积累对话后，使用回答 `Ctrl+Alt+Space`、总结 `Ctrl+Alt+S` 或追问 `Ctrl+Alt+X`。浮窗在正文下方显示检索来源（`[S编号] 文档名 · 第 N 页`），以及降级警告；TXT/MD/DOCX 不虚构页码。来源数量受 `RetrievalCount` 限制，默认 5；编号只来自实际命中的分块，继续复用 `CitationPolicy` 去除越界引用。

知识库目录为 `%LOCALAPPDATA%/LiveCopilot/Knowledge`：`knowledge.sqlite` 保存元数据、FTS5 和向量，`originals/<文档 ID>/` 保存原文副本。切换 embedding 服务/模型不会自动重新索引；旧索引仍可做关键词检索，需要语义检索时选中文档重建。复用既有 24 条一批、最多 4,000 分块、事务替换和失败保留旧索引的行为。导入本地 BGE-M3 前须已有通过校验的模型安装；未安装会中文提示，本界面不下载模型。

| 模式 | 检索及回答行为 |
| --- | --- |
| 通用 | 会话请求不读取文档、不创建 embedding 提供器，按通用知识与对话回答。 |
| 混合 | 有 `ChunkCount > 0` 的文档才检索；仅模型身份匹配时对 `RetrievalQuery.Semantic` 计算向量。语义失败警告「语义检索不可用，已改用本地关键词检索」；数据库失败警告后继续通用回答。 |
| 仅知识库 | 检索流程与混合相同；无来源或数据库失败时使用 MissingEvidence，不创建分析提供器、不调用回答模型。 |

`IKnowledgeRetriever` 与 embedding 工厂使会话可注入假实现，Platform 不依赖 LocalInference、WPF 或 NAudio。当前请求保留发起时的知识库设置，设置修改影响下次请求。原有替换请求、停止、销毁、90 秒超时和迟到结果拒绝逻辑继续生效，期限包含检索时间。

解析器位于 net8.0 的 `LiveCopilot.Platform/Knowledge`，固定使用纯托管 `PdfPig 0.1.11`（命名空间 UglyToad.PdfPig）逐页提取 PDF；依赖不加到 Core。DOCX 直接用 `ZipArchive` 与禁用 DTD/外部实体的 XML reader 提取正文段落和表格单元格，不引入 OpenXml SDK。TXT/MD 支持严格 UTF-8（可带 BOM）、UTF-16 LE/BE（必须带 BOM）。只接受本地支持格式的常规文件，拒绝目录、文件链接及网络路径，按规范化路径保持顺序去重。文件超过 50,000,000 字节拒绝；DOCX 解压正文另有相同上限。加密/损坏文件给出中文错误；扫描版 PDF 和空文本提示先 OCR，本批不实现 OCR、复杂版面还原、DOCX 图片/批注/页眉页脚或页码推断。

OpenAI 会接收导入文档分块和检索问题；本地 embedding 不上传这部分文本。检索命中的原文会随 `AnswerRequest` 发送给所选分析服务，本地 embedding 不代表回答模型离线。词法检索保留原有中文二元词与覆盖率门槛，语义结果保留原有相似度门槛；来源是检索候选，不保证每个候选都支持模型的每一句话。

新增测试都放在原 Core.Tests / Platform.Tests 内，现有 CI 自动发现。测试仅用假 HTTP / embedding / reasoning、临时 SQLite 和运行时生成的 PDF/DOCX/TXT；包括中文 PDF ToUnicode、密码加密 PDF、UTF-16、大小限制、非法输入、三模式、模型身份、回退、取消/超时与来源显示，不下载字体、模型或二进制夹具。Linux 完成 WPF 交叉编译，文件选择器、凭据管理器和真实浮窗视觉仍需 Windows 真机复测。

第 7 线证据写入 `/workspace/codex/livecopilot-windows/validation/` 的 `Build.Release.line7.log`、`Core.Release.line7.trx`、`LocalInference.Release.line7.trx`、`Platform.Release.line7.trx`、`Files.line7.txt`，不覆盖 line5/line6。完整命令、计数与限制见 `/workspace/codex/livecopilot-windows/REPORT_KNOWLEDGE.md`。已有依赖缓存时可离线运行（工作目录 `Windows`）：

第 7 线 Linux Release 验收：完整 solution（含 WPF App）**0 warnings / 0 errors**；Core **273 通过**（241 + 32），LocalInference **61 通过、2 跳过**，Platform `net8.0` **198 通过、2 跳过**（129 + 69），全部 **0 失败**。未改变原有测试断言或警告策略。

```bash
export PATH=/home/box/.dotnet:$PATH DOTNET_EnableWindowsTargeting=true
export DOTNET_CLI_HOME=/tmp/dotnet-home LIVECOPILOT_INFERENCE_CPU=1
# 本次禁用远程包源与在线 NuGet 审计，保持 TreatWarningsAsErrors。
export RestoreSources=/tmp/dotnet-home/.nuget/packages NuGetAudit=false
dotnet build LiveCopilot.Windows.sln -c Release
dotnet test tests/LiveCopilot.Core.Tests/LiveCopilot.Core.Tests.csproj -c Release --no-build --no-restore
dotnet test tests/LiveCopilot.LocalInference.Tests/LiveCopilot.LocalInference.Tests.csproj -c Release --no-build --no-restore
dotnet test tests/LiveCopilot.Platform.Tests/LiveCopilot.Platform.Tests.csproj -c Release -f net8.0 --no-build --no-restore
```

## 第 8 线：完整设置页

主窗口点击「设置」打开独立窗口，左侧依次为通用、服务、知识库、历史记录、快捷键、关于。原主窗口中的密钥和知识库控件已迁入设置页；开始/停止聆听、状态和浮窗主流程保持不变。设置逻辑位于纯 `net8.0` 的 `LiveCopilot.Platform/Settings`，使用简单 MVVM 与 `RelayCommand`，不引用 WPF、NAudio 或 LocalInference；WPF 只负责绑定、密码输入、按键录制和文档操作宿主。

| 页面 | 可配置内容与校验 |
| --- | --- |
| 通用 | 界面语言、回答语言、场景、自动建议开关、连续提问策略、双语回答、附加指令（最多 4000 个 UTF-16 单元）；转写/回答字体均为 11–28，支持浮窗自动高度和共享屏幕时隐藏浮窗。 |
| 服务 | 听写引擎和语言；推理服务、来自 `AnalysisModelCatalog` 的模型及其支持的推理强度；共享/独立 OpenAI、DeepSeek、兼容接口和当前预设服务的密钥。兼容 BaseURL 必须为 HTTPS，Path 与 Model 必填；拒绝 URL 凭据、查询参数和路径跳转。 |
| 知识库 | 通用/混合/仅知识库模式，OpenAI/本地 BGE-M3 嵌入服务、模型、检索数量（整数 3–8）；导入、删除和重新索引沿用第 7 线逻辑。嵌入身份变化立即提示保存后重建索引，模式或检索数量变化无需重建。 |
| 历史记录 | 显示「即将推出」，本批不提供历史浏览。 |
| 快捷键 | 列出回答、总结、追问、显示/隐藏浮窗；支持单项录制/恢复默认和全部恢复默认，重复绑定及 Windows 保留组合给出中文错误。 |
| 关于 | 从宿主程序集读取版本，显示项目地址 `https://github.com/carey-bk/LiveCopilot` 与未签名说明：确认来源可信后，在 SmartScreen 选择「更多信息 → 仍要运行」。 |

修改时即时校验，错误会禁用「保存」；数字输入为空、非数字、非有限值或超出范围都会保留错误，修正后方可保存。「保存」写入 `AppSettings`、凭据和快捷键，再通知会话及浮窗刷新。转写/回答字号、自动高度与捕获排除立即更新；新回答使用已保存的服务、模型、密钥和回答选项，进行中的回答保留发起时的配置。听写引擎在下次开始聆听时生效，修改不会导致正在启动的两路使用不同引擎。保存通知的订阅者异常会单独隔离并提示，不回滚已经成功持久化的设置。

「取消」或关闭窗口会丢弃未保存的偏好、密钥与快捷键草稿；上一次成功保存的内容继续有效。凭据只经 `ICredentialStore` 读写，不参与 `AppSettings` 序列化或 `ToString`；兼容接口凭据按 endpoint 隔离，更换地址会清空待保存密钥。保存失败时尝试恢复之前的偏好、凭据和快捷键；恢复不完整会明确提示重新打开核对，不承诺跨存储的断电事务。

文档操作前必须先保存设置；导入、删除和重建会立即执行，不随「取消」撤销。操作期间禁用设置编辑、保存、取消及重复文档操作，关闭窗口会取消并等待任务收尾。录制快捷键时暂停全局绑定，按 Esc、点击鼠标、切换页面或失去焦点结束录制；保存后重新注册，外部程序占用组合时仍需在 Windows 中更换绑定。

未安装本地模型时显示中文提示，可在服务/知识库页的模型卡片下载，详见第 10 线说明。Apple 听写在 Windows 上仍不可用，OpenAI 云端已在第 13 线接入；本地双语模型自动识别中英文，听写语言不强制过滤识别结果。界面语言偏好会保存，本批设置窗口文案固定为中文；OpenAI 云端支持自动建议与连续提问策略，本地语音的 Jev / Laya 自动触发仍即将推出。共享隐藏请求是否被会议软件实际遵守需要 Windows 真机验证。

2026-11-15 第 8 线 Linux Release 验收：完整 solution（含 WPF App 和 Platform.Tests 两个目标）**0 warnings / 0 errors**；Core **279 通过**（273 + 6），LocalInference **61 通过、2 跳过**，Platform `net8.0` **277 通过、2 跳过**（198 + 79），全部 **0 失败**。新增测试覆盖默认值、即时范围校验、保存/取消、文件持久化、凭据隔离与安全错误、快捷键冲突与回滚、重建提示、保存通知异常隔离和会话配置快照；既有测试断言及 `TreatWarningsAsErrors` 未改变。

最终证据位于 `/workspace/codex/livecopilot-windows/validation/`：`Build.Release.line8.log`、三套 `*.Release.line8.log` / `*.Release.line8.trx`、`Files.line8.txt`；详细报告为 `/workspace/codex/livecopilot-windows/REPORT_SETTINGS.md`。本轮只使用缓存构建与假源测试，没有真实网络调用、模型下载或权重/二进制提交。Linux 未运行 WPF 设置交互、Windows 凭据管理器、真实全局快捷键与会议共享隐藏；两项真实模型测试因缺少模型跳过，两项 Windows 桌面探针在 Linux 跳过。

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

`Configure(AppSettings)` 应在偏好变化时由 UI 线程调用，第 8 线已由设置保存接入；`ContentHeightChanged` 接受卡片内容高度，第 5 线增加 `SetContent(OverlayContent)` 用于状态和转写。贴边隐藏复用 `OverlayHoverState`，右边缘停留 0.16 秒显示、离开 0.9 秒隐藏，交互重置计时；隐藏保留 HWND 和轮询以便跨显示器唤回。贴边关闭时允许拖动，打开时禁用自由拖动。设置页使用独立窗口；浮窗卡片没有完整对话区、分栏 UI 或手动缩放手柄，既有 `OverlayLayout.Panes` 保留供未来完整 UI 使用。

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
- `IReasoningProvider`、`IEmbeddingProvider`、`ILiveProvider` 契约保持不变。第 6 线 Core 新增可注入的云推理 HTTP 实现；LocalInference 仍只实现本地语音与 embedding，音频采集留在 Platform。分析模型、价格和性能数据是仓库内 Swift 版本的快照，不进行在线刷新。
- Core 的 `TextDocumentParser` 保留轻量 TXT / Markdown 解析；WPF 宿主使用第 7 线 Platform 的完整 `DocumentParser` 和 `DocumentImport.Validate`。PDF / DOCX 不需要原生解析器或 Office，KnowledgeIndex 继续负责导入、重建和检索。
- 界面简体字典与繁体转换快照保留原文边界，不转换用户文档或对话。自动回答语言使用可注入的 `ITextLanguageDetector`，默认实现为跨平台启发式，与 Apple NaturalLanguage 的统计结果不保证逐句一致。

## 明确不在本批范围

- 不实现完整 OverlayView 对话 UI 或入门；第 8 线已提供独立设置页及迁移后的知识库管理，历史记录仅显示占位。
- Laya / Jev / MLX、决策模型分类器、完整 AppCoordinator 和本地自动建议留待后续；文档导入、手动请求 RAG 与 OpenAI embeddings HTTP 已接入。
- WASAPI 真机设备/权限/进程排除、会议共享隐藏和全局快捷键体验尚未验收；没有签名、安装器或发行打包。
- 不翻译 `AppleSpeech*`、`AppleLiveProvider`、`Laya*`、`AudioFlowMonitor`、`EchoMonitor`、`AppCoordinator`。
- 不新增 `OnboardingStore`；后续仍需决策模型、Windows 真机与真实云服务验收、签名及发行打包。
- 不修改 Mac 源码或资源，不进行签名、推送、PR、远程配置修改。

## 第 13 线：OpenAI 云端实时转写

「设置 → 服务 → 语音识别」和首次引导可选择 OpenAI 云端 · GPT-Live-1。价格沿用 Mac `ServiceGuide.LivePrice`：每路 $0.05/分钟，双路约 $0.10/分钟，连接静音也计时；回答模型和工具另计。使用「分析与回答 → API Key」中的共享 OpenAI 密钥（`CredentialReference.Live`）；云端语音工厂不读取环境密钥。保存配置不会连接；点击“开始聆听”后才连接，所有启用路径就绪后才开始采集。

Core 的 `OpenAILiveProvider` 使用 .NET `ClientWebSocket`，遵循 Mac `/v1/live/sessions` 协议（`session.start`、24 kHz 单声道 PCM16 Base64、`session.input_audio.append`）。语义完整提问委托进入已有回答/RAG/历史链路；自身麦克风不触发回答，重复委托和已回答问题被抑制。自动开关在云端语音卡片中，连续提问策略在“实时回答触发”页；Jev / Laya 保持即将推出。

启动超时 20 秒，网络故障最多重连 3 次（1/2/4 秒），重连保留最近上下文并丢弃待发音频。停止发送 `session.close` 并最多等待 8 秒，让最后转写进入历史；未确认完成会明确提示。错误仅显示安全分类，不显示服务端原始消息。

新增测试仅使用进程内 loopback `HttpListener` WebSocket 和假 key，无生产依赖、真实 API 或费用。Smoke 添加 `services-speech-openai.png`，总数 34，断言云端价格、标签和说明卡完整可见；Smoke 模式在读取凭据或建立 WebSocket 前阻断连接。Linux 可交叉编译 Windows Smoke，实际 UIA 截图仍需 Windows 桌面。
