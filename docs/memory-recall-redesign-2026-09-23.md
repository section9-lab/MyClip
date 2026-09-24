# Memory 召回改造方案：两个工具与 Wikilink 图召回（2026-09-23）

状态：已实施（2026-09-23）。实施结果与评测数字见[召回改造评测](../benchmark/docs/memory-recall-benchmark-2026-09-23.md)（多跳结论已按严格口径更正：多跳没有提升）；与本方案不同的地方列在文末“实施记录”。本文汇总 2026-09-23 的讨论结论：MCP 接口收敛为两个工具，Wikilink 作为图召回引擎在检索内部运行，并给出面向多跳召回的评测方法。前序工作见 [检索与链接图改造](memory-retrieval-design-2026-09-21.md)、[评测协议](../benchmark/docs/memory-benchmark-protocol.md)、[09-21 复跑](../benchmark/docs/memory-benchmark-2026-09-21.md)、[同类方案对照](../benchmark/docs/memory-peer-comparison-2026-09-21.md)。

## 一句话

对外只暴露 `memory_search` 与 `memory_get`；Wikilink 图在 `memory_search` 内部按问题加权传播，结果附带一到两级到达路径；写入侧把实体页写成带日期的"事实行"。不引入图数据库，不做向量检索，不新增设置项，继续支持 macOS 13。

## 一、诊断

### 接口问题

四个工具（`search_memories`、`read_memory`、`get_related_memories`、`get_sources`）加十个搜索参数，Agent 用不对也用不全。真实调用中：

- 单个片段最长 1,600 字，每篇最多 3 段（`MemorySearch.swift:105`），一次搜"MyClip 发布"返回两篇记忆就占满上下文。
- 同一条反链段落在 `related` 中重复出现：一段 Daily 含 3 个链接，同样的段落被附了 3 次。
- 直接命中（`results`）与扩展结果（`related`）分成两个列表，Agent 要自己判断轻重。
- 排序只看相关度，没有新旧信号。

### 多跳召回问题

以 09-21 逐题结果（`benchmark/runs/2026-09-21/locomo-2026-09-21/queries.jsonl`）计算：

| 指标 | LoCoMo 多跳（279 题） | LongMemEval-S 跨会话（121 题） |
|---|---:|---:|
| all@5 | **34.1%** | 69.4% |
| all@10 | 52.0% | 82.6% |
| all@20 | **85.7%** | 95.0% |
| 仅重排前 20 的 all@5 上限 | **83.2%** | 95.0% |
| 平均返回字符数 | 10,659 | 31,662 |

LoCoMo 多跳未进前 5 的 355 个证据文件中，305 个（86%）排在第 6 到 20 位，只有 50 个在前 20 之外。**瓶颈是排序，不是召回深度。**

抽样失败题分三类：

| 类型 | 例子 | 排不上去的原因 |
|---|---|---|
| 聚合（最多） | "Deborah 除了瑜伽还做什么"：骑车、跑步小组、冲浪分散在 4 个会话 | 每条证据用词不同，与问题字面不重合 |
| 桥接 | "Maria 小时候谁给家里钱"：一处说"阿姨帮过家里"，另一处说"靠阿姨们接济" | 需要经过"阿姨"这个中间实体 |
| 演变 | "Sam 逐渐养成的饮食与生活方式"：证据在第 8、9、21、22 会话，排名 9、3、12、2 | 同一件事反复提起，后续说法逐渐偏离 |

**前提**：现有协议的语料是原始会话 Markdown，没有 Wikilink 和实体页，且显式 `expand: false`。图召回迄今没有被 Benchmark 测到过。

### 已有、无需重做的部分

| 能力 | 位置 |
|---|---|
| 标题完全匹配排第一、别名完全匹配排第二 | `MemorySearch.matchingMemories` |
| 其他页面指向本页的链接文字入索引（BM25 权重 3） | `entry_search.anchors` |
| `aliases` 入索引（权重 4），整理 Agent 按规则维护中英文别名 | `entry_search.aliases`、`KnowledgeComposer.swift:12` |
| 中文按 `NLTokenizer` 分词建索引 | `entry_search.terms`、`LibraryStore.swift:771` |
| 一跳扩展、命中段落内链接加倍、多种子累加、根文件与归档不扩展 | `MemorySearch.relatedMemories` |
| 链接精确到段落序号与 `#标题` | `memory_links(ordinal, fragment, target_id)` |
| 多查询倒数排名融合 | `MemorySearch.searchMemoryPage` |
| Profile.md、Now.md 快照写入 MCP instructions | `MemoryMCP.contextDigest` |

## 二、MCP 接口

命名仿照 OpenClaw（`memory_search` / `memory_get`）：`memory_` 前缀加动作，两个工具的输入不同。

```
memory_search { query, since?, until?, app?, limit? }
→ [{ path, title, snippet, time, app, sourceIDs, links?, via? }]

memory_get { path, from?, lines? }
→ { content, links[], backlinks[], sources{ 时间范围, 应用 } }
```

| 项 | 规则 |
|---|---|
| `path` | 支持 `#标题`：`Wiki/Projects/MyClip.md#当前状态` 只读该节 |
| `snippet` | 命中的一两句，约 300 字以内；每篇最多 2 段；同一段不重复。2026-09-24 起去掉“来源：截图 `ID`”，Wikilink 只显示标签（无标签时显示页面名），长度按显示后的文字计算 |
| `links` | 2026-09-24 新增：片段里实际展示的行所指向的页面，`路径` 或 `路径#标题`，可直接交给 `memory_get`；最多 10 个，未解析的链接不列出 |
| `sourceIDs` | 展示段落引用的截图；正文引用了已记录的截图而页面来源列表缺失时，保存时自动补入（2026-09-24） |
| `time` | 有事件时间用事件时间，否则取最近一张来源截图时间；`since` / `until` 按它过滤 |
| `via` | 扩展结果的到达路径，最多两级，每级只有页面、章节和一句事实 |
| `memory_get` 定位 | `from`（起始行）、`lines`（行数），替代字符 `offset` |
| `memory_get` 尾部 | 出链按章节分组、反链按日期排序，每条只有目标、事实句、日期；来源截图的时间范围与应用 |
| 取消的工具 | `get_related_memories`（并入 `via` 与 `memory_get` 邻域）、`get_sources`（并入结果字段） |
| 取消的参数 | `queries`（融合逻辑内部保留）、`expand`、`includeArchives`、`revision`、`timeField`、`includeContext` |
| 兼容 | MCP 服务名不变，已配置的客户端无需重新配置，新会话即拿到新工具 |

## 三、图模型：Markdown 上的业务定义

### 节点（由路径推导）

| 类型 | 文件 | 对应 Zep |
|---|---|---|
| 实体 | `Wiki/People`、`Wiki/Topics`、`Wiki/Projects` | Entity |
| 事件 | `Daily/…`；Benchmark 中的会话文件 | Episode |
| 枢纽 | `Memory.md`、`Now.md`、周报 | Community |

### 边：一次 Wikilink 出现

`memory_links` 现有 `source`、`target_id`、`fragment`、`ordinal`，新增三列：

| 新列 | 来源 | 用途 |
|---|---|---|
| `fact` | 链接所在的句子 | 边的事实描述，相当于 Zep 边上的 fact |
| `section` | 链接所在章节的标题路径 | 关系类别，如"爱好""健康" |
| `date` | 事件节点的路径日期或事件时间标注 | 时间排序与衰减 |

边类型由两端节点推导：事件→实体为**提及**，实体→事件为**证据**，实体→实体为**关联**，来自 `Wiki/Archives` 为**被取代**（默认不走）。

新增全文表 `memory_edge_search(fact, section, target_title)`，用于直接检索边上的事实句。

### 事实行约定

实体页按主题分节，每条事实一行，带事件链接与日期：

```markdown
## 宠物
- 养了两只乌龟，无聊时会带出去散步 [[Daily/2023-06-12|6/12]]
- 给乌龟换了更大的缸 [[Daily/2023-08-02|8/2]]
```

一行即一条带时间的事实边：人可读、可改，解析器可以直接取出 `fact`、`section`、`date`。

## 四、`memory_search` 召回算法

```
问题 ──┬─ 段落 BM25 ───┐
       ├─ 边事实 BM25 ─┼─→ 种子 ─→ 按问题加权的图传播 ─→ 融合打分 ─→ 覆盖度选择 ─→ 结果
       └─ 实体解析 ────┘
```

### 1. 三路种子

- **段落级打分**：文档分数取其最佳段落的 BM25，不再整篇打分，避免长会话被无关内容稀释。不依赖图。
- **边事实检索**：命中 `memory_edge_search` 的边，两端节点都成为种子。
- **实体解析**：标题或别名命中的实体页成为种子（现有逻辑）。

### 2. 按问题加权的图传播

简化版 Personalized PageRank，从种子出发迭代 2 轮，restart 0.5。

- **边权重** = 该边 `fact` + `section` 对问题的 BM25 × 边类型系数 ÷ log(1 + 节点度数)。与现状"链接在命中段落里就加倍"不同：链接所在句子必须和问题相关，才会沿这条边传播。枢纽页自然被抑制，不再依赖硬编码排除。
- **只经实体节点走两跳**：允许"事件→实体→事件"（桥接题所需），不允许"事件→事件→事件"。
- **多种子汇聚加分**：PPR 的固有性质。思路同 HippoRAG（实体图 + PPR），后者在 MuSiQue、2WikiMultiHopQA 等多跳数据集上有显著提升。

### 3. 融合打分

```
score = (0.6 × 字面相关度归一化 + 0.4 × 图传播得分) × 时间衰减
```

时间衰减只作用于事件节点（半衰期 30 天），实体页不衰减。系数为常量，只在开发集上调一次。

### 4. 覆盖度选择

不直接取前 N：贪心地每步选"分数高且补上问题里尚未覆盖的词或实体"的结果（与 xQuAD / MMR 同类）。"Sam 的饮食与生活方式"会依次选入讲 diet、running、hiking 的不同会话，而不是五条都讲 diet。不依赖图。

### 5. 返回

```json
{
  "path": "Daily/2023-06-12.md#散步",
  "snippet": "I was bored today, so I just took my turtles out for a walk.",
  "time": "2023-06-12",
  "sourceIDs": ["…"],
  "via": [{ "page": "Wiki/People/Nate", "section": "宠物", "fact": "无聊时会带乌龟出去散步" }]
}
```

直接命中与扩展结果统一排序。所有常量（迭代轮数、restart、融合权重、半衰期、片段长度、结果上限）写死，不做设置项。

## 五、`memory_get`：节点邻域

读取实体页时，在正文之后返回：

```
links:     按 section 分组 → [{ target, fact, date }]
backlinks: 按 date 排序    → [{ source, fact, date }]
sources:   { 最早与最晚截图时间, 应用列表 }
```

三跳以上的问题由 Agent 读一页、选一条边、再读下一页；自动传播只负责两跳以内。

## 六、写入侧

| 规则 | 做法 | 位置 |
|---|---|---|
| 提到已有页面的实体必须链接 | `MemoryLint` 按标题与 `aliases` 做 CJK 子串匹配，覆盖中文名称（目前只识别拉丁标识符） | `MemoryLint.swift` |
| 实体页按主题分节写事实行 | 整理提示词加入事实行约定 | `KnowledgeComposer.swift` |
| 补建实体页 | 同一名称出现在 3 个以上事件节点且无页面时，做梦任务建页并回填事实行 | `MemoryConsolidation.swift` |
| 按章节局部更新 | 整理只改受影响的 `##` 小节，不重写整页，缓解 128 KB 上限与超时 | 整理提示词与写回逻辑 |

## 七、评测

### 轨道 A：原协议，不改语料

目的是确认不退化，并验证不依赖图的两项：段落级打分、覆盖度选择。沿用[评测协议](../benchmark/docs/memory-benchmark-protocol.md)，每题一次搜索，`limit=20`。协议文字中的 `search_memories` / `expand: false` 相应改为 `memory_search`。

### 轨道 B：整理后的语料（新增）

1. **生成**：用 MyClip 真实整理流程（真实 Agent）把 LoCoMo 会话整理成实体页、事实行与 Wikilink；会话文件原样保留为事件节点。生成一次后固定，所有消融复用。
2. **证据计分沿 `sourceIDs` 追溯**：返回的实体页段落若通过 `sourceIDs` 或事实行链接引用了标准证据会话，计为证据送达。
3. **问答准确率为主指标**：`benchmark_memory_qa.py`，固定阅读与评审模型。
4. **消融阶梯**：

| 级别 | 配置 |
|---|---|
| 0 | 现状，关闭扩展 |
| 1 | 现状，一跳扩展 |
| 2 | + 段落级打分 |
| 3 | + 边事实检索 |
| 4 | + 按问题加权的 PPR |
| 5 | + 覆盖度选择 |

5. **防过拟合**：LoCoMo 对话 00–04 为开发集（调常量），05–09 为测试集（只跑一次）；LongMemEval-S 用于确认不退化。

### 目标

以轨道 A 的 LoCoMo 多跳 all@5 为主要观察指标，现状 34.1%，仅重排的理论上限 83.2%。不预设目标数字，以消融阶梯逐级报告。

## 八、配套更新

- MCP instructions 改为介绍两个工具与 `via` 的含义
- 设置页"如何让 Agent 使用记忆？"按新工具重写，7 种语言同步（`Scripts/localization/update_keys.sh`）
- `MCPAccessTests`、`MemorySearchTests`、`MemoryLinkGraphTests` 等按新接口更新；新增边属性解析、PPR、覆盖度选择、`#标题` 读取、行号定位的测试
- 数据库版本上调，`memory_links` 新列与 `memory_edge_search` 作为派生表在首次同步时重建

## 九、风险与取舍

| 风险 | 控制 |
|---|---|
| 枢纽页噪音 | 边权重按问题加权 + 度数降权 |
| 常量过拟合 | 开发集 / 测试集拆分 |
| 延迟 | 个人库规模为数千节点、数万条边，内存中 2 轮 PPR 为毫秒级 |
| 整理漏链、错链 | 同一份整理语料上做消融，分开检索与写入的贡献 |
| 轨道 B 生成成本 | 10 段对话、每段 19–32 个会话，真实 Agent 整理一次后固定复用 |
| 取消参数后的能力损失 | `queries` 融合内部保留；归档历史可用 `memory_get` 直接读取 `Wiki/Archives` |

## 十、不做的部分

- **向量检索**：暂不做。若日后要做，参考 OpenClaw（向量 0.7 + BM25 0.3、段落缓存），并使用多语言共享向量空间的本地模型；不使用 `NLContextualEmbedding`（按文字体系分模型，不能跨语言，且不是为检索训练）。
- **图数据库与事实级双时间轴**：以事实行日期、Daily 与 Archives 覆盖时间问题。
- **统一改写为英文记忆**：会损失原文细节并影响用户阅读，不采用。
- **升级到 macOS 14**：原为向量模型准备，现不需要。

## 十一、实施顺序

1. **轨道 A 快速收益**：段落级打分、覆盖度选择；在原协议上验证"重排上限 83%"的判断。
2. **图模型扩展**：`memory_links` 加 `fact`、`section`、`date`；新增 `memory_edge_search`。
3. **召回与接口**：边事实检索、PPR、融合打分、`via`；`memory_search` / `memory_get` 收敛；instructions、设置页、测试。
4. **轨道 B 评测**：生成整理语料，跑消融与问答评测。
5. **写入侧**：事实行约定、CJK lint、做梦补建实体页、按章节局部更新。

参考：[OpenClaw Memory](https://docs.openclaw.ai/concepts/memory) · [OpenClaw Memory Search](https://docs.openclaw.ai/concepts/memory-search) · [OpenClaw Builtin engine](https://docs.openclaw.ai/concepts/memory-builtin) · [Mem0 Graph Memory](https://docs.mem0.ai/open-source/features/graph-memory) · [Graphiti](https://help.getzep.com/graphiti/getting-started/overview) · Zep: A Temporal Knowledge Graph Architecture for Agent Memory（arXiv 2501.13956）· HippoRAG（NeurIPS 2024）

## 实施记录（2026-09-23）

按开发集（LoCoMo 00–04）数据调整了以下几处，未写入的设计以本节为准：

| 方案原文 | 实施 | 依据 |
|---|---|---|
| 覆盖度选择（xQuAD / MMR） | 删除 | 权重 0.3 与 0.6 都没有收益，单独开启时逐题零变化 |
| Daily 30 天半衰期衰减 | 删除 | 下限 0.7 与 0.85 都略降低召回；当前状态由 Now.md 与项目页“当前状态”维护 |
| 片段约 300 字、每篇 1–2 段 | 按行选取：每行按查询词的 IDF 计分，段落按最佳行排序，长段落只保留得分最高的几行；每条结果 2 段 × 300 字 | 曾按宽口径选定 3 段 × 360 字；复核后改回 2 × 300，严格口径下检索指标基本持平，返回量少三分之一，代价是长发言更常被截断（见评测报告） |
| 边权重下限未定 | 0.05 | 0.25 时人物页上百条边会稀释少数匹配的事实行 |
| 列表要点单独成段 | 未采用 | 片段带出的事实行变少，00–01 上多跳从 39.5% 降到 34.9% |
| 时间过滤 | `observed`：有事件标注的页面按事件段落，否则同一张引用截图同时满足时间与应用，都没有时按编辑时间 | 保留原 `captured` / `event` 两种模式的精度 |
| 简化版 PPR，迭代 2 轮，restart 0.5 | 显式两步扩散：种子一跳，第二跳只从非种子的实体页出发，不回到来路 | 与“只经实体节点走两跳”的约束等价，且便于给出 `via` |
| `queries` 融合逻辑内部保留 | 删除 | `memory_search` 只接受一个 `query`，内部没有使用方 |
| 问答准确率为主指标 | 本次只报检索与证据送达指标 | 问答评测依赖的 API 密钥失效，未运行 |
| 整理后语料由 MyClip 整理流程生成 | 由 Claude Sonnet 子 Agent 按固定提示词逐会话抽取事实行，脚本拼装页面 | 评测 API 密钥失效、本机命令行未登录；真实整理流程以截图为输入，不适用于文本会话 |

MCP 服务额外拒绝未知参数，旧参数（`timeField`、`queries`、`offset` 等）返回错误而不是被忽略。
