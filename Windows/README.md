# LiveCopilot Windows：第一批 Core / Stores

本目录承接 Swift 版本中可独立测试的领域模型、配置、分析预设和状态存储逻辑，使用 C# 12 / .NET 8。WPF 项目目前只有一个空窗口，尚不是可用的 Windows 客户端。原有 `StealthApp/` 源码与资源保持不变。

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
│   └── LiveCopilot.App/                   # net8.0-windows，WPF 空壳
├── tests/LiveCopilot.Core.Tests/          # xUnit，临时目录及合成提供器
└── tools/import-localization.py          # 从 Swift 只读导入界面字典的维护工具
```

Core 使用 `Microsoft.Data.Sqlite 8.0.22`。界面 JSON 资源显式设置 `WithCulture="false"`，统一嵌入 Core 程序集，避免文件名中的 `zh-Hans` / `zh-Hant` 被自动拆到卫星程序集。常规构建直接使用已提交的资源，不需要运行导入脚本；该维护脚本需要 Python 3 和 Linux ICU。

## Linux 上构建与测试 Core

本工作区的 SDK 为 `/home/box/.dotnet` 下的 .NET SDK 8.0.428。首次恢复需要访问 nuget.org：

```bash
export PATH="/home/box/.dotnet:$PATH"
export DOTNET_ROOT="/home/box/.dotnet"
export DOTNET_EnableWindowsTargeting=true
export DOTNET_CLI_HOME="/tmp/dotnet-home"
export DOTNET_NOLOGO=1
cd /workspace/livecopilot-port-study/repo/Windows

/home/box/.dotnet/dotnet restore LiveCopilot.Windows.sln
/home/box/.dotnet/dotnet build src/LiveCopilot.Core/LiveCopilot.Core.csproj -c Release
/home/box/.dotnet/dotnet test tests/LiveCopilot.Core.Tests/LiveCopilot.Core.Tests.csproj -c Release
```

`Directory.Build.props` 也设置了 `EnableWindowsTargeting=true`；需要显式指定 MSBuild 属性时，可在命令末尾加 `-p:EnableWindowsTargeting=true`。它允许 Linux 恢复含 Windows 项目的解决方案，不代表 Linux 可以运行 WPF。其它机器请按实际 SDK 和仓库位置调整路径。

测试使用合成文本、可控制完成时机的假提供器和独立临时目录，不调用付费服务、不下载模型、不读写用户真实会话。覆盖领域模型与序列化、回答语言/引用策略、全部分析配置，以及会话读写和导出、旧会话只读加载、转写修订与长归档、异步取消/超时后丢弃旧结果、SQLite 检索与失败回滚。

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
- `IReasoningProvider`、`IEmbeddingProvider`、`ILiveProvider` 只定义契约。本批没有真实网络、音频或推理后端。分析模型、价格和性能数据是仓库内 Swift 版本的快照，不进行在线刷新。
- `TextDocumentParser` 内置 TXT / Markdown（UTF-8、UTF-16）解析；PDF / DOCX 留给 `IDocumentParser` 适配器，没有引入 PDF 原生依赖。保留现有 KnowledgeIndex 的导入、重建和检索逻辑，没有新增 DocumentImport 编排层。
- 界面简体字典与繁体转换快照保留原文边界，不转换用户文档或对话。自动回答语言使用可注入的 `ITextLanguageDetector`，默认实现为跨平台启发式，与 Apple NaturalLanguage 的统计结果不保证逐句一致。

## 明确不在本批范围

- 不实现 WASAPI、全局快捷键、悬浮窗、`SetWindowDisplayAffinity` 或其它桌面原生集成。现有 `OverlayLayout` 仅为纯几何与状态计算。
- 不移植或接入 Laya / MLX、sherpa-onnx、llama.cpp、LLamaSharp；不启动第 3、第 4 线。
- 不翻译 `AppleSpeech*`、`AppleLiveProvider`、`Laya*`、`LocalInference*`、`LocalLiveProvider`、`LocalModel*`、`AudioFlowMonitor`、`EchoMonitor`、`AppCoordinator`。
- 不新增 `OnboardingStore` 或 `DocumentImport`，不实现真实服务凭据管理。既有设置中的兼容字段与模型标识只是数据，不代表相关运行时已经接入。
- 不修改 Mac 源码或资源，不进行签名、推送、PR、远程配置修改。
