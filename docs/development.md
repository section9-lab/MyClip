# 开发与目录结构

所有命令从仓库根目录执行。开发环境为 macOS、Xcode 26、Swift 6.2、XcodeGen、Python 3 和 Node.js。

## 源码

| 目录 | 职责 |
|---|---|
| `MyClip/App/` | 应用入口、窗口、菜单栏、权限；`Model/` 协调各项功能 |
| `MyClip/Features/` | 按 Agent、Capture、Memory、Tasks、Analytics、Settings、Onboarding 划分的界面与系统服务 |
| `MyClip/UI/` | 多个界面共用的视图和 macOS 兼容辅助代码 |
| `MyClip/Core/` | Swift Package `MyClipCore`，不依赖应用界面；按职责划分子目录 |
| `MyClip/Core/Storage/` | `LibraryStore` 的初始化、数据库结构与迁移、资料库快照、SQLite 封装 |
| `MyClip/Core/Capture/` | 截图、触发规则、过滤、OCR、截图存储 |
| `MyClip/Core/Memory/` | Markdown 文件、检索、链接、索引、校验、整理后的写回 |
| `MyClip/Core/Organization/` | 整理队列、批次、交接与重试 |
| `MyClip/Core/Agent/` | ACP 通信、会话、执行记录、用量 |
| `MyClip/Core/Tasks/` | 用户工作任务、任务响应解析、报告与分享目标 |
| `MyClip/Core/MCP/` | 只读记忆服务与客户端配置 |
| `MyClip/Core/Localization/` | 应用语言选择 |
| `MyClip/Core/Prompt/` | 应用发给 Agent 的提示词和 MCP 工具说明 |
| `Sources/MyClipMCP/` | 独立的 `myclip-mcp` 命令行入口 |
| `Legacy/Kara/` | 旧 Kara 源码，保留供查阅，不参与构建 |

核心仍是一个 Swift Package，数据仍由同一个 `LibraryStore` actor 管理。各领域目录里的 `LibraryStore` 扩展负责相应操作，没有增加数据库、服务层或新的模块依赖。

`project.yml` 是 Xcode 项目的来源。新增、移动应用源文件后运行 `xcodegen generate`，将生成的 `MyClip.xcodeproj` 一起保留。Core 的 Swift 文件由 SwiftPM 自动发现。

## Memory 与看板的边界

Memory 仅保存有来源依据的上下文：`Daily/` 记录经过，`Wiki/` 积累项目与专题知识，`Profile.md` 保存用户的个人信息、偏好、工作方式与性格倾向，可以从截图和对话中归纳，每条标注依据。待办、待确认事项和任务状态由独立看板逻辑管理，不通过记忆目录维护另一套清单。

记忆目录只有 `Memory.md`、`Profile.md`、`Now.md`、`Wiki/` 和 `Daily/`，新建和移动记忆的目标仅允许 `Wiki/` 或 `Daily/`。

## 两条记忆管道

截图进来以后分两步写，**职责不重叠**，Agent 一次只做一件事：

| 管道 | 触发 | 写入范围 | 代码入口 |
|---|---|---|---|
| 实时（batch） | 每 5 分钟，一批 ≤8 张截图 | 只写 `Daily/YYYY/MM/YYYY-MM-DD.md` 与 `Daily/YYYY/MM/YYYY-MM-DD/主题.md`；不改 Wiki、根文件，不调工具，不返回任务 JSON | `DayPrompt.daily`，`MemoryRules.dailyWriting` |
| 定期整理（digest） | 每小时一次，且上次整理后有 Daily 页面变化 | 读水位线之后的 Daily，归纳进 `Wiki/`、`Memory.md`、`Now.md`、`Profile.md`；调用看板工具（`board_list` / `board_add` / `board_update` / `board_delete`）与日历工具（`calendar_list` / `calendar_add` / `calendar_update` / `calendar_delete`）分别维护两个独立功能 | `DayPrompt.digest`，`MemoryDigest`，`MemoryRules.reviewWriting` |

- 水位线是 `vault_meta.digest_at`，取上次 digest 的开始时间，所以整理期间新写的页面下一轮会读到；每次最多 8 个 Daily 页（`MemoryDigest.scopeLimit`），积压小时数会在之后几轮补齐。
- digest 复用 dream 的排队位置（`jobs.kind='dream'` 且 `dream_plans.dailies` 非空），所以它不会和 batch 抢同一次运行；夜间 dream（巡检、周汇总）用 `consolidated_at` 自己的基准，两者互不覆盖。
- 日历有两条写入口，都必须幂等：Memory 里带 `<!-- myclip-event -->` 的段落自动投影（`synchronizeCalendarEvents`），以及 digest 的 `calendar_add`（按“页面 + 原文行”upsert）。所以 prompt 要求：用工具写日程的那一行**不要**再加事件标注。
- 写工具只在 MyClip 自己启动的会话里可用（`--write-tools`）；安装到 Claude Code / Codex / OpenCode 的那份 MCP 仍然只读。

## 提示词

提示词使用 Swift 多行字符串，可以直接插入语言、时间、任务、来源和限制值，无需额外的模板加载器。

| 文件 | 修改内容 |
|---|---|
| [MemoryRules.swift](../MyClip/Core/Prompt/MemoryRules.swift) | 所有记忆写入场景共享的事实、目录、来源、链接和安全规则 |
| [MemoryPrompt.swift](../MyClip/Core/Prompt/MemoryPrompt.swift) | 截图整理、冷启动、做梦、巡检、周汇总的流程与上下文组装 |
| [HandoffPrompt.swift](../MyClip/Core/Prompt/HandoffPrompt.swift) | 整理交接、回退处理与记忆检查结果的提示文字 |
| [TaskPrompt.swift](../MyClip/Core/Prompt/TaskPrompt.swift) | 任务识别、已有任务上下文、JSON 返回约定 |
| [MCPPrompt.swift](../MyClip/Core/Prompt/MCPPrompt.swift) | MCP 初始化指引、资料摘要说明、工具描述和参数定义 |

调用方只传入数据。任务 JSON 的解析留在 `Core/Tasks/TaskResponse.swift`；文件读取、检索、执行 Agent 和写回数据库不放进 Prompt。

修改共享写入规则时只改 `MemoryRules`，避免各个流程的规则产生分歧。纯提示词测试在 `Tests/MyClipCoreTests/Prompt/`；需要真实存储或队列的联动测试留在对应领域。评测专用提示词在 `benchmark/prompts/`，不进入应用。

## 性能与后台工作

应用保留轻量队列/恢复检查，但界面刷新使用 SQLite 按表版本、跨连接 `data_version` 和目录事件按域失效；无变化时不发布 ObservableObject 状态。显式读取立即核对 Memory，后台最长约一分钟做兜底核对。文件解析、哈希、容量和 Memory 校验缓存的失效规则、能耗策略与基准见 [性能与能耗](performance-and-energy.md)。

## 构建与验证

```sh
xcodegen generate
bash Scripts/test.sh
```

`Scripts/test.sh` 是本地与 CI 共用的入口，默认依次运行核心、脚本、benchmark 和原生应用测试。原生测试需要 macOS 图形会话。分组运行和单项筛选见 [测试说明](../Tests/README.md)。

```sh
xcodebuild -project MyClip.xcodeproj -scheme MyClip -configuration Debug build
bash Scripts/package_dmg.sh
```

评测入口、数据隔离和计分口径见 [benchmark](../benchmark/README.md)。公开数据、派生语料、历史运行、缓存、二进制及 API 密钥都留在原位置，由 `benchmark/.gitignore` 排除。
