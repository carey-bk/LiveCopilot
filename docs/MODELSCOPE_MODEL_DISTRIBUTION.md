# LiveCopilot ModelScope 模型分发（本地开发）

## 当前状态

- OSS 下载配置已停用；App 包内没有 OSS 地址或 AccessKey。OSS Bucket 仍是私有的，匿名请求返回 403，已上传文件保留。
- 已创建公开仓库 [careybk/livecopilot-model-assets](https://modelscope.cn/models/careybk/livecopilot-model-assets)，仓库级 License 为 `other`，逐文件许可由 README 和清单说明。40 个上传文件提交成功；ModelScope API 返回的全部 40 项路径、字节数和 SHA-256 与本地相符（平台自动生成的 `.gitattributes` 除外）。
- 固定 Git 修订号为 `a5ba0b9be08e7d8f7438e3762791ac5b62c1e253`。37 个分发文件的匿名 HTTPS HEAD 均返回 200，`X-Linked-Etag` 与清单 SHA-256 一致；Range 返回 `206`。BGE-M3 Q8 完整下载 634,553,760 字节且完整 SHA-256 一致：在继承本机代理变量的进程中用时 56.25 秒、平均 11.28 MB/s；明确使用 `curl --noproxy '*'` 直连同一文件，用时 51.02 秒、平均 12.44 MB/s。Paraformer 165,462,184 字节和 Laya Python 24,981,445 字节在各自安装器的临时目录中下载、验证，并观察到中途百分比、已下载字节和速度回调。Laya 的 132,079 字节 wheel 还实测了 ModelScope 404 后切到清华镜像并通过 SHA-256 校验。
- 完整分发集 37 个文件、1,639,227,742 字节，包含 Paraformer、Silero VAD、BGE、Laya 模型和 Laya 隔离 Python 运行依赖。逐文件来源、许可证、SHA-256 和大小见 [清单](oss-model-manifest.json)。
- 2026-09-24 的 Dev `20260924.003` 修复了 Laya Python pin 解析：`python` 条目中的 `size` 是数值，不能把整个条目强制转换为字符串字典。新原生测试覆盖该实际结构。使用修复版自带安装脚本和与 App 相同的隔离进程环境，31 个 Laya 依赖及模型文件全部从 ModelScope 下载并通过 SHA-256 校验，未发生备用源切换；此前已单独完整下载校验 Python bootstrap 归档。Dev 数据目录的 Laya 安装 receipt 已生成，离线 worker 返回 `ready` 并成功完成一条合成提问的预测。设置页 General 可见 `20260924.003`；尝试切换 Services 时桌面自动化服务崩溃，故未把服务页视觉状态列为验收证据。

## 准备上传

运行 `python3 StealthApp/scripts/modelscope-stage.py`。脚本只读取现有、已经核验的暂存源，为 ModelScope 模型仓库生成 `StealthApp/build/modelscope-stage/`；其中 37 个文件通过硬链接复用原始字节，不修改已安装模型或用户数据。`README.md` 列明逐文件许可证、原始来源、大小和 SHA-256，`artifact-manifest.json` 保留机器可读清单。

仓库建议使用一个独立的公开模型仓库，保留 `local/` 与 `laya/` 路径。上传前核对仓库公开范围、内容规则和混合许可证声明。Laya 的 LICENSE/NOTICE 文件已经随模型一起暂存；Python wheel 保留归档内的许可证元数据。`tokenizers 0.23.2` wheel 的元数据标注 Apache Software License，但归档里没有完整许可文本，上传包另附标准 Apache-2.0 文本 `LICENSES/tokenizers-0.23.2-APACHE-2.0.txt`。上传动作和仓库公开后，记录**实际仓库地址与修订号**，逐文件校验远端大小和 SHA-256。不要上传任何用户资料、会话、密钥或应用私有配置。

ModelScope 官方客户端提供 [`ms-hub upload`](https://github.com/modelscope/modelscope_hub#ms-hub-upload) 与单文件下载。本机为它准备了隔离的 Python 3.11 环境 `StealthApp/build/modelscope-tools-venv311/`。登录时由账号所有者在本机交互输入 Write 令牌，不把令牌写进 App、仓库、聊天或命令行参数。仓库使用 `careybk/livecopilot-model-assets`，设置为公开，仓库级 License 选 `other`，因为清单包含多种各自适用的许可证；README 保留逐文件许可信息。上传时使用 `ms-hub upload careybk/livecopilot-model-assets StealthApp/build/modelscope-stage/ '' --repo-type model`，明确把目录内容放在仓库根目录。公开仓库的速度、可用性和流量政策仍需按用户网络与平台规则观察，单次本机测速不保证每位用户的表现。

## App 路由

公开、无密钥的直链基址已写入 Dev 配置 `~/Library/Application Support/LiveCopilot/Development/model-distribution.json`：

```json
{"modelScopeBaseURL":"https://modelscope.cn/models/careybk/livecopilot-model-assets/resolve/a5ba0b9be08e7d8f7438e3762791ac5b62c1e253"}
```

2.0.0 正式版默认使用上面的 ModelScope 固定修订号，无需用户另行配置。可选的 `modelScopeBaseURL` 本地文件能覆盖默认值；App 不嵌入 AccessKey。`local/...` 和 `laya/...` 文件先尝试同一仓库，再回退到国内镜像与原站。每个来源都必须通过固定 SHA-256，设置页显示当前文件的真实传输百分比、已下载大小和速度。

本地回归：Debug 构建成功；70 项核心检查、17 项 Python 下载检查、47 项 Xcode 原生测试（其中 1 项跳过）通过，`git diff --check` 无错误。已安装并启动 `LiveCopilot Dev 1.4.2 (20260924.002)`，Developer ID 签名严格验证通过，且与旧版的指定要求相同；旧 App 包已备份。设置窗口的版本文字已实机确认，服务页目视检查因桌面自动化连接中断未完成。临时下载探针已清理，BGE、Paraformer 已安装文件和用户数据未改动；Laya 安装在更新前就未在预期路径发现。
