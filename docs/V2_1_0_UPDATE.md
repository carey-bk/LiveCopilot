# LiveCopilot 2.1.0

## 本次变化

- 六步首次使用引导：界面语言、使用场景、本地模型准备、权限、回答服务，以及体验与准备检查。可跳过并随时从设置重新进入；预览不会录音或调用 API。
- 引导窗口使用淡粉蓝渐变、步骤切换动画和放大的进度指示。内容在一个窗口中展示，设置开关统一为右对齐的小尺寸拨杆。
- 设置中的“打开引导”和“悬浮窗操作提示”并排展示。模型步骤明确使用“下载并继续”；选择推荐配置本身不下载，后续步骤可查看准备进度，最后一步可补充下载所选模型。设置中正确区分下载中、排队和下载失败。
- 系统音频权限在所有使用方式中可见，并区分远程会议必需与当前可跳过。完成引导自动展开悬浮窗，首次移入前保持可见。
- 通用设置支持显示或隐藏菜单栏图标；悬浮窗共享隐藏的名称与说明在设置和操作提示中统一。
- DMG 使用淡粉蓝拖动安装布局：左侧 Applications、右侧 LiveCopilot，大图标与向左箭头，下方保留小尺寸的说明文件。
- Jev Mode 使用统一字标并作为推荐配置；新增悬浮窗操作和截图／共享排除提示。实际排除效果仍取决于 macOS 和会议软件。
- OpenAI 识别支持普通话、英语、中英混合和不限语言（自动识别）；Apple 识别使用系统支持的明确语言，本地 Paraformer 支持中英混合。
- 新用户分析预设：OpenAI `gpt-6-sol`、DeepSeek `deepseek-flash`、Qwen `qwen3.8-flash`、GLM `glm-5.3-flash`、Kimi `kimi-k2.6`。已保存的自定义设置保留。
- 知识库索引改为一根连续总进度条，显示百分比及已完成／本批文档数；当前文档按已算完的片段实时推进，每份文档等权计入总进度。文档行仅显示转圈状态，写入成功才计为完成；失败不会显示 100%。
- 新增 Sparkle 应用内更新。可以从设置 → 关于、应用菜单或菜单栏入口检查更新；自动检查默认关闭。下载和安装由用户确认，安装前结束并保存当前会话。
- 更新清单和安装包均使用 Ed25519 验签，正式应用仅连接 HTTPS 更新源。安装包继续使用 Developer ID 签名和 Apple 公证。

## 如何升级

2.0 及更早版本没有在线更新器，需退出旧版，从 GitHub Release 下载 2.1 DMG，替换 Applications 中的应用一次。之后可在应用内检查新版本。升级不会清理模型、资料、历史、偏好或 API Key。

支持 macOS 14+、Apple Silicon 和 Intel。Apple 本地识别另需 macOS 26+；Laya 自动触发需要 Apple Silicon。语音、向量与回答服务的数据和费用边界不变。

## 发布验证

- 版本：2.1.0 / 20260929.144323；Universal arm64 + x86_64。
- 前一候选版本的 73 项确定性核心检查通过，核心代码本次未变；本次 XCTest 执行 78 项、跳过 1 项显式真实 Laya 测试、无失败。
- 本次对中英文设置、模型选择和最终准备页进行了隔离的原生 SwiftUI 渲染检查；最小设置宽度和完整准备页均能容纳新增内容。未下载真实模型或调用 API，未替换当前已安装应用。
- 新增整批进度测试覆盖中途上报、不同长度文档等权计算、排除已有知识库、失败未完成、单文档重试及整库重建；连续进度条已做原生视图渲染检查。
- 应用与全部 10 个 Mach-O 组件通过 Developer ID、加固运行时、安全时间戳和架构校验。
- 前期候选包已验证签名后的 Paraformer 与 BGE-M3 实际加载及 ping；r4 候选包使用现有 BGE-M3 对两份合成文档实际建立索引：总进度 0%、23%、47%、50%、65%、81%、97%、100%。测试使用临时知识库，未改动用户资料或调用 API。本次沿用相同本地运行时，未重复模型实测。
- Apple 应用公证：`d0f4a2af-6f98-44d7-8c15-b575216bd017`，Accepted、无问题。
- Apple DMG 公证：`c4d436cf-cd1c-46a5-9dea-b094eead1256`，Accepted、无问题。
- 应用与 DMG 均已附加票据；Gatekeeper 接受，最终 DMG 完整性与校验值通过。盘内和复制出的应用均通过严格签名校验，打包不会向应用写入 FinderInfo。
- 前期 Finder 实测 Applications 在左、LiveCopilot 在右；底部三个文件图标为 56 点，上方图标为 128 点，全部无需滚动可见，本次未改动安装盘布局。
- 前期隔离预览实测现场模式系统音频卡可见、引导结束自动展开悬浮窗、菜单栏开关切换以及设置与操作提示文案一致。
- DMG SHA-256：`748a0414f159bb9f4898a2d0b88bdaec7ff704d5ea875293fd6198ac88bddb4d`。

- 前期已在独立 QA 应用中完成：从 build 100 发现 101、下载、验签、安装、重启；更新后的可执行文件与候选包一致，再次检查显示已是最新版。
- 前期修改测试清单后，应用拒绝更新并显示签名无法验证；本次正式清单与最终 DMG 的 Ed25519 验签通过。
- 前期实际操作了设置 → 关于的更新入口和自动检查开关，默认关闭，开关可正常切换；本次未修改更新器。
- 正式更新清单已放入 `site/updates/appcast.xml`，网站构建保持其字节与签名不变。

正式安装包、校验值和构建信息见 [GitHub Release](https://github.com/carey-bk/LiveCopilot/releases/tag/v2.1.0)。官网和应用内更新使用同一份已签名安装包；2.0 及更早版本需要手动安装一次 2.1。发布不会自动替换本机应用或清理用户数据。

## English

LiveCopilot 2.1 adds a six-step first-run guide, compact right-aligned switches, updated analysis defaults, transcription language guidance, and an in-app updater powered by Sparkle. Check for updates from Settings → About or the application/menu-bar menus. Automatic checks are off by default; downloading and installation require confirmation. Feeds and packages are verified with Ed25519 signatures before use.

Version 2.0 and earlier need one manual installation of 2.1. Later releases can be installed in-app. Existing models, documents, history, preferences, and API keys are preserved. macOS 14+ is required; Apple Speech requires macOS 26+, and Laya requires Apple Silicon. Capture exclusion still depends on macOS and the sharing application.
