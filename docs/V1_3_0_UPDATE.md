# LiveCopilot 1.3.0：Apple 本地识别、窗口和权限修复

## 本机交付

已安装 `~/Applications/LiveCopilot.app`，版本 **1.3.0 / 20260915.153614**（UTC 构建号）。主程序 SHA-256：`e4520b689b1de2546e3d3316983f0b4a3945fa8c70e8eb5011b019074c3c8131`。Release 包含 arm64/x86_64，签名完整性校验通过；仍为 ad-hoc 签名，没有 Developer ID 或 Apple 公证。本次没有发布新的 GitHub Release。

已有的识别、向量、DeepSeek 模型选择及知识库保持原样。Apple 入口位于「服务 → 实时服务 → Apple」，选择普通话或英语；支持 macOS 26 和受支持硬件。其他本地模型及 OpenAI Live 仍保留，macOS 14/15 使用原有路线。

## 权限与更新

截图中的 `LiveCopilot.app.previous.20260914221600` 确实对应旧应用备份。同一个应用 ID 的 13 个松散备份留在 Applications 中，可能被 LaunchServices/TCC 显示为权限对象；此外，每次 ad-hoc 编译改变代码要求，旧授权不能自动证明新代码的身份。

此次安装先把这 13 个备份以及被替换版本归档，逐文件核对内容及符号链接后，才移除松散的旧包并取消注册。归档在 `~/Library/Application Support/LiveCopilot/Backups/Applications/`。只保留、注册正常名称的 `~/Applications/LiveCopilot.app`，并仅重置该应用的 `ScreenCapture` 授权。

今后本机更新使用 `StealthApp/scripts/install-local.py`。相同签名重装的 dry-run 已验证不会重置权限；签名改变时脚本会处理旧注册并重建该应用的录屏授权记录。**脚本不能代替 macOS 最后的“允许”操作，也不修改钥匙串访问控制。** 长期免去多数更新身份提示需要稳定的 Developer ID 签名。

「通用 → 系统音频权限」现在显示当前程序的授权检查结果，并提供明确的请求和系统设置入口。缺少权限时，开始监听会显示说明，不会每点一次都自动弹系统授权框。非权限类 ScreenCaptureKit 错误不再一律误报为权限错误。

## 窗口裁切

旧结构在自动高度模式中滚动整张卡片，同时对窗口尺寸、贴边显示做重叠动画；窗口尺寸和内容布局可能暂时不一致。新结构固定顶部控制栏和底部输入栏，只让转写和回答区域滚动，根据实际窗口高度分配内容空间。动态最小高度保护控制栏；尺寸变化原子应用，贴边显示只保留透明度过渡。原生容器与 SwiftUI 根视图都按实际边界裁圆角。

原生回归覆盖长转写/回答、自动变高、切到手动缩放、停止监听和隐藏/恢复，校验 hosting view 与窗口内容边界一致。2026-09-16 已在最终安装版检查实际长转写/回答截图，顶部、输入栏、底部和圆角完整。手动缩放的原生回归通过；用户正在使用应用时没有继续重复实机拖动，二者不混同。

## Apple 与 FunASR 的实测区别

本机 Apple M4 Max / macOS 26.6.2；同一组系统 TTS 合成语音，16 kHz PCM，每 250 ms 输入一块，开头加 500 ms 静音。以下是首次收到结果时已提交的音频时长，精度受 250 ms 分块影响，**不是严格的端到端延迟或准确率基准**。SenseVoice、Paraformer 的这一轮互相并行；Apple 单独运行，不能据此推导公平的 CPU/GPU 加速倍数。

| 引擎 | 英文首次预览 | 中文首次预览 | 英文定稿 | 中文定稿 |
|---|---:|---:|---:|---:|
| Apple SpeechTranscriber | 1.25 s | 1.25 s | 5.00 s | 8.75 s |
| Paraformer 中英流式 INT8 | 1.00 s | 1.00 s | 4.50 s | 6.75 s |
| SenseVoiceSmall INT8 + VAD | 无独立流式预览 | 无独立流式预览 | 4.50 s | 6.75 s |

英文讲话在 3.572 s 结束，中文在 5.868 s 结束。Apple 本轮英文/中文定稿约滞后 1.4/2.9 秒；SenseVoice 与 Paraformer 约 0.9 秒。自动建议只使用定稿文本，因此流式预览更早出现不代表分析更早触发。

- 英文参考：`Why did we choose method B, and what is its latency?` Apple 和 SenseVoice 完整识别；Paraformer 把 latency 写成 lency。
- 中文参考：`请问这个实验为什么选择方法B？它的延迟是多少毫秒？` SenseVoice 保留了方法 B；Apple、Paraformer 写成“方法比”，但保留“延迟”和“毫秒”。
- Apple 产生英文 14 次、中文 23 次不同预览；Paraformer 分别 6、10 次。预览会修正，不提前写入历史或提问上下文。
- 三种方案都不收 ASR API 调用费。Apple 管理共享模型资源，当前实现明确选择普通话/英语；SenseVoice 自动识别多语种且整句输出，Paraformer 支持中英文流式。它们都没有房间内说话人分离，也没有内置大模型理解提问。
- Apple 模型计算由系统服务管理，FunASR 在独立 helper 进程中运行。尚未做统一口径的峰值内存、能耗、长会议、中英混说、口音或噪声测评，不能声称哪一个全面更准或更省资源。

Apple + SpeechDetector 接入了现有本地提问规则和冷却逻辑；对方/房间提问各触发一次，自己的语音不触发。停止时会排空最终结果，测试确认末词保留；纯静音没有转写。安装语言资源后再次测试，无下载动作、无真实云端 API 调用。离线推理由 Apple API 合约保证；本轮没有通过断开整台 Mac 网络来做隔离实验。

## 设置中的说明和价格

界面新增各 ASR 的本地/云端、流式/整句、语言限制说明，分析服务的凭据关系、思考强度用途，向量模型切换/重建成本，以及模式、场景和证据数量的说明。价格卡标明美元、核对日期 **2026-09-15** 和官方链接；未知模型或自定义兼容地址不套用别家报价。

| 服务 | 官方参考价格 |
|---|---|
| GPT-Live-1 | 每路会话 $0.05/分钟，按秒计费；系统音频+麦克风两路约 $0.10/分钟，连接中的静音计时；后端模型/工具额外收费 |
| GPT-5.6 Sol | 每百万 token：输入 $4、缓存命中输入 $0.40、输出 $20；当前优惠价至少至 2026-11-21 |
| DeepSeek Flash | 每百万 token，低峰/高峰：未命中输入 $0.15/$0.30、缓存命中 $0.003/$0.006、输出 $0.60/$1.20 |
| DeepSeek V4 Pro | 每百万 token，低峰/高峰：未命中输入 $0.66/$1.32、缓存命中 $0.022/$0.044、输出 $1.98/$3.96 |
| text-embedding-3-small / large | 每百万输入 token $0.02 / $0.13；建库、重建和问题向量化均产生用量 |
| Apple / FunASR / BGE-M3 | 无 API 调用费；使用本机存储、内存和计算资源 |

DeepSeek 高峰为周一至周五北京时间 09–12、14–18 点，其余低峰。官网当日直接获取的页面仍保留 V4 Pro 及其价格，未采用搜索缓存中“Pro 已退役”的旧说法。金额受厂商更新、账户折扣、税费和实际用量影响。

来源：[Apple SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)、[GPT-Live-1](https://developers.openai.com/api/docs/models/gpt-live-1)、[GPT-5.6 Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol)、[OpenAI 定价](https://developers.openai.com/api/docs/pricing)、[DeepSeek 定价](https://api-docs.deepseek.com/quick_start/pricing/)。

## 验收记录与待完成项

- 59 项确定性核心检查通过；19 项原生 XCTest 通过，最终测试时间 2026-09-15 23:55 本地时间。
- Apple 真实本地模型：中英文实时预览、稳定文本、提问触发、自己的语音不触发、静音和停止排空通过。
- SenseVoice、Paraformer 的本地转写、触发和停止回归通过；准确率限制如上。
- 安装脚本最初 2 项测试通过；9 月 16 日扩展为 3 项，增加只清理同生产 ID 开发副本、排除安装版和独立 Debug 包的检查。
- Universal Release 编译、签名、安装包字节校验通过。现有模型、知识库和 API Key 未修改；没有真实分析 API 调用或费用。
- 9 月 15 日因锁屏而待验收；9 月 16 日完成下面的授权和实机检查。


## 2026-09-16：权限根因补充与实机验收完成

用户已允许录屏，但当前程序仍报告未授权。TCC 日志明确记录 `Failed to match existing code requirement ... kTCCServiceScreenCapture`。将日志中的已存代码要求与 `codesign -d -r-` 对比，发现授权对应的是 **Debug 测试包**，而非安装版：上次安装后再跑原生测试重新注册了同 ID 的 Debug 应用。这是更新/验证流程的问题，不是用户没打开开关。

修复：

- Debug 配置改用 `com.livecopilot.development`，Release 保持 `com.livecopilot.app`。重新编译后的 Debug Info.plist 已确认独立 ID，19 项原生测试再次通过。
- 安装脚本在注册正式应用之前，取消已知 build、dist、临时 staging 副本中同生产 ID 应用的注册，不删除这些构建产物；不处理其他应用或独立 Debug ID。3 项安装脚本测试通过。
- 对同一 **1.3.0 / 20260915.153614** 安装包重新执行注册清理和单应用 ScreenCapture 重置。主程序 SHA-256 与签名未改变，未重新编译/签名安装版，API Key 未修改。
- 当前安装版随后成功开始系统音频捕获。通过本地浏览器播放 5 秒左右的合成中文测试音频，Apple 普通话路线显示对应“对方”转写；同时观察到麦克风来源“我”的转写。停止后再次开始正常，没有再次出现录屏授权提示。
- 实际截图检查：空白设置页、Apple 模型就绪状态、DeepSeek 价格与凭据状态、较长转写及流式回答下的窗口，均可显示；顶部按钮、底部输入和四角完整。用户操作期间未强行重复拖动缩放，手动缩放以原生回归为证。
- DeepSeek 凭据状态为已配置；可见用户主动发起的回答和证据引用。助手只播放本地合成音频，没有发起额外收费分析请求；临时关闭的自动建议已恢复为开启。未把用户实际转写、回答或文档内容写入验收文档。

验收结束保留 Apple 普通话选项及正在进行的用户监听，窗口保持固定、按内容自动调整高度，避免打断当前使用；图钉可恢复右侧隐藏。测试网页已关闭，本地临时 HTTP 服务已停止。最终不再处于权限阻塞状态。
