# MyClip 各版本与 Mem0、MemU、OpenClaw、Supermemory 的评测对比（2026-09-24）

资料核验日期：2026-09-24。四家的公开结果由逐家深度检索整理，只采用一手来源（官方仓库与结果文件、论文、官方博客与文档）；第三方复测单列。MyClip 的数字来自 `benchmark/runs/` 下的逐题结果，三个版本见[版本对比](memory-version-comparison-2026-09-24.md)。

## 结论

- **四家的标题数字都是问答准确率**（阅读模型作答、大模型评审判对错），与 MyClip 的检索召回不是同一类指标，不能直接比较。MyClip 的问答层评测因模型网关无可用模型尚未运行。
- **能对上口径的检索数字只有三组**，都不是四家的标题数字：Mem0 博客里的 LongMemEval Retrieval@10、第三方论文 All-Mem 对 Mem0 的实测、Supermemory 一个未合并 PR 里的纯向量实验。OpenClaw 与 MemU 没有任何 LoCoMo / LongMemEval 检索数字。
- **与这三组对比**：
  - 按会话计，MyClip 当前版本在 LongMemEval 上高于 Mem0：全部证据会话进入前 10 为 91.7%，Mem0 为 78.7%–80.4%；会话 R@5 为 93.1%，第三方测得 Mem0 为 90.2%。
  - 按证据原文是否出现在返回内容里计，MyClip 低于 Mem0：前 10 条结果的片段里显示出全部证据发言的只有 62.8%。
  - LoCoMo 按轮计，MyClip（R@5 50.1%、MRR 0.446）高于第三方测得的 Mem0（R@5 38.7%），低于 Supermemory 的纯向量实验（R@5 67.0%、MRR 0.582）。
- **MyClip 三个版本在这些口径上多数上升**：LongMemEval 全部证据进前 10 从 89.8% 升到 91.7%，会话 R@5 从 91.2% 升到 93.1%，LoCoMo 按轮 R@5 从 46.7% 升到 50.1%。唯一下降的是证据原文完整出现在片段里的比例，原因是片段从 1,600 字截到 300 字。
- **四家公开结果的可复现性普遍不足**：只有 Mem0 的 2026 年 4 月结果和 MemU 的早期结果公开了逐题文件；Mem0 的当前标题数字 92.5 / 94.4 没有逐题文件，且同一个 92.5 有三套互相矛盾的分题型数字；Supermemory 把 81.6% 的问答准确率改标成“Recall@15 95%”，后又改为“Recall@20 97%”；OpenClaw 官方从未发布评测数字。

## 一、四家公开了什么

| 系统 | 标题数字 | 指标 | 检索召回 | 逐题结果 | 主要问题 |
|---|---|---|---|---|---|
| Mem0 | LoCoMo 92.5%，LongMemEval-S 94.4%（平台 v3，2026-05） | 问答准确率；gpt-5 阅读、gpt-5 评审，每题取 200 条记忆（约 7k tokens） | 官方博客 LongMemEval Retrieval@10：78.71%（Qwen3-0.6B 向量）、80.38%（Nemotron 向量）；无 LoCoMo、无 k=5、无代码 | 4 月的 91.6% / 93.4% 有；当前 92.5% / 94.4% 没有 | 评审提示宽松（“拿不准就判对”，日期差 14 天内算对）；LoCoMo 作答提示里含与个别标准答案对应的提示；同一个 92.5 有三套分题型数字 |
| MemU | LoCoMo 92.09%（0.1.x 早期版本，2025-07） | 问答准确率；gpt-4.1-mini 阅读、gpt-4.1 评审；多轮迭代检索，每题取 25–43 条事件 | 无 | 早期版本有（result.json，1,542 题） | 已从 README 撤下，官网注明不代表当前架构；当前 2.0 版本无任何公开结果；第三方复测 38%–67% |
| OpenClaw | 无（官方从未发布） | — | 仅 GitHub issue 中 10–57 题的私人小样本（recall@1、hit@k 等） | — | 第三方 MemEval 测的是 2 月代码的 Python 移植版，带有后来修复的计分问题，且不记录检索结果 |
| Supermemory | LongMemEval-S 81.6% / 84.6% / 85.2%（gpt-4o / gpt-5 / gemini-3，2025-12）；后改为“Recall@15 95%”“Recall@20 97%” | 问答准确率（gpt-4o 评审）；“Recall@k with aggregation”未定义，每个结果位是大模型合成的多条记忆 | 官方无；未合并 PR #59 的纯向量实验（不含 Supermemory 流程）：LoCoMo 按消息 R@5 67.0%、R@10 75.6%、MRR 0.582 | 从未公开 | 81.6% 被自己标为“不正确”后撤下；LoCoMo 只写“#1”；博客里“LoCoMo Recall@10 83.5%”无定义，已删除 |

## 二、能对上口径的检索数字

### 1. LongMemEval：前 10 条是否包含全部证据

Mem0 的定义：前 10 条记忆中，包含回答所需的每一个对话轮的证据；只统计有证据的 479 题（470 道可计分题 + 9 道有证据的拒答题）。MyClip 用同一 479 题，给出两种算法：按会话文件是否进入前 10，以及按证据发言是否显示在前 10 条结果的片段里。

| 系统 | 口径 | 数值 |
|---|---|---:|
| Mem0（官方博客，2026-07） | 10 条抽取出的记忆，按对话轮 | 78.71%（Qwen3-0.6B）/ 80.38%（Nemotron-3-Embed） |
| MyClip 09-20 / 09-21 / 09-24 | 10 个会话文件，全部证据会话进入前 10 | 89.8% / 90.8% / **91.7%** |
| MyClip 09-20 / 09-21 / 09-24 | 前 10 条结果的片段里显示出每条证据发言的开头 | 64.9% / 65.3% / 62.8% |
| MyClip 09-20 / 09-21 / 09-24 | 同上，要求证据发言完整出现 | 55.5% / 55.9% / 19.0% |

两者的单位不同：Mem0 的一条结果是一条抽取出的事实（短），MyClip 的一条结果是一个会话文件加 2 段 × 300 字片段。按“找到正确会话”算，MyClip 领先约 11 个百分点；按“证据内容已经交到阅读模型手里”算，MyClip 落后约 16 个百分点。后者受片段长度直接影响：09-21 的片段每段最多 1,600 字，完整出现的比例是 55.9%，09-24 截到 300 字后降到 19.0%。

### 2. LongMemEval：会话级 R@5 与 NDCG@5

第三方论文 All-Mem（arXiv 2603.19595 v2，2026-06）用 gpt-4o-mini 生成、相同上下文预算实测 Mem0。R@5 是前 5 条中找到的证据会话占全部证据会话的比例（不是“全部找到”）。

| 系统 | R@5 | NDCG@5 |
|---|---:|---:|
| Mem0（All-Mem 实测；Mem0 版本与记忆到会话的对应方式未说明） | 90.17% | 87.14% |
| MyClip 09-20（470 道可计分题） | 91.20% | 88.05% |
| MyClip 09-21 | 91.99% | 88.75% |
| MyClip 09-24 | **93.12%** | **90.36%** |

含 30 道拒答题的 500 题口径下，MyClip 09-24 为 92.77% / 90.08%。

### 3. LoCoMo：按对话轮的 R@5、R@10、MRR

Supermemory 的纯向量实验（MemoryBench PR #59，2026-08-12，未合并）直接对原始消息排序：只用 Gemini 向量（1,536 维），不经过 Supermemory 的记忆抽取与重排；1,527 道非对抗题；R@k 为前 k 条消息中标准证据消息的比例，MRR 看第一个证据的名次。All-Mem 对 Mem0 的 LoCoMo 数字也是按轮计的 R@5。

MyClip 返回的是会话文件与片段，把各结果的片段按排名顺序展开成对话轮列表：片段显示出某条证据发言的开头，就算这条发言被检索到（1,532 道可计分题）。

| 系统 | R@5 | R@10 | MRR |
|---|---:|---:|---:|
| Supermemory 纯向量实验（不含 Supermemory 流程） | 67.0% | 75.6% | 0.582 |
| Mem0（All-Mem 实测） | 38.74% | — | — |
| MyClip 09-20 | 46.7% | 52.4% | 0.394 |
| MyClip 09-21 | 47.3% | 53.4% | 0.399 |
| MyClip 09-24 | **50.1%** | **53.5%** | **0.446** |

按题型的 R@10（Supermemory 未说明题型编号的对应方式，按常见的 1 = 多跳、2 = 时间、3 = 开放域、4 = 单跳理解）：

| 题型 | Supermemory 纯向量 | MyClip 09-20 | 09-21 | 09-24 |
|---|---:|---:|---:|---:|
| 单跳 | 84.7% | 60.9% | 60.9% | 59.9% |
| 时间 | 75.3% | 64.6% | 68.2% | 67.5% |
| 多跳 | 49.1% | 21.8% | 23.9% | 27.8% |
| 开放域 / 常识 | 46.8% | 25.1% | 23.3% | 24.7% |

MyClip 在按轮口径上落后于纯向量的消息级排序，有两个原因：一是 MyClip 先排会话再显示每个会话最多 2 条发言，前 5 条“发言”只来自前 3 个会话，而消息级排序的前 5 条可以来自 5 个不同会话；二是 LoCoMo 多跳题中 71% 至少有一条证据与问题没有共同实词，关键词检索够不着，向量可以（见[召回改造评测](memory-recall-benchmark-2026-09-23.md)的多跳分析）。

## 三、问答准确率（MyClip 未测）

以下数字属于另一类指标，仅供了解行业水位。阅读模型、评审模型、题目范围和评审宽严都不统一，互相之间也不能排序。

**LoCoMo**

| 系统 | 数值 | 条件 | 来源 |
|---|---:|---|---|
| Mem0 平台 v3 | 92.5% | 1,540 题；gpt-5 阅读与评审；200 条记忆；宽松评审；无逐题文件 | mem0 README / 研究页，2026-05 |
| Mem0 平台 v3 | 91.56% | 同上，有逐题文件 | memory-benchmarks，2026-04 |
| Mem0（论文） | 66.88%（Mem0）/ 68.44%（Mem0g） | 1,540 题；gpt-4o-mini | arXiv 2504.19413，2025-04 |
| Mem0（第三方重评其 4 月答案） | 91.0% / 81.7% / 85.3% / 35.0% | 同一批答案，分别用 Mem0 自己的评审、LongMemEval 官方评审、人工校准评审、严格评审 | Mnemoverse，2026-09 |
| Mem0 OSS（MemEval） | 评审分 0.497，F1 0.344 | 1,986 题；gpt-4.1-mini 阅读；gpt-5.2 评审，三项二值维度取平均 | ProsusAI MemEval |
| MemU 0.1.x（自报） | 92.09% | 1,542 题；gpt-4.1-mini 阅读，gpt-4.1 评审；每题 25–43 条事件 | memU-experiment，2025-11 公开 |
| MemU 托管 API | 56.55% / 61.15%–66.67% | gpt-4o-mini / gpt-4.1-mini 阅读 | MemOS 论文 / EverMemOS 论文 |
| MemU memu-py 1.3.0（MemEval） | 评审分 0.399，F1 0.299 | 同 MemEval 条件；适配器未传会话时间 | ProsusAI MemEval |
| OpenClaw（MemEval 的移植版） | 评审分 0.725，F1 0.557 | 同 MemEval 条件；2 月代码的 Python 移植，每题 20 段 | ProsusAI MemEval |
| OpenClaw（真实网关，agent 自己检索） | 52 / 100 | 前 100 道非对抗题；gpt-4.1-mini | LanceDB 博客，2026-03 |
| Supermemory | 只写“#1”，无数字 | — | 官网 |

**LongMemEval-S**

| 系统 | 数值 | 条件 | 来源 |
|---|---:|---|---|
| Mem0 平台 v3 | 94.4% | 500 题；gpt-5 阅读与评审；自定义宽松评审；无逐题文件 | mem0 README，2026-05 |
| Mem0 平台 v3 | 93.4% | 同上，有逐题文件 | memory-benchmarks，2026-04 |
| Mem0 平台 v3（第三方） | 56.00% | gpt-4.1-mini 阅读，gpt-4o-mini 评审，20 条 | MemTensor OmniMemEval |
| MemU 托管 API | 38.4% | gpt-4o-mini | MemOS 论文 |
| OpenClaw（MemEval 移植版） | 0.598 | 102 题分层抽样，gpt-4.1 阅读，gpt-4o 评审 | ProsusAI MemEval |
| Supermemory | 81.6% / 84.6% / 85.2% | gpt-4o / gpt-5 / gemini-3-pro 阅读，gpt-4o 评审；81.6% 后被自己撤下 | Supermemory 技术报告，2025-12 |

## 四、MyClip 各版本的位置

| 口径 | 09-20 | 09-21 | 09-24 | 对照 |
|---|---:|---:|---:|---|
| LongMemEval 全部证据会话进前 10（479 题） | 89.8% | 90.8% | 91.7% | Mem0 官方 78.7%–80.4%（按轮、抽取记忆） |
| LongMemEval 证据发言显示在前 10 条片段里 | 64.9% | 65.3% | 62.8% | 同上 |
| LongMemEval 会话 R@5（470 题） | 91.2% | 92.0% | 93.1% | Mem0 90.2%（All-Mem 实测） |
| LongMemEval NDCG@5（470 题） | 88.1% | 88.8% | 90.4% | Mem0 87.1%（All-Mem 实测） |
| LoCoMo 按轮 R@5 | 46.7% | 47.3% | 50.1% | Mem0 38.7%（All-Mem）；Supermemory 纯向量 67.0% |
| LoCoMo 按轮 MRR | 0.394 | 0.399 | 0.446 | Supermemory 纯向量 0.582 |

- 09-20 → 09-21 的提升来自词干归一化；09-21 → 09-24 来自段落级打分。
- 按会话找对文件，MyClip 已处在第三方测得的 Mem0 之上。差距在两处：一是片段只有 300 字，证据原文交付不足；二是没有语义检索，LoCoMo 上字面够不着的多跳证据找不到。

## 五、局限

- 三组可比数字都有口径差异，已在各表下说明：检索单位不同（抽取的事实、原始消息、会话文件），题目范围略有不同（479 / 470 / 1,527 / 1,532 题），第三方对 Mem0 的实测没有公开代码与记忆到证据的对应方式。
- MyClip 的按轮口径是从返回片段推导的，判定规则是“片段显示出证据发言的开头”，与“消息 ID 在前 k 条”接近但不完全相同。
- 只有让各系统在同一协议下跑同一数据，才能得到真正的同场对比。可行的做法：OpenClaw 的内置引擎支持纯关键词模式（`provider: "none"`），不需要外部模型，可以在本机按本协议直接跑；社区已有调用真实 `openclaw memory` 命令的评测工具（openclaw-memory-bench）。Mem0、MemU 的记忆抽取依赖大模型接口，需要网关开通模型后才能跑。

## 来源

- Mem0：[mem0 仓库](https://github.com/mem0ai/mem0) · [memory-benchmarks](https://github.com/mem0ai/memory-benchmarks) · [论文 arXiv 2504.19413](https://arxiv.org/abs/2504.19413) · [向量评估博客（Retrieval@10）](https://mem0.ai/blog/how-mem0-uses-embeddings-and-why-we-are-evaluating-nvidia-nemotron-3-embed)
- MemU：[memU](https://github.com/NevaMind-AI/memU) · [memU-experiment](https://github.com/NevaMind-AI/memU-experiment) · [memu.pro/benchmark](https://memu.pro/benchmark) · [MemOS 论文 arXiv 2507.03724](https://arxiv.org/abs/2507.03724) · [EverMemOS 论文 arXiv 2601.02163](https://arxiv.org/abs/2601.02163)
- OpenClaw：[openclaw 仓库](https://github.com/openclaw/openclaw) · [issue #140932](https://github.com/openclaw/openclaw/issues/140932) · [LanceDB 评测博客](https://www.lancedb.com/blog/openclaw-memory-from-zero-to-lancedb-pro) · [openclaw-memory-bench](https://github.com/phenomenoner/openclaw-memory-bench)
- Supermemory：[研究页](https://supermemory.ai/research) · [LongMemBench 页](https://supermemory.ai/research/longmembench/) · [MemoryBench](https://github.com/supermemoryai/memorybench) · [Hindsight 论文 arXiv 2512.12818](https://arxiv.org/html/2512.12818v1)
- 第三方：[ProsusAI MemEval](https://github.com/ProsusAI/MemEval) · [All-Mem arXiv 2603.19595](https://arxiv.org/abs/2603.19595) · [Mnemoverse 评审研究](https://github.com/mnemoverse/mnemoverse-benchmarks-paper)
