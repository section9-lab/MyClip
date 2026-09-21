# Memory 召回评测复跑（2026-09-21）

评测日期：2026-09-21。对象：本日检索层改造后的 `myclip-mcp`（release 构建），见 [改造说明](memory-retrieval-design-2026-09-21.md)。数据、指标定义与流程与 [评测协议](memory-benchmark-protocol.md) 完全一致，基线是 [2026-09-20 报告](memory-benchmark-2026-09-20.md)。

## 口径

每题仍是问题原文单次调用 `search_memories`，`limit=20`，显式 `expand: false`。语料是原始会话 Markdown，没有 Wikilink，也没有实体页。因此这次数字反映的只是 **FTS5 改用 porter 词干、检索结果结构调整** 后的单次召回，**不包含**链接扩展、多查询融合和锚文本三项改动的收益，那三项需要带链接的语料才能测。

两个数据集均全部题目执行，无失败语料。计分题数与基线相同：LoCoMo 1,532 题，LongMemEval-S cleaned 470 题。

## 总体

| 数据集 | 指标 | 09-20 | 09-21 | 变化（百分点） |
|---|---|---:|---:|---:|
| LoCoMo | all@5 | 77.5% | 78.9% | +1.4 |
| LoCoMo | recall@5 | 83.0% | 83.9% | +0.9 |
| LoCoMo | full_turn_recall@5 | 55.2% | 56.2% | +0.9 |
| LoCoMo | all@20 | 94.4% | 95.7% | +1.3 |
| LoCoMo | MRR@20 | 0.750 | 0.758 | +0.008 |
| LongMemEval-S | all@5 | 83.4% | 84.5% | +1.1 |
| LongMemEval-S | recall@5 | 91.2% | 92.0% | +0.8 |
| LongMemEval-S | full_turn_recall@5 | 64.7% | 65.0% | +0.3 |
| LongMemEval-S | all@20 | 95.5% | 97.2% | +1.7 |
| LongMemEval-S | MRR@20 | 0.911 | 0.913 | +0.002 |

## 分类

| 数据集 | 类型 | 题数 | all@5 旧 | all@5 新 | 逐题翻转（改善 / 退步） |
|---|---|---:|---:|---:|---|
| LoCoMo | 多跳 | 279 | 26.9% | 34.1% | +32 / −12 |
| LoCoMo | 时间 | 321 | 84.4% | 87.2% | +16 / −7 |
| LoCoMo | 单跳 | 840 | 95.0% | 94.3% | +14 / −20 |
| LoCoMo | 开放域 | 92 | 47.8% | 45.7% | +3 / −5 |
| LongMemEval-S | 知识更新 | 72 | 95.8% | 98.6% | +2 / −0 |
| LongMemEval-S | 跨会话 | 121 | 66.1% | 69.4% | +9 / −5 |
| LongMemEval-S | 时间推理 | 127 | 77.2% | 77.2% | +3 / −3 |
| LongMemEval-S | 单会话偏好 | 30 | 83.3% | 83.3% | +2 / −2 |
| LongMemEval-S | 单会话用户事实 | 64 | 100.0% | 98.4% | +0 / −1 |
| LongMemEval-S | 单会话助手内容 | 56 | 100.0% | 100.0% | 0 / 0 |

## 怎么读这些数字

- **多跳与跨会话的提升是词干带来的。** 需要多篇证据的问题往往用不同词形描述同一件事，porter 词干让 `Researching` 与 `research`、`moved` 与 `move` 归为一词，找齐多篇文件的比例随之上升。这是词形归一化对多跳题的贡献，不是图扩展的贡献。
- **单跳与开放域的小幅退步是排序边界抖动。** 抽样退步题里，标准文件多数从第 5 位滑到第 6 到 8 位，例如 locomo-01-0044 的 session-0001 从第 5 位掉出前五。词干让更多文件命中同一词根，BM25 分布更平，边界处会有交换。这类退步在 LoCoMo 单跳里是 20 题对 14 题的净损失，需要用开发集调整 BM25 列权重或对词干匹配降权后再验证。
- **两处 100% 的分类不变。** 单会话助手内容仍是文件全中、发言覆盖率低，属于段落交付问题，本轮未处理。
- **延迟无明显变化。** LoCoMo p50 242 ms、p95 342 ms，LongMemEval-S p50 1,015 ms、p95 2,903 ms，与基线同量级，同样是本机并发条件下的参考值。

## 还没有测到的部分

链接一跳扩展、多查询融合、锚文本别名、归档排除和写入 lint 都不在这个协议的路径上。要度量它们，需要在 LoCoMo 语料上合成实体页与回链，或用真实 Memory 目录建中文开发集，再对照 `expand` 与 `queries` 开关。这一步列在改造说明的"后续"里。

## 产物

- [LoCoMo 汇总](../build/memory-benchmark/locomo-2026-09-21/summary.json) · [逐题](../build/memory-benchmark/locomo-2026-09-21/queries.jsonl)
- [LongMemEval 汇总](../build/memory-benchmark/longmemeval-2026-09-21/summary.json) · [逐题](../build/memory-benchmark/longmemeval-2026-09-21/queries.jsonl)
- 被测二进制：`.build/release/myclip-mcp`，SHA-256 记录在两个 `metadata.json` 中。
