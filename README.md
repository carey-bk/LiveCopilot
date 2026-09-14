# LiveCopilot

基于 [vortechron/stealth](https://github.com/vortechron/stealth) 的原生 macOS 个人 AI 助手，面向面试、会议和学术答辩。保留 Swift/SwiftUI、ScreenCaptureKit 系统音频、AVAudioEngine 麦克风、菜单栏、悬浮窗、全局快捷键和本地历史。

V1 使用 OpenAI Live 理解实时对话，通过独立的 OpenAI Responses 推理与本机知识库生成文字建议。**关闭监听时也可以直接输入问题。** 无 AI 语音播放、云端向量库、Ollama 或账号系统。

## 本机首次使用

1. 安装并首次打开 **Xcode**，完成组件安装与许可；最低运行系统 macOS 14。
2. 安装 XcodeGen：`brew install xcodegen`。本次开发也支持官方发行版安装到 `~/.local/bin/xcodegen`。
3. 在项目根目录执行 `./StealthApp/run.sh`。编译 Release，签名并安装到 `~/Applications/LiveCopilot.app`，启动菜单栏应用。重装时保留旧 app 备份。
4. 点击悬浮窗齿轮打开设置。API key 使用 macOS Keychain：**Service `LiveCopilot-OpenAI`，Account 为当前 macOS 用户名**。已有该项目则无需再次粘贴；系统询问时允许 LiveCopilot 读取。开发回退是 `OPENAI_API_KEY`，不需要配置 `.env`。

   如果显示 `Checking Keychain…`，请在本机完成 macOS 的访问提示；密码只输入系统窗口。读取权限与 Key 是否有效是两项独立检查。重新打开已启动的 LiveCopilot 会恢复悬浮窗；`⌥H` 可隐藏它。
5. 默认 Live `gpt-live-1`、推理 `gpt-5.6-sol`（low effort）、向量 `text-embedding-3-small`，均可修改。实际可用模型取决于 OpenAI 项目权限。
6. 设置 → Knowledge → Import documents，导入 PDF、Markdown、TXT 或 DOCX，等待 `Ready`。扫描 PDF 需预先 OCR。首次索引会向 OpenAI 发送提取文本。
7. 选择 Interview、Meeting 或 Academic Defense，以及 Remote Meeting / In-Person 模式。
8. 点击播放开始监听，按系统提示允许所需音频权限。远程模式使用系统音频 `Them` 和麦克风 `You`；现场模式仅使用麦克风，标为 `Room`，不承诺说话人分离。
9. 自动建议只响应 Live 判断完成的问题；`⌥Space` 可随时基于已有对话请求帮助，`⌥R` 总结，`⌥F` 追问，`⌥H` 显示/隐藏悬浮窗。
10. 直接在下方文本框输入问题，点击 **Ask** 或按 Return。可勾选是否附加近期对话；不要求正在监听。回答流式展示，`[S1]` 等对应可展开的本地来源。

没有 Dock 图标是正常行为；菜单栏波形图标可打开设置和历史。悬浮窗可拖动和调整大小。

## 本次交付状态（2026-09-14）

本机已安装 **1.0.0 / 20260914.075740**，现有 Keychain 已可读取，无需重新配置 Key。原生 Release 编译、34 项核心检查和 9 个 XCTest 用例通过；真实 Embeddings、带 `[S1]` 引用的流式 Responses、官方 Live 的合成语音转写/委派/关闭均已验证。验收用合成文档已从正式知识库清理。

实际麦克风/系统音频、其他应用前台时的快捷键和会议软件共享排除效果仍需按[首次体验清单](docs/VERIFICATION.md)操作核对；不将合成音频联调视为硬件验证。

## 验证与开发

```bash
# 不使用 Key、不调用 API 的确定性检查
./StealthApp/scripts/test-core.sh

# 原生 Release 编译
./StealthApp/scripts/build.sh

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

通过 Finder / `open` 启动的 GUI 应用不保证继承当前终端环境变量，通常使用 Keychain 即可。优先级：指定的 Keychain 项 → 当前进程 `OPENAI_API_KEY`。

## 边界与限制

- Live 使用当前官方 `/v1/live/sessions` 和 client delegation，未以旧 Realtime 更换模型名代替。无端点自动降级。
- 本地索引保存来源、文本和向量；查询向量仍需请求 Embeddings API。检索排名在本机计算；embedding 请求失败时使用本地关键词检索。
- 回答结合文档证据和模型常识；来源列表是检索出的证据，不代表每条都被引用。应核对关键数字和结论。
- 远程模式最多同时使用两个 Live 会话，现场模式一个；Live 按时长计费，结束使用时停止监听或退出。
- 共享麦克风不提供可靠 diarization；耳机可减少 `Them` 音频漏入 `You`。自动识别是保守的，并保留手动触发。
- 悬浮窗保留 `NSWindow.sharingType = .none`。实际屏幕共享排除效果取决于 macOS 和会议软件，必须用实际共享画面验证，不能仅凭该属性视为已验证。
- 默认使用 ad-hoc 本机签名，重建后系统可能再次询问权限。可使用自己的签名身份，或参阅可选 `setup-signing.sh` 的原生证书流程。
- 索引限制单文件 50 MB、4,000 chunks；不提供 OCR、复杂 DOCX 排版还原或云备份。

详见 [架构与协议](docs/ARCHITECTURE.md)、[隐私边界](docs/PRIVACY.md)、[实测清单与故障排查](docs/VERIFICATION.md)、[开发计划和证据](docs/IMPLEMENTATION_PLAN.md)。最终验收依据为用户提供的 [开发需求](docs/livecopilot_goal.md)。

## 来源与许可

派生于 Stealth commit `02b78cc82195a1711e3de11adfaed26011635dae`，原作者 vortechron，MIT 许可保持不变。上游为 `upstream`，个人 fork 为 `origin`。本机开发改动没有自动发布到远程仓库。
