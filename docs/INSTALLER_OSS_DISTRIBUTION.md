# 安装包香港 OSS 分发

## 当前状态

2026-10-09 已创建 `livecopilot-downloads-hk`（中国香港，标准存储，本地冗余）。公开发行包 2.1.0 及 SHA256SUMS 已上传到 `releases/v2.1.0/`。Bucket ACL 保持私有，Bucket Policy 仅允许匿名 `oss:GetObject` 访问 `releases/*`；匿名列举返回 403。

官网现有下载按钮统一使用香港源，另保留 GitHub 备用链接。Sparkle 更新源尚未切换，仍使用原签名 appcast。匿名 HEAD 返回 200，1024 字节 Range 返回 206，列举返回 403。

本机 curl 使用 `--noproxy *` 测试：首次完整请求 90 秒下载 22,625,735 字节（约 251 KB/s）后超时；续传 120 秒仅传输 3,915,184 字节（约 32.6 KB/s）。GitHub 同机 1 MiB 抽样为 3.57 秒。没有验证当前网络出口的地域，也不能据此宣称所有大陆网络的表现。随后用户在自己的网络测试确认速度可接受，提供截图显示约 1.1 MB/s（2026-10-09）；据此推进官网下载入口发布。

## 配置

- 官网下载清单：`site/download.json`。`mirror_url: null` 保持 GitHub 下载；匿名下载验证成功后才填入固定 HTTPS 地址。
- 启用镜像后，中英文首页与页尾均显示 GitHub 备用下载链接。
- 仅上传公开发行的 DMG 和 SHA256SUMS；不上传旧模型分发目录、签名私钥或用户资料。
- 拟用地域：中国香港；标准存储、按量付费，初期不启用传输加速或 CDN。价格以实际账号开通页面为准。
- 使用独立安装包 Bucket 或独立的 `releases/v<version>/` 路径。禁止匿名写入和列举；只对发行对象提供匿名读取。权限调整需要按实际控制台确认。
- 费用告警不等于费用硬上限。

## 首次上线验收

1. 从 GitHub Releases 获取正式安装包，验证其大小和 GitHub 返回的 SHA-256；不要用未发布的本地新版本替换。
2. 按版本路径上传同一份文件，设置下载文件名和合适的 Content-Type。
3. 匿名 HTTPS HEAD、完整 GET、Range 下载均验证成功，下载后的 SHA-256 与原始发行包一致。
4. 在大陆不使用代理的网络测速；本机有代理时的测速不算大陆直连验收。
5. 填写 `mirror_url`，构建并检查中英文下载与备用链接，再发布 GitHub Pages。
6. 单独检查 Sparkle appcast 中的下载 URL、长度和签名，验证实际更新流程后才切换自动更新。不得因更换下载 URL 而重新打包 DMG。

## 后续版本

新版本先发布 GitHub，再同步相同字节到 OSS 并校验，最后更新官网清单与更新源。不要覆盖已有版本文件。上传凭证仅放在受控本机配置或 CI Secrets，不得写入网页或 App。

## 下载分流取舍

官网保持一个下载按钮。无需域名的第一阶段可直连香港 OSS，GitHub 保留为备用。严格按大陆/境外分流需要可达性良好的 HTTP 重定向服务：根据客户端出口 IP 判断国家，CN 返回香港对象的 302，其余地区返回 GitHub，未知地区优先香港；响应应使用 `Cache-Control: no-store` 避免跨地域缓存错误。该服务不代理安装包。VPN 和 Private Relay 等会影响出口 IP 判断。

不把浏览器语言或时区当作 IP 地区，不引入未经验证的公共 IP 查询服务作为下载的必需依赖。目前未创建分流服务，也未购买域名。

完整 OSS 下载文件已通过 SHA-256 校验：`748a0414f159bb9f4898a2d0b88bdaec7ff704d5ea875293fd6198ac88bddb4d`。尾段使用并行 Range 补齐，此结果证明文件一致，不代表单连接下载速度已验收。

测试下载：https://livecopilot-downloads-hk.oss-cn-hongkong.aliyuncs.com/releases/v2.1.0/LiveCopilot-2.1.0-macOS-universal.dmg

## 本次上线范围

采用单下载按钮直连香港 OSS，不检测 IP、不购买域名、不增加分流服务。GitHub 源链接作为备用。Sparkle 的带签名 appcast 保持原样，应用内更新下载仍走 GitHub，后续单独验证。
