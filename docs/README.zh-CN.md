<div align="center">
  <img src="../MyClip/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="MyClip 图标" width="120" height="120">
  <h1 align="center">MyClip</h1>
  <p align="center">把 Mac 上的工作记录，整理成可搜索的记忆和任务。</p>
</div>

<p align="center">
  <a href="../README.md">English</a> · <strong>简体中文</strong> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <a href="https://section9-lab.github.io/MyClip/demo/"><img src="images/myclip-demo.gif" alt="MyClip 桌面演示：首次使用、Memory、Timeline、Kanban、Reports、Backstage、设置，以及 Codex 和 Claude 记忆召回" width="1000"></a>
</p>
<p align="center"><a href="https://section9-lab.github.io/MyClip/demo/">观看高清版</a></p>

MyClip 自动记录工作画面，由你选择的 AI Agent 整理：

- **Memory**：可搜索的 Markdown 笔记，保留来源。
- **Timeline**：截图时间线，支持本地 OCR 文字识别。
- **Kanban**：任务看板、进度，以及日报、周报和月报。

截图和笔记保存在 Mac 上，AI 整理可能使用 Agent 的云端服务。开启 **MyClip MCP** 后，AI 工具也能搜索已保存的记忆。

## 安装

需要 **macOS 13+**、**Node.js 22+**，以及所选 Agent 的可用账户。

1. 从 [Releases](https://github.com/section9-lab/MyClip/releases) 下载 Apple Silicon 或 Intel 版 DMG，将 MyClip 拖入**应用程序**。
2. 打开 MyClip，选择 Agent，点击**开始使用**。
3. 授予**屏幕录制**和**辅助功能**权限。应用打开期间会自动采集并整理。

可在**设置**中调整采集范围、排除应用或关闭自动整理；退出 MyClip 即可停止采集。

在 **Backstage** 可为每个已支持的 Agent 选择模型：动态读取可搜索列表，分别保存并应用到后续会话，不写死模型名称。见[模型选择](agent-model-selection.md)。

发布版本使用自签名，尚未公证。首次打开若被 macOS 拦截，请参阅[安装帮助](release-signing.md#installing-a-community-build)。
