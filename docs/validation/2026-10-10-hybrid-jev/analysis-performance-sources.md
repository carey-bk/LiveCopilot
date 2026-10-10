# Analysis selection performance snapshot — 2026-10-10

This is a public reference dataset, not a LiveCopilot benchmark or a promise about a user's network. Values were captured on 2026-10-10; source pages use moving datasets and may now differ. No user credentials, questions, or documents were sent. Selecting a model reads bundled constants and makes no HTTP request.

| API model | Source configuration | TTFT, s | Output tok/s | First answer token, s | Source |
|---|---|---:|---:|---:|---|
| gpt-6.1-sol | low, OpenAI | 3.03 | 51.3 | not separately captured | [Artificial Analysis](https://artificialanalysis.ai/models/gpt-6-1-sol-low) |
| gpt-6-sol | low, OpenAI | 1.71 | 89 | 1.71 | [Artificial Analysis](https://artificialanalysis.ai/models/comparisons/gpt-6-1-sol-xhigh-vs-gpt-6-sol-low) |
| deepseek-flash | V4.1 Flash, max, DeepSeek | 1.07 | 217 | 10.26 | [Artificial Analysis](https://artificialanalysis.ai/models/comparisons/deepseek-v4-1-flash-vs-glm-5-3-flash) |
| glm-5.3-flash | effort not specified on comparison page | 3.05 | 58 | 37.80 | [Artificial Analysis](https://artificialanalysis.ai/models/comparisons/deepseek-v4-1-flash-vs-glm-5-3-flash) |
| kimi-k2.6 | non-reasoning | 2.74 | 59 | 2.74 | [Artificial Analysis](https://artificialanalysis.ai/models/comparisons/kimi-k2-6-non-reasoning-vs-kimi-k2-thinking) |
| qwen3.8-flash | OpenRouter → Alibaba Cloud Int., P50; effort not segmented | 1.47 | 63 | not available | [OpenRouter](https://openrouter.ai/qwen/qwen3.8-flash) |

AA output speed excludes time before the first chunk. TTFT may start with reasoning content; the app displays only answer text. The compact card intentionally shows only the two requested metrics and the actual source link. A tooltip explains the distinction from local visible-answer latency. ASR, retrieval, local network and prompt length are outside these model references.

Exact model and effort matching prevents borrowing Max for Low, GPT-6 for GPT-6.1, Flash-Next for Flash or unsegmented measurements for a selected effort. Public first-party measurements through OpenRouter are now allowed as labelled references: the source line explicitly says `OpenRouter → provider`. They are not measurements of the user's direct endpoint; region, gateway, workloads and cache distributions differ. Custom endpoints remain unmatched.

## Expanded same-effort snapshot (2026-10-10, follow-up)

The live OpenRouter provider UI now supports a **Reasoning effort** filter for DeepSeek V4.1 Flash, GLM 5.3 Flash, Kimi K3 and GPT-6 Sol. This filter is not present for Qwen3.8 Flash or Kimi K2.6. Static search snippets default to All and were insufficient; values below were read after selecting the effort and allowing the table to update. Only the named first-party row was used, never the fastest third-party host, a Flex/Fast route or the aggregate best-provider tile. P50 was selected. The filtered source URL preserves the chosen effort.

| Model | Effort | TTFT, s | tok/s | Measurement route/source |
|---|---|---:|---:|---|
| gpt-6.1-sol | medium | 5.59 | 50.8 | [Artificial Analysis → OpenAI](https://artificialanalysis.ai/models/gpt-6-1-sol-medium) |
| gpt-6.1-sol | high | 61.03 | 51.5 | [Artificial Analysis → OpenAI](https://artificialanalysis.ai/models/gpt-6-1-sol-high) |
| gpt-6.1-sol | xhigh | 172.38 | 53.5 | [Artificial Analysis → OpenAI](https://artificialanalysis.ai/models/gpt-6-1-sol-xhigh) |
| gpt-6.1-sol | max | 320.85 | 55.6 | [Artificial Analysis → OpenAI](https://artificialanalysis.ai/models/gpt-6-1-sol) |
| gpt-6-sol | high | 23.37 | 84.6 | [Artificial Analysis → OpenAI](https://artificialanalysis.ai/models/gpt-6-sol-high) |
| gpt-6-sol | xhigh | 57.46 | 85.7 | [Artificial Analysis → OpenAI](https://artificialanalysis.ai/models/gpt-6-sol-xhigh) |
| gpt-6-sol | max | 130.45 | 89.4 | [Artificial Analysis → OpenAI](https://artificialanalysis.ai/models/gpt-6-sol) |
| deepseek-flash | none | 1.15 | 222.1 | [Artificial Analysis → DeepSeek](https://artificialanalysis.ai/models/deepseek-v4-1-flash-non-reasoning) |
| kimi-k2.6 | enabled | 2.75 | 57 | [Artificial Analysis → Kimi K2.6](https://artificialanalysis.ai/models/comparisons/kimi-k2-6-vs-kimi-k2-thinking) |
| deepseek-flash | low | 1.13 | 153 | [OpenRouter → DeepSeek](https://openrouter.ai/deepseek/deepseek-v4.1-flash?reasoningEffort=low#providers) |
| deepseek-flash | high | 1.26 | 162 | [OpenRouter → DeepSeek](https://openrouter.ai/deepseek/deepseek-v4.1-flash?reasoningEffort=high#providers) |
| glm-5.3-flash | low | 3.57 | 33 | [OpenRouter → Z.ai](https://openrouter.ai/z-ai/glm-5.3-flash?reasoningEffort=low#providers) |
| glm-5.3-flash | high | 3.85 | 32 | [OpenRouter → Z.ai](https://openrouter.ai/z-ai/glm-5.3-flash?reasoningEffort=high#providers) |
| glm-5.3-flash | max | 3.00 | 58 | [OpenRouter → Z.ai](https://openrouter.ai/z-ai/glm-5.3-flash?reasoningEffort=max#providers) |
| kimi-k3 | low | 3.95 | 26 | [OpenRouter → Moonshot AI](https://openrouter.ai/moonshotai/kimi-k3?reasoningEffort=low#providers) |
| kimi-k3 | high | 4.35 | 16 | [OpenRouter → Moonshot AI](https://openrouter.ai/moonshotai/kimi-k3?reasoningEffort=high#providers) |
| kimi-k3 | max | 5.89 | 20 | [OpenRouter → Moonshot AI](https://openrouter.ai/moonshotai/kimi-k3?reasoningEffort=max#providers) |
| gpt-6-sol | medium | 2.23 | 68 | [OpenRouter → OpenAI](https://openrouter.ai/openai/gpt-6-sol?reasoningEffort=medium#providers) |

Together with the initial same-effort entries, the catalog covers 22 model/effort configurations: GPT-6.1 Sol five tiers; GPT-6 Sol five tiers; DeepSeek Flash Low/High/Max/Off; GLM Flash Low/High/Max; Kimi K2.6 On/Off; Kimi K3 Low/High/Max. Two unsegmented legacy entries are retained only for discovery links, never displayed as selected-effort numbers.

Remaining gaps: Qwen3.8 Flash's public OpenRouter table does not offer an effort filter; an official API-wide per-effort TTFT/throughput matrix was not found. Model-default/unknown/custom configurations remain unspecified rather than inferring a tier. Official OpenAI and DeepSeek documentation confirms capability/effort settings, not a universal latency guarantee. Self-hosted GPU benchmarks and Qwen Omni audio latency are different deployments/products and were excluded. Public figures move with workload and load; source pages can change even within the same day. Each pair is one observed snapshot, not an average assembled from different pages.

No paid requests, keys, user audio or knowledge documents were used for this source expansion. Sources: [OpenRouter performance metrics](https://openrouter.ai/blog/announcements/better-insights-faster-metrics-and-new-developer-power-tools/), [OpenRouter provider metrics](https://openrouter.ai/providers/apply), [OpenAI model documentation](https://developers.openai.com/api/docs/models/gpt-6.1-sol), [DeepSeek release](https://deepseek.com/en/news/deepseek-v4-1-flash/).

## Reasoning parameter verification

- [OpenAI GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol): Responses `reasoning.effort=low`; also medium/high/xhigh/max. Existing explicitly saved models/efforts are retained on launch.
- [DeepSeek](https://api-docs.deepseek.com/guides/thinking_mode/): thinking enabled plus top-level `reasoning_effort=low`; none disables thinking. Service default would otherwise be high.
- [Qwen](https://help.aliyun.com/en/model-studio/qwen-api-via-openai-chat-completions): verified Qwen3.8 models support low/medium/xhigh. Send `enable_thinking=true` and `reasoning_effort=low`. Do not send `thinking_budget` concurrently. Existing max_tokens cap remains unchanged (Qwen's max_tokens excludes thinking, per this document).
- [GLM Chat Completions](https://docs.bigmodel.cn/api-reference/模型-api/对话补全.md), [GLM5.3 migration](https://docs.bigmodel.cn/cn/guide/start/migrate-to-glm-new.md): GLM5.3/Flash have mandatory thinking and low/high/max. Send thinking enabled plus `reasoning_effort=low`, avoiding server default max. FlashX belongs to the Flash series.
- [Kimi K2.6](https://platform.kimi.com/docs/guide/kimi-k2-6-quickstart): supports enabled/disabled, without an effort tier. The default remains disabled and is never called low. [Kimi K3](https://platform.kimi.com/docs/guide/use-reasoning-effort): low/high/max, no K2 thinking toggle. Editing the model to K3 starts at low.
- Unknown models/custom endpoints retain protocol defaults; do not invent unsupported low fields. The service guide tells users that custom endpoint reasoning is server controlled.

## Change and refresh policy

`AnalysisPerformance.swift` contains the small curated snapshot. Update its source URL, configuration, numeric values and capture date together after opening the source page. Never fill a missing low measurement with max, an unspecified OpenRouter effort, or another similarly named model. A routed first-party reference must identify OpenRouter and its provider in the UI source label. A future live updater requires separate caching, availability and schema tests; none is needed to select models now.

Defaults reset only on an explicit provider/model selection in the onboarding/settings UI. Choosing the same item, editing effort alone, saving an unchanged connection, and decoding preferences do not reset effort. Preset drafts reset on user model edits, then preserve a subsequent effort selection when saved. No Keychain code, account identity, model download or production preferences changed.
