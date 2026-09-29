# LiveCopilot 2.1.0

## 本次变化

- 六步首次使用引导：界面语言、使用场景、本地模型准备、权限、回答服务，以及体验与准备检查。可跳过并随时从设置重新进入；预览不会录音或调用 API。
- 引导窗口使用淡粉蓝渐变、步骤切换动画和放大的进度指示。内容在一个窗口中展示，设置开关统一为右对齐的小尺寸拨杆。
- Jev Mode 使用统一字标并作为推荐配置；新增悬浮窗操作和截图／共享排除提示。实际排除效果仍取决于 macOS 和会议软件。
- OpenAI 识别支持普通话、英语、中英混合和不限语言（自动识别）；Apple 识别使用系统支持的明确语言，本地 Paraformer 支持中英混合。
- 新用户分析预设：OpenAI `gpt-6-sol`、DeepSeek `deepseek-flash`、Qwen `qwen3.8-flash`、GLM `glm-5.3-flash`、Kimi `kimi-k2.6`。已保存的自定义设置保留。
- 新增 Sparkle 应用内更新。可以从设置 → 关于、应用菜单或菜单栏入口检查更新；自动检查默认关闭。下载和安装由用户确认，安装前结束并保存当前会话。
- 更新清单和安装包均使用 Ed25519 验签，正式应用仅连接 HTTPS 更新源。安装包继续使用 Developer ID 签名和 Apple 公证。

## 如何升级

2.0 及更早版本没有在线更新器，需退出旧版，从 GitHub Release 下载 2.1 DMG，替换 Applications 中的应用一次。之后可在应用内检查新版本。升级不会清理模型、资料、历史、偏好或 API Key。

支持 macOS 14+、Apple Silicon 和 Intel。Apple 本地识别另需 macOS 26+；Laya 自动触发需要 Apple Silicon。语音、向量与回答服务的数据和费用边界不变。

## 发布验证

发布准备中；最终版本号、Apple 公证结果、更新流程验证和校验值将在完成后补齐。GitHub Release 与官网尚未发布。

## English

LiveCopilot 2.1 adds a six-step first-run guide, compact right-aligned switches, updated analysis defaults, transcription language guidance, and an in-app updater powered by Sparkle. Check for updates from Settings → About or the application/menu-bar menus. Automatic checks are off by default; downloading and installation require confirmation. Feeds and packages are verified with Ed25519 signatures before use.

Version 2.0 and earlier need one manual installation of 2.1. Later releases can be installed in-app. Existing models, documents, history, preferences, and API keys are preserved. macOS 14+ is required; Apple Speech requires macOS 26+, and Laya requires Apple Silicon. Capture exclusion still depends on macOS and the sharing application.
