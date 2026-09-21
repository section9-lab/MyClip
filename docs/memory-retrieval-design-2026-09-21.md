# Memory 检索与链接图改造（2026-09-21）

本文记录 2026-09-21 对 MyClip 记忆检索层的一次结构性修改：让检索器感知 Wikilink 图、缩小 MCP 载荷、把 Agent 协议改为搜索优先、并给写入规则加上可执行的检查。配套评测口径见 [评测协议](memory-benchmark-protocol.md)，此前定位出的短板见 [本地评测报告](memory-benchmark-2026-09-20.md)。

## 起因

两条真实召回轨迹暴露了问题。第一条：Agent 按 MCP 指令先读 Memory.md，从目录里猜了 section9-lab 去读，两页都没有 JEV，最后退回到对仓库跑 `rg`。第二条：直接 `search_memories("JEV")` 一次命中五个文件。差别不在存储，在导航策略和接口设计。

同一轨迹还显示：一次读取 Memory.md 返回三百多个 `contextSourceIDs`，五条搜索命中的返回体约九成是 UUID；Daily 里大量 `[[页面#标题]]` 形式的锚点链接在 `get_related_memories` 中全部是断链；JEV 被五个文件提到却没有页面，chat-bridge 页明确写着“不作为独立主题记录”。

## 根因与对应改动

| 根因 | 改动 | 位置 |
|---|---|---|
| 图只存在于文本，索引有损：链接表存原始字符串，锚点被丢，锚文本无归属 | `memory_links` 增加 `target_id`、`fragment`、`ordinal`；写入时解析目标，文件出现或删除时重解析；`Wikilink` 解析 `#` 片段；其他文件的显式链接标签进入目标页的 `anchors` 字段（BM25 权重 3） | `Wikilink.swift`、`LibraryStore.swift` 表结构、`MemoryVault.swift` 同步 |
| 检索是文档级单信号 | 检索后沿解析图扩展一跳，返回 `related`，每个邻居附带“从哪篇、哪条链接、链接所在段落”；FTS5 改用 `porter unicode61` 处理英文词形 | `MemorySearch.swift` |
| 溯源数据混进检索响应 | 列表只返回 `sourceCount`、`contextSourceCount`；段落自带 `sourceIDs`；`read_memory` 保留文档级 `sourceIDs`，`contextSourceIDs` 需 `includeContext: true` | `MemoryMCP.swift` |
| Agent 协议鼓励猜目录、单查询 | instructions 改为搜索优先；`search_memories` 接受 `queries` 数组并做倒数排名融合，命中标注 `matchedQueries`；`Wiki/Archives` 默认排除 | `MemoryMCP.swift`、`MemorySearch.swift` |
| 写入规则是散文，没有执行点 | `MemoryLint` 在每批整理后检查断链、提到已有页面却未链接、多处出现却无页面的名词、过长的项目页与 Now.md，结果写入交接记录；prompt 增加实体页与锚点链接规则 | `MemoryLint.swift`、`OrganizationHandoff.swift`、`KnowledgeComposer.swift` |

数据库版本升到 10。旧库首次打开时删除并在首次同步时重建三张派生表（全文、段落全文、链接边），过程用 `vault_meta.search_rebuild` 标记，崩溃后可恢复。

## 在真实资料库副本上的对照

对用户资料库的副本（52 个文件、300 条链接边）分别用 2026-09-20 的 release 二进制和本次 debug 二进制执行同一查询 `JEV`，`limit=5`：

| 指标 | 旧 | 新 |
|---|---:|---:|
| 搜索返回文本字符数 | 94,084 | 14,695 |
| 其中 UUID 字符占比 | 80% | 3% |
| 读取 Memory.md 返回字符数 | 17,287 | 2,136 |
| 前五命中里的归档快照 | 1 | 0 |
| 返回的一跳邻居 | 无 | MyClip（0.917）、ego-lite（0.25） |
| 链接边解析成功数 | 不适用 | 300 / 300，其中 44 条带标题片段 |
| `get_related_memories` 读 chat-bridge 页的返回字符数 | 38,942（含 17 条指向自身章节的边） | 21,869（自链接与归档来源已排除） |

多查询 `["JEV", "TypeSafe", "路由"]` 下，Daily 2026-09-20 与 chat-bridge 页同时命中三个子查询并排在前两位。

这些是单次本机观测，不是评测分数；LoCoMo 与 LongMemEval 基线在协议里显式传 `expand: false`，保持与 9 月 20 日结果可比。链接扩展的收益需要在带链接的语料上另行评测。 改造后按原协议复跑的结果见 [2026-09-21 复跑报告](memory-benchmark-2026-09-21.md)：LoCoMo all@5 77.5% → 78.9%，多跳 26.9% → 34.1%；LongMemEval-S all@5 83.4% → 84.5%，跨会话 66.1% → 69.4%。这部分提升来自词干归一化，单跳与开放域有小幅边界抖动。

## 邻居评分规则

种子按排名取权重 `0.5 / (1 + rank)`。同一种子到同一邻居只计一次，取最大值；链接所在段落如果正好是本次命中的段落，权重翻倍。根文件（Memory.md、Profile.md、Now.md）不作为种子扩展，也不作为邻居返回；页面指向自身章节的链接不计入关系。默认最多返回 8 个邻居，每个邻居最多保留 3 条不同的到达路径。

## 兼容性与已知取舍

- `content.text` 仍与 `structuredContent` 同时返回，遵守 MCP 对不支持结构化内容客户端的兼容建议；载荷缩减来自去掉 UUID 列表而不是去掉双重序列化。
- 链接路径文本仍被全文索引：Daily 里写 `[[Wiki/Projects/Shanghai|上海行程]]` 会让该 Daily 命中 `Shanghai`。这保持了原有行为，但意味着邻居有时与命中重叠。
- `MemoryLint` 的候选实体只看拉丁字母标识符（含大写、数字或连字符），中文名词暂不识别；停用词表是手工维护的。
- 写入检查全部是软性提示，通过交接记录进入下一批整理，不阻塞保存。

## 后续

1. 用当前真实 Memory 目录做中文开发集，度量 all@5、命中所需跳数与返回字符数。
2. 在 LoCoMo 语料上合成实体页与回链，对照 `expand` 开关测多跳题的收益。
3. 观察 lint 提示被 Agent 采纳的比例，再决定哪些提示升级为提交时的硬约束。
