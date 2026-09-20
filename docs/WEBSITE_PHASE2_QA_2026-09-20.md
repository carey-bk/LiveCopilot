# 官网 Phase 2 验收 — 2026-09-20

## 本轮修改

依据 Phase 2 文档和用户关于软件界面失真的反馈，保留原有静态构建、中英文、GitHub Pages、下载和安装说明，只调整官网。

- 移除产品层虚构的红黄绿标题栏、知识库侧栏、通用回答卡、常驻贴边把手。
- `site/components/product-ui.html`、`product-transcript.html`、`product-answer.html` 统一渲染 Hero、功能卡片、工作流终点和场景面板。
- 对照实际工具栏、状态、自动建议、转写跟随、生成回答/总结/追问、回答分节、逐条来源、输入框、近期对话和底部操作。
- 独立 `product.css` 采用源码的 16px 圆角、14px 内边距、12/14px 字号和原生材质方向，避免复用官网玻璃样式。
- 文档卡、检索连线、阶段说明、播放控制移到产品外围，明确标为官网示意。
- Hero 使用 13.5 秒统一时间线，转写与回答按短语更新。来源在回答区逐条展开，窗口外层高度保持固定。
- 贴边卡片改为真实空闲窗口，淡出至完全隐藏；右缘或网页按钮唤回，没有虚构把手。
- 工作流进入视口 45% 后播放约 6 秒，最终回答使用同一产品组件。
- 增加“听 / 找 / 答”服务概览，再展开原有详细对比；保留深色隐私区。
- 分享预览图同步替换为新的产品组件。

## 产品真实性依据

本地应用源码提交：`064692ec15a3fbc537af41aef2bcd21219f48629`。

核对了 `OverlayView.swift`、`OverlayWindow.swift`、`OverlayLayout.swift`、`WindowBackgroundView.swift`、`AppBrandTitle.swift`、`SuggestionMode.swift`、`Localization.swift`、`AppCoordinator.swift` 以及仓库真实截图。

另外编译隔离的数据 fixture，直接使用未修改的真实 SwiftUI View、材质、品牌、布局、翻译代码，生成原生参考图，再与网页逐项比较。这是当前源码的真实 SwiftUI 渲染，不是用户实际会话截图，也不是已发布二进制的实机验收；没有读取生产凭据、个人资料或录音。

对照文件：`../LiveCopilot-website-backups/phase2-qa-20260920/product-comparison.html`。

浏览器材质、字体回退和原生控件字形存在平台差异，不承诺逐像素一致。网页为动画预留固定尺寸，App 可以自动改变高度。来源披露增加至少 24px 的网页点击区域。工具栏和开关为视觉复刻，不会假装启动实际录音或打开软件设置。

当前源码的 `tuckAway` 采用淡出和 `orderOut`，因此本轮按真实行为实现，优先于文档中泛化的滑出/handle 示意。

## 验证

- 生产构建成功，双语翻译键一致；唯一 ID、站内锚点、本地资源校验通过。
- Chrome macOS、Playwright WebKit：两种语言分别检查 375、390、430、768、1024、1280、1440、1728px，共 32 组。
- 无横向溢出、无 pageerror；发现的 WebKit ResizeObserver 循环警告已修复。
- 所有尺寸执行场景切换、来源展开、贴边按钮；另检查 Escape、方向键/Home/End、安装/服务深链、无 JS 完整内容与原生披露。
- Hero 全状态循环、短语转写、暂停、来源展开、固定外层高度、工作流最终状态和 reduced motion 通过。最终动画测试外层高度 645.296875px 不变，CLS 约 0.000004，无外部请求。
- axe-core 中英文 390/1440px 无 WCAG 2 A/AA、2.1 AA 违规；Lighthouse 发现的来源点击区域已补足。
- 检查了中英 Hero、Bento、工作流、服务概览、移动排版和 1200×630 分享图。

## Lighthouse（本地实验室）

| 配置 | Performance | Accessibility | Best Practices | SEO | LCP | CLS |
|---|---|---|---|---|---|---|
| 桌面 | 100 | 100 | 100 | 100 | 0.4s | 0 |
| 移动模拟 | 99 | 100 | 100 | 100 | 1.7s | 0 |

保留正常动效执行测试。这不是线上真实用户 CWV，未测量真实用户 INP。源文件保持可读，仍有压缩/缓存等优化建议。

## 验证边界

- WebKit 验证不等于实际 Safari 或 iOS 真机验收。
- 本机 Safari 26.6.2 WebDriver 被系统设置阻止，返回 `You must enable 'Allow remote automation' in the Developer section of Safari Settings`。未修改用户浏览器设置，未声称 Safari 真机通过。
- 未进行付费 API、真实音频或原生应用功能回归；本轮只发布官网。
- 保留原有服务价格说明，未重新审计各家实时价格。

## 备份与发布

改动前官网、构建脚本和 Pages 配置已归档到 `../LiveCopilot-website-backups/website-before-phase2-20260920-080712.tar.gz`，附 SHA-256 清单；归档可读取。上一版历史备份继续保留。

通过独立官网分支发布，只包含网站、构建脚本与本记录，原工作区的应用开发提交不进入发布。完成后核对 Pages 工作流、线上资源哈希与下载入口。

原始截图、原生 fixture、浏览器结果、Lighthouse/axe JSON 保存在 `../LiveCopilot-website-backups/phase2-qa-20260920/`。
