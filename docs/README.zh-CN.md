<div align="center">
  <img src="../MyClip/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="MyClip 图标" width="120" height="120">
  <h1 align="center">MyClip</h1>
  <p align="center">MyClip 帮你记住正在做的工作。它在 Mac 上采集前台焦点窗口或其所在的显示器，并使用 Codex 或 Claude 将截图整理为可搜索的笔记、相互关联的知识和任务建议。</p>
</div>

<p align="center">
  <a href="../README.md">English</a> · <strong>简体中文</strong> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <a href="https://section9-lab.github.io/MyClip/demo/"><img src="images/myclip-demo.gif" alt="MyClip 桌面演示：首次使用、Memory、Timeline、Kanban、Reports、Backstage、设置，以及 Codex 和 Claude 记忆召回" width="1000"></a>
</p>
<p align="center"><a href="https://section9-lab.github.io/MyClip/demo/">观看高清版</a> · <a href="images/myclip-demo.mp4">下载 MP4</a></p>
<p align="center"><sub>45 秒 HTML 演示 · 示例数据 · 中文界面。</sub></p>

## 你可以做什么

- **回顾工作。** 浏览截图时间线，查看笔记背后的来源。每张截图都有本地 OCR 文本文档，可以阅读、复制或打开。
- **建立个人知识库。** 搜索、编辑并连接不同项目、主题和日常工作中的笔记。笔记以 Markdown 文件保存，也可以用其他编辑器打开。
- **跟进下一步。** 审核任务建议，确认重要事项，通过看板追踪进度。在 **Kanban** 和 **Reports** 之间切换，查看按项目和进度组织的日报、周报与月报。
- **为 AI 工具提供上下文。** 让 Codex、Claude Code、Claude Desktop、Cursor 或 OpenCode 搜索已保存的记忆。

## 开始使用

需要 **macOS 13 或更高版本**，以及 **Codex 或 Claude 账户**。安装 Agent 连接器还需要 **Node.js 22 或更高版本**。本地构建说明见下文。

1. 打开 MyClip，进入侧边栏的 **Backstage**。安装连接器并登录，点击**连接**检查是否可用，再点击**启用**，将该 Agent 用于整理。仅连接不会启动任务；可以连接多个 Agent，但同一时间只能启用一个。
2. 授予**屏幕录制**和**辅助功能**权限。MyClip 打开时会自动采集，首次授权后也会开始。
3. 正常工作即可。默认触发条件为：指针静止一秒后点击、停止垂直滚动两秒，或输入字母键后按回车。自动整理会将新截图转为 Memory。
4. 在 **Memory** 查看笔记，在 **Timeline** 浏览截图，在 **Kanban** 审核任务建议。

要让 AI 工具使用记忆，请在设置中开启 **MyClip MCP**，选择客户端并应用配置，然后重启客户端或新建会话。

**Claude Code（命令行）**通过 ACP 在后台整理截图。**Claude Desktop** 有独立入口，用于打开应用以及配置 Chat 和本地 Code 会话中的 MCP 记忆访问，不能启用为后台整理 Agent。桌面端配置保存在 `~/Library/Application Support/Claude/claude_desktop_config.json`，保留已有服务器，不修改命令行配置。配置后请完全退出并重新打开 Claude Desktop。

## 截图文本文档

MyClip 使用 Apple Vision 在本机识别中英文文字，不依赖 AI 整理。在截图详情中选择 **OCR 文档**即可阅读或复制文本，也可点击**打开文档**，打开与原图保存在一起的 UTF-8 `.txt` 文件。重复截图共享同一份图片和文本文档。没有可识别文字的截图会得到空文档，识别失败可以重试。

启动后会在后台处理已有截图。OCR 文档及其搜索索引随原图按保留设置一起过期，已保存的 Memory 笔记不受影响。应用支持 macOS 13 及以上版本，包括 macOS 27；macOS 13 使用单帧 ScreenCaptureKit 流，并采用与新系统相同的应用排除规则。

## 截图整理

截图保存后立即进入持久化等待池。自动整理从最早一张待处理截图开始计时，等待五分钟，再按时间顺序为同一 Agent 组成一批：最多 **8 张图片和 32 条 OCR 记录**，OCR 文本总计最多 **12,000 个字符**。回车和手动截图使用图片；鼠标点击、滚动及旧版指针触发的截图使用本地 OCR。缺失的 OCR 会在分发前补齐；空白、识别失败或单条过长的 OCR 会回退到原图，并占用图片额度。遇到第一条会超出限制的记录时结束组批，不会跳过它。新截图不会重置计时。每次只执行一批，两批开始时间至少间隔五分钟。

**Backstage** 显示等待数量、倒计时和当前批次。**立即整理**可以提前启动一批。执行失败或中断会暂停自动处理，直到你重试或继续；截图和已有 Memory 文件都会保留。批次创建时会固定输入模式和 OCR 内容，重试或重启后也保持一致。截图详情中的**按图片重新整理**会明确发送原图，适合 OCR 无法保留的图表和布局。启用另一个 Agent 后，等待自动整理的截图会重新分配；正在执行的批次继续使用原 Agent。已有任务及其重试也保留原 Agent，并等待其重新启用。

每批使用独立的临时会话。Claude 接收 `persistSession: false`；MyClip 的 Codex app-server 代理强制要求 `ephemeral: true`，后端不确认该设置时会拒绝执行。每次运行结束后关闭 Agent 进程。旧的已保存对话既不会恢复，也不会删除。下一批收到固定整理规则、上一成功批次的交接信息（最多 4 KiB）、带时间戳和来源 ID 的本批输入、应用/窗口及触发方式元数据，以及已有任务上下文。相关 Memory 文件按需读取。交接信息只记录已保存文件的变更和来源 ID，不包含对话历史或 Memory 正文，且只在 Memory 发布成功后替换。失败重试会从新会话开始，并检查当前文件。

未启用 Agent 时，截图继续留在等待池。停用 Agent 会停止分配新任务，当前任务仍可完成。MyClip 会记住已启用的 Agent，并在启动时重新连接。旧版默认 Agent 偏好不会自动启用 Agent，升级后需要明确启用一次。

MyClip 以**完全权限**启动每个整理和任务识别会话：Codex 使用 `agent-full-access`，Claude Code 使用 `bypassPermissions`。文件访问、编辑、命令、网络访问和 MCP 工具调用不会逐项弹出确认卡。活动会话的其余工具权限请求会自动处理；已取消任务会拒绝迟到的请求。工具活动仍可在执行记录中查看。

**Backstage** 统计整理、任务识别及重试所回传的 Token 用量，分别展示各 Agent 和各批次的总量。每个请求结束后将用量保存在本地；旧记录或未回传的数据标为不可用，而不是零。上下文窗口占用不等于实际消耗。活动批次会显示当前阶段、已用时间和距最近进度更新的时间。Claude ACP 使用 Claude Code 现有的登录和网络设置，因此已配置的本地代理必须保持运行。

当前会话连续五分钟没有新的思考、回复文本、工具活动或权限活动时，整理会停止。只要持续有进展，一批最多可运行十五分钟。仅用量更新或其他会话的活动不会延长超时。

Memory 将截图观察时间（`observed_at`）与文件更新时间（`updated_at`）分开保存。Now 显示依据被采集的时间，旧依据不能覆盖更新的 Now 页面。缺失的观察时间保持未知。整理器将事件历史归入 Daily，将结论保存在项目/主题页面，并将已解决事项移出 Inbox。重复或偶然的浏览不一定生成新的永久笔记。

新整理页面的 `source_ids` 只包含正文实际引用的截图 ID。本批参考截图单独保存在 `context_source_ids`，不构成每条陈述的依据。MCP 搜索结果会带上各段落引用的来源 ID，`memory_get` 会汇总页面背后的截图（数量、时间跨度、应用）。已有笔记仍可正常阅读，在再次整理时采用这些规则；升级不会批量重写笔记。

应用内搜索与 MCP 使用相同的 SQLite FTS5 排序。关键词可匹配任意词项；精确标题和已声明的别名最先，其次综合每篇笔记中最匹配的段落与整篇笔记的 BM25，最后按文件修改时间排序。按段落打分可以避免长笔记盖过真正回答问题的那个段落。中文与标点仍支持字面子串匹配。空查询列出最近编辑的笔记。

MCP 提供两个只读工具。`memory_search` 接收 `query`（问题或关键词），以及可选的 `since`、`until`、`app` 和 `limit`（默认 10），返回带排名的结果，包含 `path`、`title`、简短的 `snippet`（最多两个匹配段落，每个不超过 300 字符）、`time`、段落引用的 `sourceIDs` 和来源 `apps`。`memory_get` 接收这些结果中的 `path`，可选加上 `#heading` 只读某一节，以及 `from`/`lines` 指定行范围；返回 Markdown 行、按标题分组的页面链接、按最新排序的反向链接（每条附带包含该链接的行及其日期），以及页面背后截图的摘要。未知参数会被拒绝，而不是被忽略。

搜索会沿着 Wikilink 展开。最匹配的结果，加上链接所在行匹配问题的链接两端，作为种子在链接图上做两步扩散：从每个种子出发一跳，再仅经过实体页面（Daily 笔记 → 人物或主题页面 → 另一篇 Daily 笔记）扩展第二跳。每条链接按其所在行与问题的匹配程度加权，并按目标页面拥有的链接数做衰减，避免 `Now.md` 这类枢纽页面淹没结果；根目录文件和 `Wiki/Archives` 不参与。这样到达的页面与直接匹配结果一起排名，并带有 `via`：一跳或两跳，每跳包含持有该链接的页面、其标题、链接所在行及日期。链接表示关联，不证明事实关系。

`time` 以及 `since`/`until` 过滤器描述内容发生的时间：优先取段落上标注的事件，其次是引用的截图，最后是文件编辑时间。`since` 包含边界，`until` 不包含边界，两者都接受 ISO 8601 时间戳。指定 `app` 时，有事件的笔记需通过同时引用该应用截图的事件段落匹配；没有事件的笔记则需要一张同时满足时间范围和应用的引用截图。未知日期的事件不会被采集或编辑时间替代。没有指定范围的带日期页面会略微偏向最近的日子。

事件标注以 HTML 注释保存在对应段落之前，中间不留空行，复制 Markdown 或重建索引后仍会保留。例如：

```markdown
<!-- myclip-event {"start":"2026-09-10T00:00:00+08:00","end":"2026-09-11T00:00:00+08:00","precision":"day","evidence":"2026年9月10日"} -->
2026年9月10日，客户会议结束。来源：截图 `REPLACE_WITH_ACTUAL_SOURCE_UUID`。
```

请使用实际依据和真实引用的截图 ID。支持 `day`（本地日历日）、`range`（明确区间，不含结束边界）和 `instant`（省略结束时间或与开始时间相同）三种精度。时间戳必须明确包含 UTC 偏移量。搜索将事件开始时间作为结果的 `time` 返回；这记录的是笔记的陈述，不代表对来源做了独立验证。无效日期、冲突标注、代码示例中的标注、缺少段落引用，或段落中不存在的 `evidence` 表述，都不会生成事件时间索引。相对日期需要已知原消息时间和时区；整理器必须保留原始表述并解释换算方式。采集时间和编辑时间不能填补缺失的事件日期。已有笔记即使没有标注也可搜索，只有相关依据再次被整理时才添加标注；升级不会编造或改写日期。

段落、事件和链接索引都是派生的 SQLite 数据，编辑时更新，删除笔记时一同删除，也会为旧资料库重建，但不改变 Markdown。需要超过两跳的问题，Agent 会用 `memory_get` 读取页面，并沿其中列出的链接或反向链接继续查阅。

临时会话不能在 Codex 或 Claude 中重新打开，请在 MyClip 中查看执行详情；每条记录也会显示图片/文本输入数量。这些设置阻止的是可恢复的本地 Agent 对话，并不决定模型服务商在服务端的数据保留。

在 **Backstage** 点击整理记录，可查看每个请求（包括重试）的工具调用、命令参数、结果、文件位置与编辑、Agent 回复、输入/输出 Token、缓存读取/写入和回传费用。工具记录在运行中持续保存，取消或重启后仍可查看。费用取自所回传会话累计金额的差值；缺少回传或会话基线未知时，费用仍为未知。旧记录保留原有 Token 总量，但无法恢复从未保存过的工具详情。

## 隐私与控制

- **选择采集内容。** 设置按三组组织：范围（默认为前台焦点窗口，也可选择其所在显示器）、独立的鼠标触发（静止后点击、滚动后停顿），以及键盘触发（默认字母键后回车，也可选择每次回车）。应用打开时自动采集，退出即可停止。可排除指定应用，全屏采集也遵守排除规则。
- **资料库保存在本机。** 截图和笔记存储在 Mac 上。原始截图默认保留 30 天，已保存笔记继续保留；可在设置中调整保留期限。
- **决定何时使用 AI。** 整理使用所选 Agent 的模型服务，可能在云端处理截图和笔记。关闭自动整理后，新截图会保留在本地，直到你选择处理。

<details>
<summary>从源码构建</summary>

需要 Xcode 26、Swift 6.2、XcodeGen、Python 3 和 Node.js。目录、提示词与测试分组见[开发说明](development.md)。

```sh
xcodegen generate
bash Scripts/test.sh
xcodebuild -project MyClip.xcodeproj -scheme MyClip -configuration Debug build
```

运行 `Scripts/package_dmg.sh` 打包 DMG，输出为 `dist/MyClip-<version>.dmg`。

分别构建 Apple Silicon 和 Intel 安装包时，运行 `MYCLIP_ARCH=arm64 bash Scripts/package_dmg.sh` 或 `MYCLIP_ARCH=x86_64 bash Scripts/package_dmg.sh`，文件名分别以 `-arm64.dmg` 和 `-x86_64.dmg` 结尾。推送 `v<version>` tag 后，GitHub Actions 会测试并打包两种架构，随后发布包含两个 DMG 和 `SHA256SUMS` 的 Release。tag 须与 `CFBundleShortVersionString` 一致，发布说明放在 `docs/releases/v<version>.md`。

</details>
