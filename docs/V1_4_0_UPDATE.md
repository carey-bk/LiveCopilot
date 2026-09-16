# LiveCopilot 1.4.0

## 中文

- **识别全流式**：移除 SenseVoiceSmall 整句识别入口、下载项和原生执行路径；保留 Apple Speech、Paraformer 中英流式和 GPT-Live-1。旧的 SenseVoice 选择迁移为 Paraformer，其他配置保留，既有权重不删除。
- **独立字号**：通用 → 语言与外观增加流式识别区和回答区的独立滑杆/步进器，范围 11–28 pt，带预览、即时生效并保存。识别预览、完整转写、回答正文及来源正文分别跟随所属区域字号；窗口换行与滚动保持可用。
- **更多分析服务**：新增 Qwen、GLM、Kimi 预设，默认 `qwen-plus`、`glm-5.2`、`kimi-k2.6`；可改模型、Base URL 和思考模式。统一接入流式回答、上下文和资料检索，但按厂商发送不同思考参数。各厂商及各端点的 Key 独立保存；未保存连接时不能管理新地址的密钥。
- **双语说明升级**：介绍网站增加常驻服务介绍区，按听取、检索和回答解释优缺点、费用及数据流；明确本地识别也能自动触发分析，区别是本地文本规则与 Live 语义委派。README、安装、架构、隐私及本地模型文档同步更新。

配置新服务不需要把 API Key 发给开发者或写入源码。请在应用的服务 → 分析服务中选择厂商、保存连接，再输入自己账户的 Key。模型和地域可用性由厂商账户决定；Qwen 的地域密钥不混用，GLM Coding Plan 不是通用 API 额度。

## English

- Retires sentence-only SenseVoiceSmall in favor of Apple, Paraformer, and GPT-Live-1 streaming options. Legacy selections migrate to Paraformer without resetting preferences or deleting weights.
- Adds separate 11–28 pt transcript/answer font controls, with live previews and persisted settings. Large text reflows and remains scrollable.
- Adds Qwen, GLM, and Kimi analysis presets, configurable models/endpoints/thinking, vendor-specific request fields, and provider/endpoint-scoped credentials. Uses the existing streaming answer and RAG workflow.
- Replaces the bilingual site's collapsed technical disclosure with a visible service comparison. Local ASR also triggers automatic suggestions via text rules; GPT-Live-1 supplies semantic delegation decisions. Speech, embeddings, and analysis remain independent choices.

## 验证 / Validation

- Universal arm64 + x86_64 Release build succeeded.
- 67 deterministic checks passed; 24 native XCTest cases passed with zero failures. Includes legacy ASR migration, independent font persistence/bounds, provider routing, credential isolation, vendor thinking parameters, SSE output/error handling and existing application regression checks.
- Real local runtime: Chinese/English Paraformer synthetic-audio fixtures produced 10/6 changing previews before audio ended, delegated once for the other speaker/room, and did not delegate for “You”. Silence suppression, final-tail flush and normal-endpoint equivalence passed. English “latency” remained imperfect; this is a functional test, not an accuracy benchmark.
- Real BGE-M3 cross-language retrieval passed, with persisted index reopening. No paid API request or physical microphone/system-audio capture was made for this update.
- Mock GUI checked: exactly three listening options; Qwen/GLM/Kimi defaults; independent font controls; maximum-size transcript and answer text with intact top/bottom controls and scrolling.
- Chinese/English site checked at desktop, 390px and 320px widths with no horizontal overflow. Service content is a normal section, installation remains a disclosure, language navigation and demo actions work.
- **Boundary:** real Qwen, GLM, and Kimi credentials were not supplied or used. Protocol/Mock validation does not verify account balance, model entitlement, real latency, or answer quality. Apple Speech and paid OpenAI/DeepSeek behavior were not re-exercised with live audio/API calls in this update.

当前仍为 ad-hoc 签名、未经 Apple 公证的社区版本。升级可能需要 macOS 对新签名重新授权；本次不绕过系统认证或修改密钥访问控制。 / This remains an ad-hoc signed, unnotarized community build. macOS may require permissions for a changed signature; no authorization or credential ACL bypass is introduced.
