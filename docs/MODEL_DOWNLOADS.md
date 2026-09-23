# 本地模型下载（2026-09-23 Dev）

设置中可选择“镜像优先，失败后尝试原站”或“原站”。默认镜像优先；该偏好由 BGE、Paraformer 和 Laya 共享。镜像为第三方服务，不保证境内可达，也不保证重定向目标位于境内。

| 内容 | 镜像优先 | 原站 |
| --- | --- | --- |
| BGE-M3 Q8、Paraformer 编码器/解码器/词表 | HF-Mirror | Hugging Face |
| Laya 模型、分词器、配置 | HF-Mirror | Hugging Face |
| Laya 固定版本 Python wheels | 清华 PyPI 镜像 | files.pythonhosted.org |
| Silero VAD | 暂无已验证备用源 | GitHub Releases |
| Laya 独立 Python、源码 | 暂无已验证备用源 | GitHub Releases / codeload |
| Apple ASR | 系统管理 | Apple |

所有替代源仍使用同一份固定 SHA-256；校验失败不会安装，继续尝试原站。已有模型不需要重新下载或重建索引。

BGE/Paraformer 显示当前文件百分比、已下载 MB、MB/s 和源站域名；未知 Content-Length 时只显示字节和速度。切换文件或下载源会重新计算该文件进度。网络失败时保留 URLSession 可用的续传数据重试；不承诺跨退出/取消的续传。Laya 大模型沿用持久化分块缓存，并按已完成字节更新模型阶段进度（非全安装包速度）。

智源官方模型平台页面可访问，但尚未确认当前 GPUStack Q8 GGUF 文件的官方下载地址，因此未将未经验证的链接加入程序。用户目前没有国内对象存储，本次未上传模型或创建托管服务。

验证：镜像实际下载 Laya LICENSE、encoder/config.json 和一个固定版本 PyPI wheel，与现有 SHA-256 一致。curl 探测使用 --noproxy '*'，但不代表排除了系统 VPN、透明路由等影响；未完成全新无代理环境下全量安装验证。镜像部分响应仍重定向 Hugging Face/CDN。
