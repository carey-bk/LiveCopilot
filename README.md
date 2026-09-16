# LiveCopilot

<img src="assets/brand/LiveCopilot-preview.png" width="100" alt="LiveCopilot Logo">

**中文** · [English](README.en.md) · [中文介绍页](https://carey-bk.github.io/LiveCopilot/) · [English website](https://carey-bk.github.io/LiveCopilot/en/)

基于 [vortechron/stealth](https://github.com/vortechron/stealth) 的原生 macOS 个人 AI 助手，面向面试、会议和学术答辩。保留 Swift/SwiftUI、ScreenCaptureKit 系统音频、AVAudioEngine 麦克风、菜单栏、悬浮窗、全局快捷键和本地历史。

V1.3.2 可选择 **Apple SpeechAnalyzer / SpeechTranscriber 本地流式识别**、**本地 Paraformer 中英流式识别**、**本地 SenseVoiceSmall + VAD** 或 OpenAI Live 进行语音识别，知识库可选择 **本地 BGE-M3** 或 OpenAI Embeddings，分析可选 OpenAI、DeepSeek 或 OpenAI 兼容服务。**关闭监听时也可以直接输入问题。** 无 AI 语音播放、云端向量库、Ollama 或账号系统。

**1.3.2** 在悬浮窗和设置标题加入 Logo，新增“关于”页，提供作者 GitHub、项目仓库及双语介绍页入口。本次公开发布也包含本地语音与向量模型、自动伸缩与贴边隐藏、一键刷新、口语回答及密钥静默读取等累计更新。详见 [1.3.2 更新](docs/V1_3_2_UPDATE.md)、[1.3.1 更新与验收](docs/V1_3_1_UPDATE.md) 和 [本地模型说明](docs/LOCAL_MODELS.md)。

## 下载与安装

从 [GitHub Releases](https://github.com/carey-bk/LiveCopilot/releases/tag/v1.3.2) 下载 **LiveCopilot-1.3.2-macOS-universal.dmg**。支持 **macOS 14+、Apple Silicon 和 Intel**；Apple 本地识别另需 macOS 26+ 和受支持的设备。直接安装无需 Xcode。

1. 打开 DMG，将 `LiveCopilot.app` 拖到 `Applications`，然后从应用程序文件夹启动。没有管理员权限时可复制到 `~/Applications`。
2. 当前版本为 **ad-hoc 签名，未经 Apple 公证**。如果 macOS 无法验证开发者，确认来源与 Release 中的 SHA-256 后，可按照 [Apple 官方说明](https://support.apple.com/en-us/102445)，在尝试打开后到“系统设置 → 隐私与安全性 → 仍要打开”允许该应用。
3. 点击菜单栏波形图标打开设置，`⌥H` 显示或隐藏悬浮窗。1.1.1 起也显示 Dock 图标，点击可恢复悬浮窗。

安装包不含 API Key、个人文档、会话历史或知识库。已有用户升级前先退出旧版，替换应用不会自动删除本地数据；macOS 可能重新询问权限。完整说明见 [安装说明](docs/INSTALL.txt)。

## 首次配置与使用

1. 点击悬浮窗齿轮，进入 **服务 → 实时服务**，选择本地识别并下载模型，或选择 OpenAI Live 并配置 Key。在软件中保存 Key 后，密钥保存在应用管理的 macOS Keychain 项（`LiveCopilot-Credentials-v1`），以后启动自动复用。兼容旧 `LiveCopilot-OpenAI` 项；如需授权，点击“授权已保存的密钥”完成一次迁移，无需重新粘贴。开发环境仍支持 `OPENAI_API_KEY`。

   启动和切换服务只做静默检查，不主动弹出授权窗口。显示“API Key 已保存 · 待授权”时，在服务页点击授权按钮；系统密码只输入 macOS 窗口。读取权限与 Key 是否有效是两项独立检查。重新打开已启动的 LiveCopilot 会恢复悬浮窗；`⌥H` 可隐藏它。
2. **服务 → 知识库服务** 选择“本地 · BGE-M3”并下载模型（约 635 MB），或保留 OpenAI Embeddings。**服务 → 分析服务** 可选择 DeepSeek 并配置独立密钥。语音与向量均选本地、分析选 DeepSeek 时，无需 OpenAI Key；模型下载后只有生成建议需要连接分析 API。旧配置升级时保持原有云端选择。
3. 设置 → 知识库 → 导入文档，支持 PDF、Markdown、TXT 和 DOCX；扫描 PDF 需预先 OCR。本地向量模式不上传索引文本，OpenAI 模式会发送提取文本。切换向量模型后，点击“重建全部索引”，完成前旧资料仍可进行关键词检索。生成回答时，相关资料片段会发送至所选分析服务。
4. 选择 Interview、Meeting 或 Academic Defense，以及 Remote Meeting / In-Person 模式。
5. 点击播放开始监听，按系统提示允许所需音频权限。远程模式使用系统音频 `Them` 和麦克风 `You`；现场模式仅使用麦克风，标为 `Room`，不承诺说话人分离。
6. 自动建议响应 Live 语义判断或本地中英文问题规则；不会仅因 VAD 停顿就请求分析。本地字幕在停顿后或连续语音满 12 秒时更新，本地规则可能漏判含蓄问题。`⌥Space` 可基于已有对话请求帮助，`⌥R` 总结，`⌥F` 追问，`⌥H` 显示/隐藏悬浮窗。
7. 直接在下方文本框输入问题，点击 **Ask** 或按 Return。可勾选是否附加近期对话；不要求正在监听。回答流式展示，`[S1]` 等对应可展开的本地来源。

菜单栏波形图标可打开设置和历史。1.2.1 起悬浮窗默认隐藏于屏幕右侧，悬停右边缘可唤出，也可点击 Dock 或按 `⌥H`；固定按钮关闭贴边隐藏。空白窗口保持紧凑，内容增加后向下展开。四边具有 12 pt 缩放热区，四角为 28 × 28 pt；拖动上下边缘切换为手动高度，取消贴边隐藏后可从头部移动窗口。两个模式均可在 **通用 → 悬浮窗** 中切换。

顶部 **↻ 刷新会话** 清空当前转写、输入草稿和回答上下文，窗口恢复紧凑并重新启用自动高度。正在监听时继续新会话，旧音频缓冲和旧回答不会回填。知识库、密钥与已保存历史不受影响；被丢弃的当前监听会话不归档。

回答建议先给可直接念出的短段落，必要的依据、引用与补充单独放后面；可以使用相关常识和合理推理，但不得虚构个人经历或项目数据。总结、追问分别使用独立任务提示词。

## 语言、底色和服务配置

- **通用 → 界面语言**：跟随系统、English、简体中文，立即生效。回答跟随提问语言。
- **通用 → 窗口底色**：半透明毛玻璃／微透磨砂／纯白底色。微透与白底使用浅色控件与深色文字。
- **服务 → 实时服务／知识库服务**：独立选择本地或 OpenAI。选择 OpenAI 时，Live 和 Embeddings 共用现有 Key；界面显示固定掩码，点击“更换密钥”才打开输入框，不回填真实 Key。
- **服务 → 分析服务**：选择分析供应商。默认沿用实时服务的 OpenAI；DeepSeek 使用独立 Key，默认模型 `deepseek-v4-pro`，可修改。兼容服务填写 HTTPS Base URL、Chat Completions 路径和模型，先保存连接，再配置该地址的 Key。
- 更换分析模型不需要重建知识库。自定义 API 地址改变后不会沿用旧地址的密钥。

早期版本通过 `NSWindow.sharingType = .none` 对全部窗口请求截图排除。1.1.1 起设置和历史页允许截图；**通用 → 在截图和屏幕共享中隐藏悬浮窗** 控制悬浮窗，默认保留隐藏，关闭后可截图。实际排除效果仍依赖 macOS 和具体会议软件。

详见 [V1.1 更新与验证](docs/V1_1_UPDATE.md)。

## V1 交付记录（2026-09-14，后续已升级）

初始 V1 交付为 **1.0.0 / 20260914.075740**。原生 Release 编译、34 项核心检查和 9 个 XCTest 用例通过；开发机上完成真实 Embeddings、带 `[S1]` 引用的流式 Responses、官方 Live 的合成语音转写/委派/关闭验证。V1.1 增加到 43 项核心检查和 12 个 XCTest 用例；第三方服务仍仅完成 Mock 协议与原生 UI 验证。

实际麦克风/系统音频、其他应用前台时的快捷键和会议软件共享排除效果仍需按[首次体验清单](docs/VERIFICATION.md)操作核对；不将合成音频联调视为硬件验证。

## 验证与开发

源码构建需要完整 **Xcode** 和 XcodeGen（`brew install xcodegen`，或设置 `XCODEGEN_BIN`）。首次构建会下载并校验固定版本的原生 sherpa-onnx/llama.cpp 运行库，再编译通用辅助程序；已安装的成品无需开发环境。执行 `./StealthApp/run.sh` 会编译、签名并安装到 `~/Applications/LiveCopilot.app`，旧应用会备份。

```bash
# 不使用 Key、不调用 API 的确定性检查
./StealthApp/scripts/test-core.sh

# 原生 Release 编译
./StealthApp/scripts/build.sh

# 从干净且已提交的源码构建 Universal DMG，输出到 dist/
./StealthApp/scripts/package-dmg.sh

# Xcode XCTest（scheme 自动使用隔离的 Mock 模式）
xcodebuild -project StealthApp/LiveCopilot.xcodeproj -scheme LiveCopilot \
  -configuration Debug -derivedDataPath StealthApp/build \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test

# 可实际操作的 Mock 应用；无需音频权限或 Key
./StealthApp/run.sh --mock

# 以下均为明确选择运行的真实 API 联调；前一条只检查 Keychain
./StealthApp/scripts/integration.sh --keychain-check
./StealthApp/scripts/integration.sh
./StealthApp/scripts/integration.sh --live
```

真实联调使用临时生成的合成文档，验证 embeddings → 本地混合检索 → Responses 流式答案和引用。`--live` 额外测试 Live 启动、短暂静音输入及正常关闭，会产生少量 API 费用。不要把真实 Key 放进命令行参数、源码、日志或聊天。

如果确实需要环境变量，在本机 zsh 中使用隐藏输入，然后从**同一终端直接运行二进制**：

```zsh
read -s 'OPENAI_API_KEY?OpenAI API key: '; echo
export OPENAI_API_KEY
"$HOME/Applications/LiveCopilot.app/Contents/MacOS/LiveCopilot"
unset OPENAI_API_KEY
```

通过 Finder / `open` 启动的 GUI 应用不保证继承当前终端环境变量，通常使用 Keychain 即可。优先级：应用管理的 Keychain 项 → 尚未迁移的旧 Keychain 项 → 当前进程 `OPENAI_API_KEY`（仅 OpenAI、无保存项时）。删除已保存密钥后不会回退并复活旧 Key。

## 边界与限制

- Live 使用当前官方 `/v1/live/sessions` 和 client delegation，未以旧 Realtime 更换模型名代替。无端点自动降级。
- 本地索引保存来源、文本和向量；选择 BGE-M3 时查询向量也在本机生成，选择 OpenAI 时请求 Embeddings API。检索排名在本机计算；embedding 请求失败时使用本地关键词检索。
- 回答结合文档证据和模型常识；来源列表是检索出的证据，不代表每条都被引用。应核对关键数字和结论。
- 远程模式最多同时使用两个 Live 会话，现场模式一个；Live 按时长计费，结束使用时停止监听或退出。
- 共享麦克风不提供可靠 diarization；耳机可减少 `Them` 音频漏入 `You`。自动识别是保守的，并保留手动触发。
- 悬浮窗的截图排除可以在通用设置中切换。排除效果取决于 macOS 和会议软件，必须用实际共享画面验证，不能仅凭该属性视为已验证。
- 当前使用 ad-hoc 签名，重建后系统可能要求重新授权。正式升级身份连续性需要稳定的 Developer ID 签名；不要通过放宽 Keychain ACL 或弱化签名验证来规避。参见[发布说明](docs/RELEASING.md)。
- 索引限制单文件 50 MB、4,000 chunks；不提供 OCR、复杂 DOCX 排版还原或云备份。

详见 [架构与协议](docs/ARCHITECTURE.md)、[隐私边界](docs/PRIVACY.md)、[实测清单与故障排查](docs/VERIFICATION.md)、[开发计划和证据](docs/IMPLEMENTATION_PLAN.md)。最终验收依据为用户提供的 [开发需求](docs/livecopilot_goal.md)。

## 来源与许可

派生于 Stealth commit `02b78cc82195a1711e3de11adfaed26011635dae`，原作者 vortechron，MIT 许可保持不变，并保留原始 Git 历史。LiveCopilot 独立发布于 [carey-bk/LiveCopilot](https://github.com/carey-bk/LiveCopilot)；原始项目见 [vortechron/stealth](https://github.com/vortechron/stealth)。打包与发布流程见 [发布说明](docs/RELEASING.md)。

图标的可编辑 SVG、单色标志与生成方式见 [品牌文件](assets/brand/README.md)。本地 FunASR 已提供 SenseVoiceSmall 和 Paraformer 流式两种选项，OpenAI Live 仍可切换。
