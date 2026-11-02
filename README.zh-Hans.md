# LiveCopilot

<img src="assets/brand/LiveCopilot-preview.png" width="88" alt="LiveCopilot">

[English](README.md) · [繁體中文](README.zh-Hant.md) · **简体中文**

**跟上对话，找到依据，用自己的话回答。**

面向面试、会议和学术答辩的原生 macOS 助手。LiveCopilot 实时转写语音，检索个人文档中的相关资料，并在悬浮窗中流式呈现回答建议。也可以不开麦，直接输入问题。

[下载 2.7.0](https://github.com/carey-bk/LiveCopilot/releases/tag/v2.7.0) · [产品介绍](https://carey-bk.github.io/LiveCopilot/) · [版本说明](docs/releases/2.7.0.md)

## 下载与使用要求

**2.7.0 · 安装包 38.38 MB · macOS 通用版本 · Developer ID 签名与 Apple 公证**

[下载安装包 — 香港镜像](https://livecopilot-downloads-hk.oss-cn-hongkong.aliyuncs.com/releases/v2.7.0/LiveCopilot-2.7.0-macOS-universal.dmg) · [GitHub 下载与校验值](https://github.com/carey-bk/LiveCopilot/releases/tag/v2.7.0)

| 功能 | 使用要求 |
|---|---|
| 应用本体 | macOS 14 或更高版本；Apple Silicon 或 Intel |
| 本地 Laya 自动触发 | 需要 Apple Silicon，模型另行下载 |
| Apple 本地语音识别 | macOS 26 或更高版本，以及受支持的设备与语言 |
| AI 回答 | 自备受支持分析服务的 API Key |

小安装包**不包含 Laya 权重**。在首次引导或「设置 → 服务」中下载所需模型，无需另外安装 Python、Ollama 或 Docker。下载量约为：Zipformer + VAD **200 MB**、BGE-M3 **635 MB**、Laya 与运行环境 **767 MB**。安装后还需额外磁盘空间，运行会占用本机内存和计算资源。

打开 DMG，将 LiveCopilot 拖入「应用程序」后启动。已有用户可以从应用菜单选择「LiveCopilot → 检查更新…」。正常升级保留配置、API Key、文档和历史；Laya 模型更新独立于应用更新。

## 2.7 升级了什么？

- 转写区支持三行折叠，原文与译文格式一致；新增可选的流式转写翻译。
- Zipformer 英文大小写整理，改善英文转写可读性。
- 自由知识、混合知识、仅知识库三档；混合模式在资料无关时使用通用知识回答。
- 自动回答显示具体等待或拦截原因，提供诊断计数和近期事件。
- 导出本地诊断摘要及私下反馈 ZIP，可选包含崩溃报告，不会自动上传。

翻译使用已配置的回答服务，可能产生费用。2.7 未更新 Laya 模型权重。

详见 [2.7.0 版本说明](docs/releases/2.7.0.md)和[验证报告](docs/releases/2.7.0-validation.md)，包含测试、公证与下载校验结果。

## 开始第一次对话

1. **安装并打开引导。** 选择界面语言和使用方式；以后可从通用设置重新打开引导。
2. **准备语音与本地模型。** 中英双语优先选择 Zipformer；需要文档检索时下载 BGE-M3，Apple Silicon 用户可下载 Laya 开启自动触发。按需下载即可。
3. **连接分析服务。** 选择 OpenAI、DeepSeek、Qwen、GLM、Kimi 或兼容流式 Chat Completions 的服务，保存自己的 API Key。
4. **按需添加资料。** 知识库支持 PDF、Markdown、TXT、DOCX。扫描版 PDF 请先 OCR；更换向量模型后重建文档索引。
5. **开始监听或直接输入。** 现场模式使用麦克风；远程会议模式采集系统音频并可选用麦克风。按提示授予 macOS 权限，也可保持监听关闭、手动提问。
6. **回看完整会话。** 在悬浮窗阅读回答和来源，结束后到历史记录查看问题、回答及引用。

`⌥H` 显示或隐藏悬浮窗；生成回答、总结、追问快捷键可自定义。重要事实和引用请自行核对。

## 哪些处理在本机完成？

| 环节 | 可选服务 | 什么内容会离开本机？ |
|---|---|---|
| 语音识别 | 本地 Zipformer、Paraformer、Apple；OpenAI Live | 本地识别在设备上完成；OpenAI Live 会向 OpenAI 发送音频。 |
| 文档索引与检索 | 本地 BGE-M3；OpenAI Embeddings | BGE-M3 本地处理；OpenAI Embeddings 接收索引或查询文本，检索数据仍保存在本机。 |
| 自动触发回答 | 本地语音搭配 Laya；OpenAI Live 的语义委派 | Laya 的判断在本地完成；云端语音遵循其服务商的数据处理方式。 |
| 生成回答与自动命名 | 用户选择的分析 API | 相关问题、对话文本及选中证据；自动命名会使用会话问答上下文。 |

例如选择 **Zipformer + BGE-M3 + DeepSeek**，语音识别和索引在本地完成，DeepSeek 负责回答，无需 OpenAI Key。本地处理无 API 调用费；云服务可能按账户用量收费。

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

干净仓库无需下载 Laya 权重即可构建小体积应用；原生运行时依赖固定校验值。Debug 使用独立应用标识，模拟测试无需 API Key 或付费请求。正式签名、公证是独立步骤，打包前请阅读发布指南。

| 文档 | 用途 |
|---|---|
| [架构说明](docs/ARCHITECTURE.md) | 组件与数据流 |
| [验证说明](docs/VERIFICATION.md) | 测试方式与证据边界 |
| [模型分发](docs/MODEL_RELEASE_READINESS.md) | 模型版本固定与发布要求 |
| [发布指南](docs/RELEASING.md) | 签名、公证、打包与更新 |
| [反馈问题](https://github.com/carey-bk/LiveCopilot/issues) | 请附应用版本、macOS 版本和模型诊断，勿附密钥或私人对话 |

技术文档保持英文。三份 README 介绍同一版本；应用界面目前支持简体中文和英文。

## 致谢与许可

基于 [vortechron/stealth](https://github.com/vortechron/stealth)，保留上游 Git 历史和 [MIT 许可](LICENSE)。各运行时依赖保留自己的许可声明。[作者：carey-bk](https://github.com/carey-bk)。

---

[English](README.md) · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)
