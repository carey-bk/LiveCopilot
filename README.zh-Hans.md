# LiveCopilot

<img src="assets/brand/LiveCopilot-preview.png" width="88" alt="LiveCopilot">

[English](README.md) · [繁體中文](README.zh-Hant.md) · **简体中文**

**跟上对话，找到依据，用自己的话回答。**

面向面试、会议和学术答辩的原生 macOS 助手。LiveCopilot 实时转写语音，检索个人文档中的相关资料，并在悬浮窗中流式呈现回答建议。也可以不开麦，直接输入问题。

[下载 2.12](https://github.com/carey-bk/LiveCopilot/releases/tag/v2.12) · [产品介绍](https://carey-bk.github.io/LiveCopilot/) · [版本说明](docs/releases/2.12.md)

## 下载与使用要求

**2.12 · 安装包 538 MB · macOS 通用版本 · Developer ID 签名与 Apple 公证**

[从 GitHub 下载安装包](https://github.com/carey-bk/LiveCopilot/releases/download/v2.12/LiveCopilot-2.12-macOS-universal.dmg) · [百度网盘备用下载](https://pan.baidu.com/s/1oMcGKhPmuOY7KXkb4NiTVQ?pwd=0211) · [夸克网盘备用下载](https://pan.quark.cn/s/5548f7b59bfc) · [GitHub 发布页与校验值](https://github.com/carey-bk/LiveCopilot/releases/tag/v2.12)

| 功能 | 使用要求 |
|---|---|
| 应用本体 | macOS 14 或更高版本；Apple Silicon 或 Intel |
| 本地 Laya 自动触发 | 需要 Apple Silicon，模型已内置 |
| Apple 本地语音识别 | macOS 26 或更高版本，以及受支持的设备与语言 |
| AI 回答 | 自备受支持分析服务的 API Key |

安装包**已内置 Arctic 检索模型和 Laya 自动触发模型**，检索资料和自动触发都无需另外下载模型。本地语音识别模型可在首次引导或「设置 → 服务」中按需下载：Zipformer 约 **200 MB**、Paraformer 约 **238 MB**；macOS 26 上的 Apple 本地语音识别无需通过 LiveCopilot 下载。无需另外安装 Python、Ollama 或 Docker。本地模型会占用磁盘空间以及本机内存和计算资源。

打开 DMG，将 LiveCopilot 拖入「应用程序」后启动。已有用户可以从应用菜单选择「LiveCopilot → 检查更新…」：2.11 只需下载 2.1 MB、2.10.0 只需下载 3.7 MB 的增量包，更早的版本下载完整安装包。从 2.12 起，连不上 GitHub 时更新会自动改用香港镜像。正常升级保留配置、API Key、文档和历史；用旧 BGE-M3 模型建立的资料索引，在原文件仍在时会自动用 Arctic 重建。

## 2.12 更新了什么？

- 修复：回答较多时悬浮窗可能卡死几分钟（2.10 和 2.11 都受影响）。
- 悬浮窗的使用提示改为区域高亮：提示指向的位置保持明亮，其余区域变暗。
- 「反馈问题」会把运行日志、卡顿记录和系统报告打包成可预览的 ZIP，并打开一封已附上 ZIP 的邮件发给作者；软件卡住超过 3 秒时会自动记录卡在哪里。
- 应用内更新优先连接 GitHub，连不上时自动改用香港镜像；更新失败时的链接改为官网下载区。
- 新手引导的回答服务页不再超出窗口；内置的 Arctic 模型不再显示下载说明。

完整说明：[docs/releases/2.12.md](docs/releases/2.12.md)。

## 开始第一次对话

1. **安装并打开引导。** 六步引导会带你选择输入方式、准备语音识别并测试回答服务。以后可在设置的「概览」中重新打开。
2. **准备语音识别。** macOS 26 上默认使用 Apple 本地语音识别；中英双语也可以下载本地 Zipformer。文档检索用的 Arctic 和 Apple Silicon 上自动触发用的 Laya 均已内置。
3. **连接分析服务。** 选择 OpenAI、DeepSeek、Qwen、GLM、Kimi 或兼容流式 Chat Completions 的服务，保存自己的 API Key。
4. **按需添加资料。** 知识库支持 PDF、Markdown、TXT、DOCX。扫描版 PDF 请先 OCR；更换向量模型后重建文档索引。
5. **开始监听或直接输入。** 现场模式使用麦克风；远程会议模式采集系统音频并可选用麦克风。按提示授予 macOS 权限，也可保持监听关闭、手动提问。
6. **回看完整会话。** 在悬浮窗阅读回答和来源，结束后到历史记录查看问题、回答及引用。

`⌥H` 显示或隐藏悬浮窗；生成回答、总结、追问快捷键可自定义。重要事实和引用请自行核对。

## 哪些处理在本机完成？

| 环节 | 可选服务 | 什么内容会离开本机？ |
|---|---|---|
| 语音识别 | 本地 Zipformer、Paraformer、Apple；OpenAI Live | 本地识别在设备上完成；OpenAI Live 会向 OpenAI 发送音频。 |
| 文档索引与检索 | 本地 Arctic（已内置）；OpenAI Embeddings | Arctic 本地处理；OpenAI Embeddings 接收索引或查询文本，检索数据仍保存在本机。 |
| 自动触发回答 | 本地语音搭配 Laya；OpenAI Live 的语义委派 | Laya 的判断在本地完成；云端语音遵循其服务商的数据处理方式。 |
| 生成回答与自动命名 | 用户选择的分析 API | 相关问题、对话文本及选中证据；自动命名会使用会话问答上下文。 |

例如选择 **Zipformer + Arctic + DeepSeek**，语音识别和索引在本地完成，DeepSeek 负责回答，无需 OpenAI Key。本地处理无 API 调用费；云服务可能按账户用量收费。

## 隐私与使用边界

- API Key 保存在本机 macOS 钥匙串；文档、索引和历史保存在本地。无需 LiveCopilot 账户，也不经过开发者运营的中转服务器。
- 本地语音不等于完全离线回答：所选分析服务会收到相关文本，并适用其留存与计费政策。删除本地历史无法撤回已发出的 API 请求。
- 会议共享与录制隐藏可选，默认关闭。请在实际会议软件中验证效果；设置页和历史页仍可被捕获。
- 不内置 OCR，不保证说话人分离，不提供 AI 语音播放或云备份。Laya 可能漏判或误触发；应用支持 Intel 不代表 Laya 支持 Intel。

[隐私说明](docs/PRIVACY.md) · [服务选择指南](docs/SERVICE_GUIDE.md) · [本地模型](docs/LOCAL_MODELS.md)

## 开发与文档

基于 Swift/SwiftUI。源码构建需要完整 Xcode 和 XcodeGen：

```bash
./StealthApp/scripts/test-core.sh
./StealthApp/scripts/build.sh
xcodebuild -project StealthApp/LiveCopilot.xcodeproj -scheme LiveCopilot \
  -configuration Debug -derivedDataPath StealthApp/build CODE_SIGNING_ALLOWED=NO test
```

模型权重不放在 Git 中：正式打包时从本地资源目录放入内置的 Arctic 和 Laya 模型，并在签名前校验。原生运行时依赖固定校验值。Debug 使用独立应用标识，模拟测试无需 API Key 或付费请求。正式签名、公证是独立步骤，打包前请阅读发布指南。

| 文档 | 用途 |
|---|---|
| [架构说明](docs/ARCHITECTURE.md) | 组件与数据流 |
| [验证说明](docs/VERIFICATION.md) | 测试方式与证据边界 |
| [模型分发](docs/MODEL_RELEASE_READINESS.md) | 模型版本固定与发布要求 |
| [发布指南](docs/RELEASING.md) | 签名、公证、打包与更新 |
| [反馈问题](https://github.com/carey-bk/LiveCopilot/issues) | 请附应用版本、macOS 版本和模型诊断，勿附密钥或私人对话 |

技术文档保持英文。三份 README 介绍同一版本；应用界面支持英文、简体中文和繁体中文。

## 致谢与许可

基于 [vortechron/stealth](https://github.com/vortechron/stealth)，保留上游 Git 历史和 [MIT 许可](LICENSE)。各运行时依赖保留自己的许可声明。[作者：carey-bk](https://github.com/carey-bk)。

---

[English](README.md) · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)
