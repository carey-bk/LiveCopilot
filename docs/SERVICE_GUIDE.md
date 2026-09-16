# 服务选择 / Service guide

中文介绍页：[服务选择](https://carey-bk.github.io/LiveCopilot/#services) · [English guide](https://carey-bk.github.io/LiveCopilot/en/#services)

## 三个独立模块

| 模块 | 可选服务 | 优势与取舍 |
| --- | --- | --- |
| 听取对话 | Apple Speech、Paraformer、GPT-Live-1 | Apple 由系统管理，本地流式但需 macOS 26+；Paraformer 本地中英流式，需下载约 238 MB，术语可能误识别；Live 使用云端语义判断，音频离机且按连接时长收费。 |
| 检索资料 | BGE-M3、OpenAI Embeddings | BGE-M3 建库与查询向量不离机，约 635 MB、占用本机算力；OpenAI 无需本地推理，但建库文本与查询需发送至 API。两者检索库均在本机，更换向量模型需重建索引。 |
| 组织回答 | OpenAI、DeepSeek、Qwen、GLM、Kimi、兼容 API | 全部独立于 ASR。分析服务接收问题、相关对话和检索片段，生成口语回答、总结或追问。实际效果、等待时间和价格需用自己的问题比较。 |

SenseVoiceSmall 整句识别入口在 1.4.0 移除。旧选择迁移到 Paraformer；如果尚未下载 Paraformer，请到实时服务页下载。已有文档、模型权重、密钥、历史和其他偏好不会因此删除。

## 自动触发不是 GPT-Live-1 独有

- GPT-Live-1 根据实时会话语义发出委派事件，应用再调用所选分析模型。优点是能使用语义上下文，而不只是匹配提问词；不保证每次判断正确。本应用不播放 AI 语音，Live 的语音生成能力在此没有使用。
- Apple / Paraformer 的完整转写由应用运行本地中英文问题规则，再经过停顿、冷却和去重。提问检测没有 API 费，但间接提问、反问或识别错误可能造成漏判/误触发。
- 所有路线都可用 Option + Space 手动请求，且都不会因每个字幕片段或每次停顿就自动调用分析。远程模式的“我”不会触发；现场模式不区分房间里具体说话人。

## 新分析服务配置

| 预设 | 默认模型 | 默认 Base URL | 思考字段 |
| --- | --- | --- | --- |
| Qwen / 阿里云百炼 | `qwen-plus` | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `enable_thinking` |
| GLM / 智谱 | `glm-5.2` | `https://open.bigmodel.cn/api/paas/v4` | `thinking.type` |
| Kimi / Moonshot | `kimi-k2.6` | `https://api.moonshot.cn/v1` | `thinking.type` |

三者使用 `/chat/completions` 流式接口，支持修改模型、Base URL 和思考模式。Qwen/Kimi 默认关闭可选思考以缩短临场等待；GLM 默认遵循模型设置。换到必须思考的模型时选择“模型默认”；并非每个模型都允许关闭思考。更换分析模型不需要重建知识库。

Qwen Key 必须与地域匹配，新业务空间可从控制台复制新域名；北京旧域名是预填起点。国际 Z.AI 可改用 `https://api.z.ai/api/paas/v4` 并选择账户可用模型；Kimi 国际账户使用 `https://api.moonshot.ai/v1`。国际/国内账户密钥、模型及价格不一定通用。Coding Plan 订阅不等于通用 API 额度。

**先保存连接，再在软件内保存对应 Key。** 密钥仍在应用管理的 macOS Keychain 中，按服务商与端点隔离；不继承 OpenAI 或其他地域的 Key。不要将 Key 发到聊天或仓库。代码适配、编译与 Mock 验证不需要真实 Key；真实调用另需自己的有效 Key、余额和模型权限。

## 费用与来源

核对日期：2026-09-16。价格可能变更，实际以账户所属平台账单为准。未能从可读取官方价格页核实的具体价格不填猜测数字。

- GPT-Live-1：每路 $0.05/分钟，按秒。系统音频 + 麦克风为两路，约 $0.10/分钟，连接静音也计时。分析另计。[官方说明](https://developers.openai.com/api/docs/models/gpt-live-1)
- OpenAI Embeddings：Small $0.02、Large $0.13 / 百万输入 token，建库和查询都计费。[Small](https://developers.openai.com/api/docs/models/text-embedding-3-small)、[Large](https://developers.openai.com/api/docs/models/text-embedding-3-large)
- OpenAI、DeepSeek 的已核对模型报价在设置中显示；其他模型/代理不可套用同一报价。[OpenAI Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol)、[DeepSeek](https://api-docs.deepseek.com/quick_start/pricing/)
- Qwen 的模型、地域、上下文档位、思考模式会影响价格。[计费](https://help.aliyun.com/zh/model-studio/model-pricing)、[接入与地域](https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope)、[思考参数](https://www.alibabacloud.com/help/en/model-studio/deep-thinking)
- GLM 使用通用 API 计费；Z.AI 与国内平台分别核对。[智谱价格](https://bigmodel.cn/pricing)、[GLM-5.2](https://docs.bigmodel.cn/cn/guide/models/text/glm-5.2)、[Z.AI 通用端点](https://docs.z.ai/guides/overview/quick-start)
- Kimi 按输入/输出及缓存命中计费，思考也消耗输出 token。[计费](https://platform.kimi.com/docs/pricing/chat)、[K2.6 参数](https://platform.kimi.com/docs/guide/kimi-k2-6-quickstart)

## English

Speech recognition, embeddings, and answer generation are independent. Apple and Paraformer keep audio local, and BGE-M3 keeps indexing/query embeddings local. Only selected cloud routes receive their corresponding audio/text. Using a non-OpenAI analysis provider with local speech and embeddings does not require an OpenAI key.

Local ASR **can trigger automatic assistance**: the app detects questions in committed text, then applies silence, cooldown, and duplicate checks. GPT-Live-1 instead provides semantic delegation decisions. Neither guarantees perfect timing, and the manual shortcut remains available. LiveCopilot does not use voice output.

Qwen, GLM, and Kimi presets use streaming Chat Completions, editable models/endpoints, and provider-specific thinking controls shown above. Save the connection before saving its key. Credentials remain in Keychain, scoped to provider and endpoint; changing the region cannot silently reuse another destination's key. Model-default thinking omits overrides. Optional thinking can increase first-answer latency and output-token cost; some models cannot disable it.

Qwen keys must match the endpoint region. Z.AI and Moonshot international accounts use their own endpoints and credentials. Coding Plan subscriptions are not general API credit. Refer to the official links above for current account/model pricing; no unverified flat price is assigned to every model in a provider.

**Validation boundary:** Qwen/GLM/Kimi have deterministic request, credential-isolation, thinking-parameter, and streamed-response tests. No real credentials for these three providers were used. The UI and local ASR/embedding runtime were tested separately; account access, billing and real provider latency remain to be validated with a user's key.
