# LiveCopilot 模型 OSS 分发（本地开发）

> **状态：未启用（2026-09-24）。** 全量模型对象 1,639,227,742 字节（约 1.64 GB）托管在 OSS 上，每个用户下载完所有模型会产生约 0.7 元的**外网下行流量费**，按用户规模线性增长且无上限，因此不采用阿里云 OSS 分发。
>
> 当前 Dev 配置使用 [ModelScope 专用仓库](MODELSCOPE_MODEL_DISTRIBUTION.md) 作为 37 个文件的优先来源，其后依次使用适用的国内镜像和原站。下方 OSS 配置仅保留为历史记录，不是当前下载配置。
>
> **2.0.0 正式版内置 ModelScope 公开 HTTPS 固定修订号作为默认分发源**，没有 OSS 地址或 AccessKey。Dev 的本地 `model-distribution.json` 仅包含 ModelScope 基址；旧 OSS 配置保留为 `model-distribution.json.disabled`。下面的清单、暂存脚本和 Bucket 策略保留作参考。

## 上传清单与许可证

[`oss-model-manifest.json`](oss-model-manifest.json) 列出 37 个必需对象的 OSS key、固定来源、SHA-256、许可证和已知字节数。它由 `python3 StealthApp/scripts/oss-manifest.py > docs/oss-model-manifest.json` 从 Swift 模型定义与 `LayaRuntime/pins.json` 生成；上传前重新生成并检查差异。对象路径保持清单原样，OSS 基址可以带前缀（例如 `https://<bucket>.oss-cn-hangzhou.aliyuncs.com/models`）。

| 组 | 对象数量 | 许可证 | 来源 |
| --- | ---: | --- | --- |
| Paraformer INT8（encoder、decoder、tokens） | 3 | Apache-2.0 | [固定修订模型卡](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-paraformer-bilingual-zh-en/tree/8e40c43232a1c5c66c82111efc5820d3accca11b) |
| Silero VAD ONNX | 1 | MIT | [Silero LICENSE](https://github.com/snakers4/silero-vad/blob/master/LICENSE) |
| BGE-M3 Q8 GGUF | 1 | MIT | [量化仓库](https://huggingface.co/gpustack/bge-m3-GGUF/tree/2d48f1737679ad900d5c26c5aad5410e9c70fdca) |
| Laya CPython 3.12.14 | 1 | PSF-2.0 | `pins.json` 固定归档 |
| laya-mlx 源码 | 1 | Apache-2.0 | `pins.json` 固定提交；应用内已有 LICENSE 与 NOTICE |
| Laya 模型（含 LICENSE、NOTICE） | 11 | Apache-2.0 | `pins.json` 固定修订；LICENSE、NOTICE 随模型一同分发 |
| Python wheels | 19 | 逐文件见清单 | 对应版本的 PyPI 元数据；实际归档也应保留其 `.dist-info` 许可文件 |

清单中仅列 App 安装实际需要的文件，未打包整仓库。模型许可证是上游仓库或随模型文件所声明的许可证；wheel 的复合许可证请以归档内许可文件为准。上传前保留 Laya 的 LICENSE/NOTICE，不要把用户文档、会话或密钥放入该 Bucket。

## 创建专用 Bucket 和下载权限

1. 已在 [OSS 控制台](https://oss.console.aliyun.com/) 创建专用 Bucket `livecopilot-models-cn-7b4f`，地域华东 2（上海）`oss-cn-shanghai`，标准存储、本地冗余、私有 ACL；当前“阻止公共访问”保持开启。存储、请求与外网流量会产生费用，详见[阿里云计费说明](https://help.aliyun.com/zh/oss/billing-overview)和[创建 Bucket](https://help.aliyun.com/zh/oss/user-guide/create-a-bucket-4)。
2. 上传前运行 `python3 StealthApp/scripts/oss-stage.py`，将清单对象暂存到 `StealthApp/build/oss-stage/objects/`；脚本逐个核对 SHA-256，复制已验证的本机 BGE，不修改已安装模型。本机测试已验证全部 37 项共 1,639,227,742 字节；`StealthApp/build/oss-stage/upload/models/` 是为控制台扫描准备的同名硬链接目录。2026-09-24 OSS 控制台上传任务显示 37 项成功、0 项失败，Bucket 根目录仅有 `models/`，其下为 `local/` 与 `laya/`；本机上传源再次逐项通过 SHA-256 与大小检查。上传权限仅属于管理员登录会话，不写入 App。匿名下载后的云端哈希验证仍须在策略生效后完成。
3. 若 App 不带 AccessKey 且无独立签名 URL 服务，下载对象必须允许匿名读取。Bucket ACL 仍保持私有；[预备 JSON 策略](oss-bucket-policy.json)给所有人仅授予 `oss:GetObject`，资源限定为 `models/local/*` 与 `models/laya/*`，且请求须使用 HTTPS，不授予列举、上传、删除或管理权限。参见 [Bucket Policy 文档](https://help.aliyun.com/zh/oss/user-guide/use-bucket-policy-to-grant-permission-to-access-oss/)。OSS 的“阻止公共访问”会覆盖这条匿名策略；如开启，需在适用的账号或该专用 Bucket 层级关闭，详见[阻止公共访问](https://help.aliyun.com/zh/oss/user-guide/block-public-access)。这意味着模型对象 URL 对任何知道地址的人公开，且请求会计费；该 Bucket 不得存放私人数据。
4. 用无凭据的 `curl -I https://<bucket>.oss-<region>.aliyuncs.com/models/local/paraformer-tokens.txt` 确认返回 200；对不存在的路径应为 403/404，匿名列举 Bucket 应被拒绝。大对象须支持 HTTP Range（206），供 Laya 分块下载。上传后的对象哈希仍按清单在客户端校验，错误内容会自动切到备用源。

可在控制台图形策略中选择“指定资源”加上述两个前缀、“所有账号”、“只读（不包含 ListObject 操作）”，高级设置收窄为 `oss:GetObject`，访问方式选择 HTTPS。具体界面以阿里云当前控制台为准。

## 历史 OSS 配置（未启用）

原拟在 Dev App 的 `~/Library/Application Support/LiveCopilot/Development/model-distribution.json` 使用以下配置；现已停用，不应覆盖当前的 ModelScope 配置：

```json
{"ossBaseURL":"https://livecopilot-models-cn-7b4f.oss-cn-shanghai.aliyuncs.com/models"}
```

配置仅包含公开 HTTPS 基址，不含 AccessKey、签名或用户数据。App 每次下载读取该文件；不配置或格式无效时直接使用下列镜像。原生 BGE、Paraformer、VAD 与 Laya 的 Python、源码、wheel、模型都按**分文件路由**下载，每个来源都校验固定 SHA-256，任一来源不可达、被截断或内容不符即自动切到下一条：

| 顺序 | 路由 |
| --- | --- |
| 1 | 配置的公开分发源；下例 OSS 地址当前未启用 |
| 2 | 文件自带镜像：BGE-M3 Q8 走 ModelScope（`gpustack/bge-m3-GGUF`，与固定 SHA-256 字节一致） |
| 3 | 主机镜像：`huggingface.co` → `hf-mirror.com`；`github.com` releases → `gh-proxy.com` / `hk.gh-proxy.com` / `ghproxy.net`；`codeload.github.com` → `hk.gh-proxy.com`；CPython 归档优先中科大、南大 `github-release` 镜像；PyPI → 清华 |
| 4 | 原站 |

这些镜像均在**无代理家宽**上实测：ModelScope 11.6 MB/s、hf-mirror 1.8–4.9 MB/s、中科大/南大 12–15 MB/s、gh-proxy 0.67 MB/s（同一文件 GitHub 直连 45.5 s 未完成）。GitHub 直连因此始终排在最后，仅作兜底。设置页显示**当前文件**的百分比、已传大小和速度；短文件可能只显示初始与校验完成。下载取消或校验失败不会替换已安装模型。

本机已完成 37 个上传源对象的 SHA-256 校验，OSS 控制台显示全部上传成功。Bucket 仍是私有且阻止公共访问；其匿名下载不可用。Dev App 当前改用 ModelScope，实际仓库、修订号、远端校验和下载结果见 [ModelScope 分发记录](MODELSCOPE_MODEL_DISTRIBUTION.md)。
