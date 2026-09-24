# MyClip 纯 HTML Demo

参照正在运行的 `/Applications/MyClip.app` 重建界面。Memory、Timeline、Kanban、Backstage 和 Settings 都由 HTML、CSS、JavaScript 绘制；Timeline 中的工作画面也是 DOM 模拟。真实应用截图仅用于本地比对，不作为播放素材。参考的已安装应用显示版本为 0.6.13；Onboarding 按当前源码采用「权限与语言 → 可选 Agent」两步流程。

## 预览

从仓库根目录运行：

```sh
python3 -m http.server 8766 --bind 127.0.0.1 --directory docs/demo
```

打开 [HTML 预览](http://127.0.0.1:8766/preview.html)。播放会从 macOS 桌面开始，点击 Dock 后跳动两次，再完成引导、展示功能，最后演示 Codex 与 Claude 的记忆召回。可使用章节、进度条、场景菜单或全屏模式检查。点击应用内控件会暂停自动播放，随后可以直接操作页面。

默认播放时长 **0:45**。启动与浏览片段已压缩到约 2–3 倍节奏，完整召回结果各保留约 5 秒；播放器的 1× 即为这版快节奏剪辑，也可手动选择 3×。Memory 和 Kanban 只展示主页面；日报与周报切换后展示分享入口，不进入编辑；Settings 只展示并滚动到下半页，不打开选项。手动交互仍保留。

## 页面与交互

| 页面 | 可操作内容 |
| --- | --- |
| Onboarding | 两项必需权限、可选文件访问、语言选择、下一步、返回、选择或暂不设置 Agent |
| Memory | 目录、Wikilink、搜索与清除、关联与来源展开、Markdown 编辑、预览和保存 |
| Timeline | 应用/事件/日期筛选、空状态、画面详情、OCR 文本 |
| Kanban | 审阅建议、确认、撤销、忽略、新建与编辑任务、修改状态、拖动任务 |
| Reports | 日/周/月报、日期与周期切换、参考任务、右侧报告预览、带格式复制和分享入口 |
| Backstage | 四种 Agent、连接状态、暂停、记录筛选、整理详情、用量范围与表格 |
| Settings | 采集范围、鼠标/键盘触发、排除应用、六个 MCP 客户端、帮助、保留时长、索引和关于 |

这些操作只修改当前网页内的示例状态。刷新或从头播放会重置数据。系统权限、Agent 连接、整理、MCP 配置等展示状态不会修改本机设置或调用外部模型。语言选择保留选择值，本轮演示内容使用中文。

报告与分享面板按提供的真实应用截图重建：周期下拉框、日期控件、白色文稿、右侧 360 × 520 分享面板，以及 Gmail、Notion、飞书、Lark、钉钉、微信、Slack 等入口。分享按钮仅复制示例报告并显示演示反馈，不打开外部应用或发送内容。

Codex 与 Claude 是 HTML 客户端示意。工具面板包含真实 MyClip MCP 对 `app-data.js` 中同一份虚构笔记的返回结果；最后的回答依据原文编排。来源按钮可展开返回的 Markdown。

## 文件结构

| 文件 | 用途 |
| --- | --- |
| `preview.html/css/js` | 响应式审阅播放器 |
| `index.html`、`macos.css/js` | macOS 桌面、Dock、窗口启动与光标 |
| `app-data.js` | 五篇虚构记忆、任务、工作画面和整理记录 |
| `app-views.js`、`desktop.css/js` | 各页面的 HTML、样式、交互状态 |
| `recall.css/js` | Codex / Claude 召回界面 |
| `scenes.js` | 45 秒、10 章节、26 个状态 |
| `assets/ui/`、`assets/macos/` | 项目插画、品牌图标、系统壁纸与小图标 |
| `scripts/recall.py` | 用共享笔记运行真实 MCP 并冻结结果 |
| `scripts/export-assets.swift` | 导出本机系统图标 |
| `scripts/export-readme.sh` | 从同一时间线导出高清 MP4、README GIF 与视频封面 |
| `video.html` | 高清 MP4 播放页，发布于 GitHub Pages 的 `/demo/` |
| `REFERENCE.md` | 五个真实页面的结构与尺寸记录 |

## 验证

```sh
cd docs/demo
npm run check
python3 scripts/recall.py
npx --yes hyperframes@0.8.72 preview --background --port 3017
npx --yes hyperframes@0.8.72 preview --status
```

Composition 使用一个暂停的 GSAP 时间线，支持任意方向定位。播放器时钟独立。完整检查覆盖语法、运行时、布局、运动和对比度。连续桌面的 sub-composition 建议、滚动容器外内容及折叠/遮挡内容的提示需结合截图判断。模态框出现时，其不可交互的背景页面不参与本帧布局检查；页面在独立状态下仍完整检查。

## README 导出

```sh
bash docs/demo/scripts/export-readme.sh
```

需要 Node.js、FFmpeg 和 gifsicle。输出位于 `docs/images/`：

- `myclip-demo.gif`：1200 × 750，15 fps 采样，45 秒无限循环；优化时合并相同帧，保留原始时长。
- `myclip-demo.mp4`：1600 × 1000，30 fps，45 秒，H.264，静音，支持 fast start。
- `myclip-demo-poster.jpg`：高清播放页的静态封面。

所有语言 README 的动图都链接到 [高清播放页](https://section9-lab.github.io/MyClip/demo/)，并保留仓库内 MP4 下载链接。GitHub Pages 使用独立 `gh-pages` 分支：`video.html` 对应 `demo/index.html`，MP4 与封面位于 `images/`。重新导出后需同步这些发布文件。

旧的截图播放素材与 PreviewApp 宿主已移至被忽略的 `snapshots/legacy-native/`；新的演示不依赖它们。真实参考截图位于被忽略的 `snapshots/real-app/`，不属于交付素材。
