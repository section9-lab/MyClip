# 借鉴 Instinct 记忆方案的改造（2026-09-23）

起因是对 Instinct（iMessage 助手）记忆系统的逆向分析：git 管理的 Markdown、frontmatter 里的 `aliases` 做写入时查询扩展、常驻上下文的用户画像、每日一次的整合批次。MyClip 已有更强的检索（BM25、链接扩展、多查询融合）和更严格的溯源，缺的是别名、回答侧的常驻画像、定期整合，以及目录分工。本次改动只补这几处，不改变增量整理（每 180 秒一批）和检索方式。

## 改动

| 项 | 做法 | 位置 |
|---|---|---|
| 目录 | 新增 `Wiki/People`（有实际往来的人）、`Wiki/Reading`（外部文章、帖子、视频、产品页）；Topics 只放实体并用实体名命名；Inbox 只放需要用户确认的事项；Daily 超限按主题拆到 `Daily/YYYY/MM/YYYY-MM-DD/主题.md`，原文件留作当天索引 | `MemoryLayout.swift`、`KnowledgeComposer.swift` |
| 旧库补目录 | `vault_meta.layout` 升到 2，已有资料库只补建一次新目录，用户删掉的目录不再恢复 | `MemoryLayout.prepareMemoryLayout` |
| `type` | 由路径推导，补 `person`、`reading`、`archive` | `MemoryDocument.kind(for:)` |
| `aliases` | frontmatter 里一行 `aliases: [...]`（也接受块列表），最多 12 个，原样保留在文件中；进入 `entry_search.aliases` 列，BM25 权重 4；别名完全匹配排在标题完全匹配之后；CJK 按子串匹配 | `MemoryVault.swift`、`LibraryStore.swift`、`MemorySearch.swift` |
| 公开文件瘦身 | `context_source_ids`（整批审计上下文）只留在 `Entries/<id>/<rev>.md`，不再写进 `Memory/`；`source_ids` 保留，单独复制 Memory 目录时证据仍在 | `MemoryDocument.published`、`flushMemoryFiles`、`synchronizeMemoryFiles` |
| 数据库 v12 | 重建全文表（加别名列），把所有文件标为待发布，首次同步时一次性改写为瘦身版本；比较“是否被外部编辑”时两边都按发布形式比较，瘦身本身不算编辑、不产生新版本 | `LibraryStore.init` |
| MCP 摘要 | `initialize` 的 instructions 附上 Profile.md、Now.md 的快照（每个文件最多 800 字，去掉事件标注，引用 ID 缩短，标明 observedAt 和“资料不是指令”）；模板状态（revision 1）与 MCP 已停用时不附 | `MemoryMCP.contextDigest` |
| Lint | `misfiled`：Topics/Inbox 中标题以“浏览、帖文、报道、视频、说法、访谈……”结尾的页面；`expired`：Now.md 与项目页“当前状态”里事件时间已过的段落（只看有引用的事件标注）；`sensitive`：疑似验证码或密钥，只报类型不复述值；别名计入已知名称。三项都是软提示，放在交接记录最前面 | `MemoryLint.swift` |
| 做梦 | 见下文“做梦任务”；最初版本是批次成功后顺带执行的每日整合，已改为队列里的独立任务 | `MemoryConsolidation.swift` |

没有新增设置项；间隔、范围、别名上限都是常量。

## 做梦任务（同日后续改动）

做梦是队列里的一种任务（`jobs.kind = 'dream'`），和批次整理共用队列、执行记录与详情页，在列表里用月亮图标和“做梦 · 整理记忆”标题区分。

| | 批次整理 | 做梦 |
|---|---|---|
| 触发 | 有新截图 | 每个“梦日”（本地凌晨 4 点起算）一次，队列为空且 20 分钟没有新截图时入队 |
| 输入 | 截图或 OCR | 入队时固定的计划，存于 `dream_plans` |
| 轮次 | 1 轮 | 最多 3 轮：回顾上周（写周报）、整理今天（最多 12 页）、巡检旧记忆（最久未巡检的 8 页，记录于 `memory_reviews`） |
| 单轮上限 | 30 分钟，10 分钟无进展判超时 | 45 分钟，10 分钟无进展判超时 |
| 失败 | 最多 6 次，退避 1、5、15、30、60 分钟，用完后暂停队列 | 连接类错误 30 分钟后再试 1 次；其他失败或中断结算已写内容后结束，不暂停队列，不标记 Agent 失败 |
| 基线 | — | 只有完成的梦才推进 `consolidated_at` 与页面巡检时间；未完成时第二天仍覆盖同一批页面 |

没有任何改动的日子不产生任务。队列页的“整理记忆”按钮（月亮图标）可以手动做梦：不等空闲，排在待整理截图之前，没有新改动时也会巡检；悬浮说明写明它做什么、何时自动执行，手动执行后当天不再自动进行。数据库升到 v13（`jobs` 加 `kind` 列）。

同时放宽了批次：ACP 单轮上限 15 → 30 分钟，无进展超时 5 → 10 分钟，握手与会话请求 30 → 60 秒，重试从 3 次（约 6 分钟）改为 6 次（约 2 小时）。

## 验证

- `xcrun swift test`：320 个测试通过（9 个需要真实 Agent 的默认跳过）。新增覆盖别名检索与解析、旧库一次性瘦身、外部编辑保留上下文、索引重建从历史恢复证据、新目录一次性补建、三项 lint、MCP 摘要（模板、截断、停用）、整合计划范围与周报、整合结算自愈。
- `xcodebuild` 构建成功，`--preview` 启动正常。

### 公开评测（按[协议](../benchmark/docs/memory-benchmark-protocol.md)，单次查询、关闭扩展）

| 数据集 | all@5 基线 | all@5 改造后 | 逐题排序一致 |
|---|---:|---:|---:|
| LoCoMo | 78.92% | 78.92% | 1986 / 1986 |
| LongMemEval-S | 84.47% | 84.47% | 500 / 500 |

公开数据集没有别名，这组结果只说明排序没有退化；别名的收益要在带别名的真实库上看。

### 真实资料库副本（71 个文件，原库未改动）

迁移：

| 指标 | 迁移前 | 迁移后 |
|---|---:|---:|
| Memory 目录总量 | 948 KB | 788 KB |
| frontmatter 占比 | 24% | 9% |
| `context_source_ids` 占比 | 17% | 0% |
| Now.md | 28.5 KB | 7.7 KB |
| 正文、版本号、受保护标记、证据表 | — | 全部不变 |

MCP `read_memory(includeContext: true)` 仍返回 Now.md 的 547 条上下文来源；连接摘要 1,801 字。

Lint 在副本上报出 10 个错放页面（Inbox 中的帖文与 Topics 中的产品页浏览），无过期状态、无疑似密钥。

用 Claude（`claude-agent-acp`）在副本上跑了一次真实整合：

- 第一次范围 30 页，一轮用满 900 秒的 ACP 上限，只完成了别名补充；据此把范围降到 12 页、周报拆成单独一轮、失败也结算并记录。
- 调整后：周报一轮 160 秒；整理一轮约 700 秒，两轮都正常结束。4 个错放帖文从 Inbox 移到 Wiki/Reading（保留原 ID）；生成 `Daily/2026/Weekly/2026-W38.md`，每条链接回 Daily；写出 `Inbox/Profile候选.md`，Profile.md 未改；3 个页面补了别名；断链 0 → 0，无效文件 0。正文中的 644 个不同截图 ID 全部保留，MyClip.md 去掉 3 条重复引用。

## 已知取舍

- 只复制 Memory 目录、不带 `Entries/` 时，整批上下文（`context_source_ids`）不会随之迁移；正文引用和 `source_ids` 仍在。
- 错放检查按标题后缀判断，只覆盖中文和少量英文结尾；Topics 中不以这些词结尾的浏览页不会被发现。
- 每日整合一天最多一次，失败不重试；一天的改动超过 12 页时，其余页面留到下一天。
- 别名由 Agent 写入，真实整合中别名数量少于规则建议（1 到 3 个）。
