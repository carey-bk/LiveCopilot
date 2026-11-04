# Service guide

[English product guide](https://carey-bk.github.io/LiveCopilot/en/#services) · [Chinese product guide](https://carey-bk.github.io/LiveCopilot/#services)

## Three independent stages

| Stage | Options | Benefits and tradeoffs |
| --- | --- | --- |
| Speech | Zipformer, Paraformer, Apple Speech, GPT-Live-1 | Zipformer is recommended for local Chinese/English, with optional terminology enhancement (off by default), about 200 MB. Paraformer remains a local bilingual alternative, about 238 MB. Apple is system-managed and requires macOS 26+. Live sends audio to the cloud and charges by connected duration. |
| Retrieval | BGE-M3, OpenAI Embeddings | BGE-M3 keeps indexing/query vectors local, about 635 MB and local compute. OpenAI avoids local inference but receives document/query text. Both keep the retrieval database local. Changing embedding models requires reindexing. |
| Answers | OpenAI, DeepSeek, Qwen, GLM, Kimi, compatible API | Independent of ASR. Receives question, relevant conversation, and retrieved excerpts for spoken answers, recaps, or follow-ups. Compare quality, waiting time, and cost using your own questions. |

SenseVoiceSmall's sentence-only option was retired in 1.4.0; old selections migrated to Paraformer without deleting documents, weights, keys, history, or other preferences. Current fresh configurations recommend Zipformer for mixed speech.

## Automatic triggering

GPT-Live-1 supplies semantic client-delegation events; the app then invokes the selected analysis model. Local ASR uses Laya's response-intent decision, followed by deterministic pause, scheduling, and duplicate checks. Neither guarantees perfect timing. Older pre-Laya releases used local text rules; that historical behavior is not the current semantic-classifier design.

Manual generation is always available (current default Control–Option–Space; saved custom bindings are preserved). Captions or pauses alone do not cause an analysis request. Remote-mode local speech does not automatically trigger; in-person mode cannot distinguish individual room speakers. LiveCopilot does not produce spoken AI responses.

## Analysis configuration

| Preset | Default model | Default base URL | Thinking |
| --- | --- | --- | --- |
| Qwen / Alibaba Model Studio | `qwen3.8-flash` | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `enable_thinking`, off by default |
| GLM / Zhipu | `glm-5.3-flashx` (`glm-5.3-flash` also listed) | `https://open.bigmodel.cn/api/paas/v4` | Cannot be turned off for these models; Low by default |
| Kimi / Moonshot | `kimi-k2.6` | `https://api.moonshot.cn/v1` | `thinking.type` |

These presets use streaming `/chat/completions` with editable model/endpoint/thinking. Qwen/Kimi optional thinking defaults off to reduce waiting; GLM-5.3-Flash/FlashX cannot disable thinking, so the UI offers Low, High or Max. OpenAI's current default is `gpt-6-sol` (`gpt-6-luna` and `gpt-6.1-sol` are also listed); DeepSeek uses `deepseek-flash`. Low reasoning is preferred where supported. New defaults do not overwrite saved choices, keys, documents, or indexes. Changing the answer model does not require reindexing.

Qwen keys must match the region; new workspaces may supply a new console endpoint, while the older Beijing URL is a starting preset. International Z.AI uses `https://api.z.ai/api/paas/v4`; international Moonshot uses `https://api.moonshot.ai/v1`. Credentials, available models, and prices may differ by region/account. Coding Plan subscriptions are not general API credit.

**Save the connection before saving its key in the app.** Keys remain in macOS Keychain, scoped by provider and endpoint; another service/region's key is not inherited. Do not send keys in chat or commit them. Protocol/build/Mock tests need no real keys; live calls require account credit and model access. Model-default thinking omits overrides. Thinking may increase first-answer latency and output-token cost.

## Historical pricing references

The original pricing/default review was 2026-09-25. The following figures are that record, not a fresh price quote. Provider billing is authoritative; do not invent prices when an official page cannot be verified.

- GPT-Live-1: $0.05/minute per stream, billed by second; system audio + microphone are two streams, about $0.10/minute, including connected silence. Analysis is separate. [Reference](https://developers.openai.com/api/docs/models/gpt-live-1)
- OpenAI Embeddings: Small $0.02 / Large $0.13 per million input tokens, for both indexing and queries. [Small](https://developers.openai.com/api/docs/models/text-embedding-3-small), [Large](https://developers.openai.com/api/docs/models/text-embedding-3-large)
- Settings displays reviewed OpenAI/DeepSeek model prices; do not apply them to other models/proxies. [OpenAI](https://developers.openai.com/api/docs/models/gpt-6-sol), [DeepSeek](https://api-docs.deepseek.com/quick_start/pricing/)
- Qwen prices depend on model, region, context tier, and thinking. [Pricing](https://help.aliyun.com/zh/model-studio/model-pricing), [regions](https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope), [thinking](https://www.alibabacloud.com/help/en/model-studio/deep-thinking)
- GLM general API and international Z.AI require separate checks. [Zhipu pricing](https://bigmodel.cn/pricing), [GLM-5.3-Flash](https://docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash), [Z.AI endpoint](https://docs.z.ai/guides/overview/quick-start)
- Kimi bills input/output and cache usage; thinking consumes output tokens. [Pricing](https://platform.kimi.com/docs/pricing/chat), [K2.6](https://platform.kimi.com/docs/guide/kimi-k2-6-quickstart)

**Validation boundary:** Qwen/GLM/Kimi have deterministic request, credential-isolation, thinking-field, and streaming tests. No real credentials for those providers were used in the documented integration checks. UI/local ASR/embedding tests do not prove account access, billing, latency, or live answer quality. Local speech + BGE-M3 + another analysis provider requires no OpenAI key.
