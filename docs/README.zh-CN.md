<div align="center">
  <img src="../MyClip/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="MyClip 图标" width="120" height="120">
  <h1 align="center">MyClip — Mac 上的 AI 屏幕记忆</h1>
  <p align="center">把工作画面变成可搜索的记忆，让 AI 找回继续工作所需的上下文。</p>
</div>

<p align="center">
  <a href="../README.md">English</a> · <strong>简体中文</strong> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a>
</p>

MyClip 是一款优先在本地保存数据的 macOS 应用，将工作截图整理为可搜索的 Markdown 记忆和任务。内置 **Model Context Protocol（MCP）服务**，让 **Codex**、**Claude Code** 等客户端检索已保存的工作上下文，并追溯来源截图。

<p align="center">
  <a href="https://myclip.vibevibe.cc/">产品官网（英文）</a> · <a href="https://github.com/section9-lab/MyClip/releases/latest">下载 Mac 版</a> · <a href="integrations/codex.md">Codex 接入指南（英文）</a> · <a href="integrations/claude-code.md">Claude Code 接入指南（英文）</a>
</p>

<p align="center">
  <a href="https://myclip.vibevibe.cc/demo/"><img src="images/myclip-demo.gif" alt="MyClip 桌面演示：首次使用、Memory、Timeline、Kanban、Reports、Backstage、设置，以及 Codex 和 Claude 记忆召回" width="1000"></a>
</p>
<p align="center"><a href="https://myclip.vibevibe.cc/demo/">观看高清版</a></p>

## 搜索和找回工作上下文

- **Memory**：可搜索的 Markdown 笔记，保留来源。
- **Timeline**：截图时间线，支持本地 OCR 文字识别。
- **Kanban**：任务看板、进度，以及日报、周报和月报。

截图和笔记保存在 Mac 上，AI 整理可能使用 Agent 的云端服务。开启 **MyClip MCP** 后，AI 工具也能搜索已保存的记忆。

## 安装

需要 **macOS 13+**、**Node.js 22+**，以及所选 Agent 的可用账户。

1. 从 [Releases](https://github.com/section9-lab/MyClip/releases/latest) 下载 Apple Silicon 或 Intel 版 DMG，将 MyClip 拖入**应用程序**。
2. 打开 MyClip，选择 Agent，点击**开始使用**。
3. 授予**屏幕录制**和**辅助功能**权限。应用打开期间会自动采集并整理。

可在**设置**中调整采集范围、排除应用或关闭自动整理；退出 MyClip 即可停止采集。

在 **Backstage** 可为每个已支持的 Agent 选择模型：动态读取可搜索列表，分别保存并应用到后续会话，不写死模型名称。见[模型选择](agent-model-selection.md)。

发布版本使用自签名，尚未公证。首次打开若被 macOS 拦截，请参阅[安装帮助](release-signing.md#installing-a-community-build)。

## 让 Codex 和 Claude Code 使用记忆

在**设置 → MCP 记忆访问**中启用服务，勾选使用的客户端并点击**一键开启**。配置完成后重启客户端或新建会话。也支持 Claude Desktop、Cursor、OpenCode 和 WorkBuddy。

可以这样问：“通过 MyClip 找到我昨天查看的项目决策，说明依据来自哪天的截图。”回答取决于已经采集并整理的内容；MyClip 不会自动导入全部 AI 对话。

MCP 提供两个只读工具：`memory_search` 搜索记忆片段；`memory_get` 按返回路径或章节读取笔记及其关联、来源信息。查询不会修改笔记，也不会触发截图或 AI 整理。

接入的客户端会收到检索到的记忆，并可能在连接时收到已更新的个人信息、当前关注事项的短摘要；数据处理遵循该客户端的设置。关闭 MyClip MCP 服务即可暂停访问。

开发说明见[开发文档](development.md)，官网构建和发布方式见[网站维护说明](../website/README.md)。
