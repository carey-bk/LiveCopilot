# 官网改版验收记录 — 2026-09-19

## 交付范围

依据 LiveCopilot 官网视觉升级规格 v1.1，保留 Python 静态构建、中英文路径、GitHub Pages 和 v1.4.1 下载入口。完成玻璃导航、动态 Hero 产品窗口、顺序工作流、四张行为演示卡、四场景切换、本地处理架构、深色隐私区、下载与安装说明、服务指南和 1200×630 分享图。没有新增网页依赖或真实 API 调用。P3 装饰性视差未添加。

官网发布从 origin/main 的 `5aa62342faf248f1adf7b930f4434aeb48e1cf54` 建立独立工作区，只提交官网文件和本文，避免将原工作分支的应用开发提交一并发布。用户提供的改版规格文件保留原位，不纳入发布提交。

## 备份

- 文件：`../LiveCopilot-website-backups/website-before-redesign-20260919-225100.tar.gz`
- SHA-256：`b8ebb446c8411d4249507f2c3cb4dfa2b546a3df0fce5776a774e14a25d423ed`
- 包含完整 `site/`、`StealthApp/scripts/build-site.py`、`.github/workflows/pages.yml`。
- 归档生成时原工作区 HEAD：`064692ec15a3fbc537af41aef2bcd21219f48629`。备份中的官网文件与当时 origin/main 一致；已核验归档可读取。
- 同目录附 JSON 校验清单。回滚时在独立工作区恢复这些文件并经现有 Pages 工作流重新发布；不要覆盖其他应用开发文件。

## 内容核对

- 原生 `DocumentParser.supportedExtensions` 支持 PDF、DOCX、Markdown、TXT，因此答辩示例中的 XLSX 改为导出的 PDF。
- Markdown 来源使用章节引用；PDF 来源使用页码。
- 本地语音、本地 BGE-M3、SQLite 检索、macOS Keychain 的说明按当前源码核对。
- 明确表示回答会把问题、相关对话与检索片段发送给用户选择的分析服务。云端语音或向量服务另有相应的数据发送，不承诺全流程离线。
- 下载继续指向已有签名和公证的 v1.4.1 Universal DMG；已通过 GitHub Releases API 核对资产名称和公开下载地址。未重新发布应用。
- 保留服务选择、费用说明、Apple Speech 的系统限制及首次安装/签名说明。原有第三方价格文案未在本次重新逐项审计。

## 本地验证

- `python3 StealthApp/scripts/build-site.py` 成功；中英文翻译键一致。
- HTML 静态检查：无重复 ID、无缺失站内锚点、无缺失本地资源。
- Chrome macOS 自动化与 Playwright WebKit：中英文分别测试 375、390、430、768、1024、1280、1440、1728px，共 32 组布局，无横向溢出、缺图或 pageerror。
- 两种浏览器、两种语言、375/390/768/1440px：四场景数据、Sources、方向键/Home/End 支持、悬浮窗口按钮、移动导航、Escape、`#install` 与 `#services` 深链通过。切换四场景的容器高度保持一致。
- 关闭 JavaScript：完整问题、回答和来源仍可阅读；导航、下载、语言链接和原生 details 可用。无 JS 时场景区域显示会议示例。
- Hero 14 秒状态机所有阶段通过，含流式转写、分块回答、柔和重置、暂停和动态切换 reduced motion。展开 Sources 暂停循环，输入框仅演示且不会发送内容。
- 录制 Hero 周期：无外部请求，布局偏移约 0.00006。回答与资料均为虚构示例，不展示模型内部推理。
- axe-core WCAG 2 A/AA、2.1 AA：中英文 390/1440px 均无违规项；小字号文件类型和流程文字的对比度已修正。
- 已检查桌面、手机全页图，以及 Hero、场景区域、本地处理路径和分享图。

## Lighthouse

对最终本地生产构建，在 macOS Chrome 无头环境分别执行桌面配置与移动模拟。检测期间保留正常动效，没有为评分关闭脚本。

| 配置 | Performance | Accessibility | Best Practices | SEO | LCP | CLS |
| --- | --- | --- | --- | --- | --- | --- |
| 桌面 | 100 | 100 | 100 | 100 | 0.3 s | 0 |
| 移动模拟 | 100 | 100 | 100 | 100 | 1.4 s | 0 |

这属于本地实验室数据，不等于线上真实用户 Core Web Vitals。未测量真实用户 INP。原始 Lighthouse JSON、axe JSON、截图及测试脚本保存在 `../LiveCopilot-website-backups/qa-20260919/`。这些工具仅用于开发验证，没有进入官网依赖。

## 验证边界

- WebKit 自动化覆盖桌面和移动布局，但不是 Safari macOS 应用或真实 iOS Safari 的真机验收；后者未执行。
- 没有进行付费模型 API 调用、真实音频录制或原生应用重新测试。
- 页面保留轻量 CSS/JS；Lighthouse 的缓存、未压缩资源等诊断仍有优化建议，四项评分已达到规格目标。Pages 的线上缓存策略由托管服务控制。

## 发布

目标：`https://carey-bk.github.io/LiveCopilot/` 与 `/en/`。
发布由 `.github/workflows/pages.yml` 执行，交付时另行核验远端工作流成功、线上页面资源与本地构建一致及下载可达。
