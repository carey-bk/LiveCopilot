# LiveCopilot 1.3.2

2026-09-16

## 本次更新

- 悬浮窗与设置侧栏的 LiveCopilot 标题显示应用 Logo，复用应用内的高分辨率图标。
- 设置新增“关于”，显示版本和构建号，提供作者 GitHub、项目仓库、双语介绍页与 Stealth 来源链接。
- 新增独立中文、英文介绍页，顶部通过“中文 / EN”切换；README 同步提供两个语言入口。
- 介绍页包含可点击的预设回答示例、服务比较、隐私边界和安装说明，适配桌面与手机。不录音，不访问模型 API，不使用外部字体或追踪脚本。

## 本次公开发布包含的累计更新

相对 GitHub 上的 1.1.0，包含 Apple SpeechAnalyzer / SpeechTranscriber、Paraformer 流式与 SenseVoiceSmall + VAD 本地识别、BGE-M3 本地向量化；还包含微透底色、自动伸缩、右侧隐藏、刷新会话、口语回答、独立服务配置、费用说明及应用管理的 Keychain 凭据。

Apple 本地识别需 macOS 26+ 及受支持的设备、语言；应用本身支持 macOS 14+ 的 Apple Silicon 与 Intel。模型首次下载需要联网，本地模型不收 API 调用费，但占用本机资源。云端分析仍发送问题、相关对话与检索片段到所选服务。

## 本次验证

- Release Universal 构建成功，包含 arm64 / x86_64。
- 原生测试 24 项通过，包含 60 项核心逻辑检查。
- 本地介绍页中文、英文切换及回答示例按钮通过；390px 手机与 1280px 桌面视图无水平溢出、无缺失图片。
- 已安装同一份 1.3.2 构建，实机确认悬浮窗及设置标题 Logo、关于页的版本号与三个目标链接；启动未弹出 Keychain 授权。
- 本次改动未更改 ASR、分析接口或密钥存储协议；未为界面变更重复调用付费 API。

## 安装与签名

DMG 包含应用、Applications 快捷入口、中英文安装说明、MIT 许可、版本来源信息；校验和单独发布。请退出旧版本再替换，固定安装位置。

此社区版仍为临时签名，未经 Apple 公证。静默启动不会主动弹出 Keychain 授权，但签名变化后使用原密钥或系统录音时仍可能需要用户重新授权。开发机安装脚本会清理旧应用身份并重置本应用的旧录屏记录，不能代替用户授予系统权限。

## English

Version 1.3.2 adds the app logo to the overlay and Settings titles, an About page with author/project/guide links, and a bilingual product website with explicit Chinese/English switching. The website uses only scripted demo content and makes no recording or model requests.

This public release also includes the local speech/embedding routes, compact and edge-hiding window, conversation refresh, spoken-answer prompts, service guidance and credential handling developed since 1.1.0. The universal Release build and 24 native tests passed. Local website checks covered both languages and mobile/desktop layouts. No paid model requests were needed for this branding release.

The build remains ad-hoc signed and not Apple-notarized. Changed signatures may require renewed macOS permissions. See the bilingual installation instructions shipped in the DMG.
