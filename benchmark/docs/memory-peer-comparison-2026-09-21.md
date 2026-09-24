# MyClip 两版检索器与同类方案的对照（2026-09-21）

核验日期：2026-09-21。本文把三件事放在一起看：MyClip 09-20 与 09-21 两版检索器在两个公开数据集上的逐类表现；能与同类方案按同一指标并列的部分；以及只能并排展示、不能直接比较的公开成绩。评测方法见 [协议](memory-benchmark-protocol.md)，两次本地运行的完整报告见 [09-20](memory-benchmark-2026-09-20.md) 与 [09-21](memory-benchmark-2026-09-21.md)。

## 一、MyClip 两版检索器对照

09-21 版的改动是 FTS5 加 porter 词干、链接图索引、一跳扩展、多查询融合和载荷缩减；按协议单次查询、关闭扩展测得的差异只反映词干与排序变化。

### LoCoMo（1,532 道可计分题，10 段对话）

| 题型 | 题数 | all@5 09-20 | all@5 09-21 | 发言覆盖@5 09-20 | 09-21 | 逐题翻转（升 / 降） |
|---|---:|---:|---:|---:|---:|---|
| 单跳 | 840 | 95.0% | 94.3% | 62.8% | 63.1% | +14 / −20 |
| 时间 | 321 | 84.4% | 87.2% | 68.8% | 71.1% | +16 / −7 |
| 开放域 | 92 | 47.8% | 45.7% | 27.3% | 24.8% | +3 / −5 |
| 多跳 | 279 | 26.9% | 34.1% | 25.8% | 28.5% | +32 / −12 |
| 总体 | 1,532 | 77.5% | 78.9% | 55.2% | 56.2% | +65 / −44 |

### LongMemEval-S cleaned（470 道可计分题，每题 38 到 62 个会话文件）

| 题型 | 题数 | all@5 09-20 | all@5 09-21 | 发言覆盖@5 09-20 | 09-21 | 逐题翻转（升 / 降） |
|---|---:|---:|---:|---:|---:|---|
| 单会话：用户事实 | 64 | 100.0% | 98.4% | 81.2% | 79.7% | 0 / −1 |
| 单会话：助手内容 | 56 | 100.0% | 100.0% | 19.6% | 19.6% | 0 / 0 |
| 单会话：偏好 | 30 | 83.3% | 83.3% | 48.9% | 48.9% | +2 / −2 |
| 跨会话 | 121 | 66.1% | 69.4% | 58.2% | 59.5% | +9 / −5 |
| 知识更新 | 72 | 95.8% | 98.6% | 83.8% | 84.3% | +2 / 0 |
| 时间推理 | 127 | 77.2% | 77.2% | 75.4% | 75.8% | +3 / −3 |
| 总体 | 470 | 83.4% | 84.5% | 64.7% | 65.0% | +16 / −11 |

两个数据集上的形态一致：需要汇集多篇证据的题型（多跳、跨会话、时间）受益最大，单篇精确定位的题型持平或有 1 到 2 题的边界抖动。LoCoMo 每段对话只有 19 到 32 个文件，LongMemEval 每题 38 到 62 个，所以同样的 all@5 在 LongMemEval 上更难达到；MyClip 在候选更多的 LongMemEval 上总体分更高，说明它的弱项不是候选规模，而是证据分散。

## 二、能按同一指标并列的部分：LongMemEval 500 题会话召回

Sibyl 公开了 500 题口径的会话级 Recall@5 及分类结果，这是目前唯一能与 MyClip 逐类对齐的同行数字。以下把 MyClip 两版按同一口径重算（含 30 道拒答题，只检查其标注会话是否被找到）。重算脚本对 09-20 数据的结果与 [09-20 对照](memory-peer-comparison-2026-09-20.md) 完全一致。

| 类别 | 题数 | MyClip 09-20 Recall@5 | MyClip 09-21 Recall@5 | Sibyl 公布 Recall@5 | 09-21 与 Sibyl 差，百分点 |
|---|---:|---:|---:|---:|---:|
| 用户事实 | 70 | 98.57% | 98.57% | 100.00% | −1.43 |
| 助手内容 | 56 | 100.00% | 100.00% | 100.00% | 0.00 |
| 偏好 | 30 | 83.33% | 83.33% | 100.00% | −16.67 |
| 跨会话 | 133 | 83.32% | 86.90% | 95.33% | −8.43 |
| 知识更新 | 78 | 98.08% | 98.72% | 98.72% | 0.00 |
| 时间推理 | 133 | 87.39% | 86.92% | 94.01% | −7.09 |
| 整体 | 500 | 90.71% | 91.64% | 96.96% | −5.32 |

同口径的 Hit@5：MyClip 09-21 为 97.40%（09-20 为 96.80%），Sibyl 100.00%，AutoMem 公布 97.00%，MemPalace raw 基线公布 96.60%。Sibyl 用 OpenAI 向量加图混合检索；MyClip 是纯本地 BM25，无向量、无外部服务。差距集中在偏好、跨会话、时间三类，与本地评测里定位的短板一致。

## 三、只能并排、不能直接比较的公开成绩

以下数字于 2026-09-21 逐条核验来源。它们属于三种不同的指标族：第三方同套件问答成绩、项目方自报问答成绩、检索召回。不同族之间不能排序；同一族内阅读模型、评审模型、题目范围也不统一。MyClip 目前只有第三族的数字。

### 第三方同套件：ProsusAI MemEval，LoCoMo 全部 1,986 题，gpt-4.1-mini 阅读，gpt-5.2 评审

| 系统 | 答案 token F1 | LLM 评审准确率 |
|---|---:|---:|
| PropMem（套件作者所提） | 60.5 | 82.3 |
| OpenClaw | 55.7 | 72.5 |
| 全上下文基线（不用记忆系统） | 54.2 | — |
| Hindsight | 48.9 | 67.6 |
| Graphiti（Zep 开源版） | 41.6 | 57.3 |
| SimpleMem | 35.8 | 47.8 |
| Mem0 | 34.4 | 49.7 |
| MemU | 29.9 | 39.9 |
| MyClip | 未测 | 未测 |

来源：[ProsusAI/MemEval README](https://github.com/ProsusAI/MemEval)，2026-03-06。同一套件另有 LongMemEval-S 102 题分层抽样结果：PropMem 0.716、SimpleMem 0.667、OpenClaw 0.598（二元准确率，gpt-4.1 阅读）。作者注明 Mem0 当时的时间戳缺陷压低了其时间类分数，MemU 自报的 92.09% "不可直接比较"。

### 项目方自报：问答准确率

| 系统 | LoCoMo | LongMemEval-S | 阅读 / 评审模型 | 来源与日期 |
|---|---:|---:|---|---|
| Zep 平台 | 94.7%（1,540 题） | 90.2% | gpt-5.4 / gpt-5.4 | [getzep.com/research](https://www.getzep.com/research)，未注日期 |
| Zep 论文 | — | 71.2% | GPT-4o | [博客](https://blog.getzep.com/state-of-the-art-agent-memory)，2025-01-22 |
| Mem0 平台 v3 | 92.5%（1,540 题） | 94.4% | gpt-4o / gpt-4o | [memory-benchmarks](https://github.com/mem0ai/memory-benchmarks)，2026-05-13 |
| Mem0 论文 | 66.88 / Mem0g 68.44（无对抗题） | — | gpt-4o-mini | [arXiv 2504.19413](https://arxiv.org/abs/2504.19413)，2025-04-28 |
| Hindsight | 89.61%（四类题） | 91.4% | Gemini-3 | [hindsight-benchmarks](https://github.com/vectorize-io/hindsight-benchmarks)，2026-08-31 |
| AutoMem | 84.74%（1,986 题） | 87.0% | gpt-5-mini 阅读，gpt-5.4-mini 评审 | [EXPERIMENT_LOG](https://github.com/verygoodplugins/automem)，2026-05-17 |
| Supermemory | 宣称第一，无数字 | 81.6%（GPT-4o）/ 84.6%（GPT-5）/ 85.2%（Gemini-3） | 如列 | 数字仅见于 Hindsight 的汇总表；[supermemory.ai/research](https://supermemory.ai/research) 无数字 |
| SimpleMem 论文 | F1 43.24 | 83.97%（gpt-4.1 评审） | gpt-4.1-mini | [arXiv 2601.02553](https://arxiv.org/abs/2601.02553)，2026-01-29 |
| MemU 旧版 | 92.09% | — | 未注明 | [memu.pro/benchmark](https://memu.pro/benchmark)，页面标为历史版本 |
| Memobase | 75.78%（四类题） | — | gpt-4o 评审 | [locomo-benchmark](https://github.com/memodb-io/memobase)，2025-07-12 |
| Letta 文件系统 | 74.0% | 未找到 | GPT-4o-mini | [博客](https://www.letta.com/blog/benchmarking-ai-agent-memory)，2025-08-12 |
| OpenClaw 自报 | 未找到 | 未找到 | — | 仅有 MemEval 第三方数据 |
| MyClip | 未测 | 未测 | — | — |

### 检索召回：与 MyClip 同族

| 系统 | 数据集 | 指标 | 数值 | 来源 |
|---|---|---|---:|---|
| Sibyl | LongMemEval-S 500 题 | Hit@5 / Recall@5 | 100.00% / 96.96% | [sibyl](https://github.com/hyperb1iss/sibyl)，2026-07-24 |
| MyClip 09-21 | LongMemEval-S 500 题 | Hit@5 / Recall@5 | 97.40% / 91.64% | 本文第二节 |
| AutoMem | LongMemEval-S | Recall@5（实为 Hit@5 定义） | 97.00% | 同上 AutoMem |
| MyClip 09-20 | LongMemEval-S 500 题 | Hit@5 / Recall@5 | 96.80% / 90.71% | 09-20 对照 |
| MemPalace | LongMemEval-S | R@5 | 96.6% raw，98.4% hybrid（450 题保留集） | [mempalace](https://github.com/mempalace/mempalace)，2026-09-15 |
| MemPalace | LoCoMo | 会话 R@10 | 60.3% raw，88.9% hybrid v5 | 同上 |

MemPalace 的 LoCoMo 会话 R@10 与 MyClip 的文件级 recall@10 定义接近但语料序列化不同（MemPalace raw 只索引用户发言）；MyClip 09-21 的 LoCoMo 文件级 recall@10 为 91.1%，可作为方向参考，不能视为同场对照。

### 为什么不能把 MyClip 放进问答榜

- MyClip 的数字是"证据文件是否进入前五"，没有答案模型，没有评审模型。问答准确率既受检索影响，也受阅读模型、上下文预算和提示词影响。Zep 同一系统在 GPT-4o 与 gpt-5.4 下相差近 20 个百分点，Mem0 论文与平台版相差 25 个百分点，说明阅读模型的贡献不小于记忆系统本身。
- 题目范围不同：Mem0 平台与 Zep 用 1,540 题（去掉对抗类），MemEval 与 AutoMem 用 1,986 题，Hindsight 与 Memobase 只报四类。
- 部分"第三方"榜单由厂商运营：AMB 由 Hindsight 的公司 Vectorize 运营；Hindsight 表中的其他厂商行是自报。Mem0 在 2025-05 复现 Zep 得 58.44%，与当时 Zep 自报的 84% 相差很大。Mem0 自己 2026-09-18 的博客也承认没有两家共用同一模型栈与评审。

要给 MyClip 一个能进榜的数字，需要固定答案模型和评审模型，按 LongMemEval 官方问答格式或 MemEval 套件跑全部题目并保留逐题记录。这是 09-20 报告列出的下一层评测，目前未执行。

