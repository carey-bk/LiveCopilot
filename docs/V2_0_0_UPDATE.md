# LiveCopilot 2.0.0

## 新功能

- Jev Mode：Apple 本地识别与 Paraformer 的完整语段由本地 Laya 模型评估，停顿后按可调阈值决定是否触发分析。GPT-Live-1 继续使用自身语义委派，不使用 Jev Mode 的触发设置。
- GPT-Live-1 识别语言偏好：中文优先、英文优先、中英混合、不限语言（自动识别）。这些选项是会话提示，不保证强制限定转写语种。
- BGE、Paraformer、Silero VAD、Laya 模型及其隔离 Python 运行依赖默认从固定修订的公开 ModelScope 仓库下载，逐文件检查 SHA-256，失败时尝试已配置镜像及原站；应用不包含 AccessKey。下载界面显示当前文件序号、实际进度与速度。
- 修复本地语音识别启动、流式字幕显示、自动分析调度和微透磨砂顶栏。更新设置界面中的 OpenAI 标识。

## 安装和兼容性

macOS 14+，Universal（Apple Silicon 与 Intel）。Laya 仅支持 Apple Silicon；Apple 本地识别另需 macOS 26+ 及受支持设备。升级前退出旧应用，然后替换 `LiveCopilot.app`。模型权重、会话、设置、知识库和钥匙串凭据保留；安装包不包含这些私人数据。

自动触发可能漏判或误触发，仍可手动生成回答。Laya 仅负责判断，最终回答由所选分析服务生成，可能产生该服务的 API 费用。GPT-Live-1 会把音频发送给 OpenAI，其语音服务费用与回答分析费用分开。

模型分发和许可证见 [ModelScope 分发记录](MODELSCOPE_MODEL_DISTRIBUTION.md) 与 [逐文件清单](oss-model-manifest.json)。
