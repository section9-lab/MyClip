# MyClip 与其他记忆项目的召回成绩对照

核验日期：2026-09-20。此表比较 LongMemEval-S cleaned 的会话定位能力，不是最终回答正确率或完整记忆产品排名。

## 本轮实际完成的工作

1. 核对其他项目的公开结果与计分代码，区分 Hit@5、Recall@5、All@5。
2. 使用已经保存的 MyClip 500 道问题的实际检索输出，按公开报告的 500 题口径重新计分；没有重新检索、修改查询、调整实现或调用模型。
3. 验证 500 个 question_id 唯一、标准证据会话均非空；独立集合运算与现有评分函数一致。原先 470 道可回答题的全部文件级指标逐题复核一致，原报告保持不变。

为对齐同行报告，本附表包含 30 道拒答题，但只检查它们标注的相关会话是否被找到，不评价是否正确拒答。正式召回基线仍按原协议排除这 30 题，计分 470 题。

## 指标定义

- **Hit@5**：前五个结果至少包含一个标准证据会话的题目比例。
- **Recall@5**：每题找回的标准证据会话数除以该题全部标准证据会话数，再对题目取平均。
- **All@5**：前五个结果找齐全部标准证据会话的题目比例。

例如一题需要两个会话，前五只找回一个：Hit=100%，Recall=50%，All=0%。三种数字不能混用。

## 对照结果

| 系统 / 配置 | Hit@5 | Recall@5 | 成绩来源 |
|---|---:|---:|---|
| Sibyl，公开 live API 配置 | 100.00% | 96.96% | 项目方公布 |
| AutoMem，公开 full canonical 配置 | 97.00% | 未核实到该指标 | 项目方公布 |
| MyClip，本轮被测 MCP | 96.80% | 90.71% | 本机实际输出重新计分 |
| MemPalace，raw ChromaDB 基线 | 96.60% | 未核实到该指标 | 项目方公布 |

MyClip 在此 500 题口径下的 All@5 为 82.40%。原报告的 83.40% 是 470 题口径的 All@5；数值变化来自纳入题目范围不同，不是实现变化。原报告 91.20% 则是 470 题的 Recall@5。

以上是同一类数据集、同一会话粒度和同一计分含义的公开对照；其他项目没有在本机重跑。不同系统的输入序列化、候选池、模型、检索调用和计算预算未统一。因此数值差距可以定位需要验证的方向，不能当作严格控制条件下的胜负结论。

来源与核验：

- [Sibyl 报告](https://github.com/hyperb1iss/sibyl/blob/c59f48c4fb73c0a7c177e236f4f340d94a5fde63/docs/testing/longmemeval.md)：500 题，用户和助手发言均索引，OpenAI text-embedding-3-small，图与向量混合检索，无 LLM 提取或 LLM 重排。报告指向运行 commit `36032a25b2893f2fbcbc074bd0c212fb829dd975`。其[运行代码](https://github.com/hyperb1iss/sibyl/blob/36032a25b2893f2fbcbc074bd0c212fb829dd975/benchmarks/longmemeval_live.py)硬编码的数据 SHA-256 与本轮完全一致：`d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442`。[评分函数](https://github.com/hyperb1iss/sibyl/blob/36032a25b2893f2fbcbc074bd0c212fb829dd975/packages/python/sibyl-core/src/sibyl_core/evals/longmemeval.py)与本表 Hit、Recall 定义一致。公开 CI 运行 `26304777971` 的原始 artifact 已过期，本轮没有独立重算它的逐题输出。
- [AutoMem 报告](https://github.com/verygoodplugins/automem/blob/3caa9d5d396ba4cb303df1fb39da7602126f60c9/docs/TESTING.md)：500 题，公布的 recall@5 为 485/500。[计分代码](https://github.com/verygoodplugins/automem/blob/3caa9d5d396ba4cb303df1fb39da7602126f60c9/tests/benchmarks/longmemeval/test_longmemeval.py)使用前五个不同会话是否命中任意 answer_session_id，因此本表将其正确标为 Hit@5。其同表 87% 是另一项最终问答正确率，没有混入本表。
- [MemPalace 报告](https://github.com/MemPalace/mempalace/blob/36ec72f95e2e9f2bd6112891752edff457229f93/benchmarks/README.md)：raw 模式 500 题，公布的 Recall@5 为 0.966。[计分代码](https://github.com/MemPalace/mempalace/blob/36ec72f95e2e9f2bd6112891752edff457229f93/benchmarks/longmemeval_bench.py)实际打印的是 recall_any，即本表的 Hit@5。这个配置是直接 ChromaDB 向量检索基线，不能代表其完整 Palace 架构或优化版本；raw 入口仅索引用户发言，与 MyClip 的输入处理也有差异。

## 同一 Recall@5 指标的能力分项

Sibyl 公开了 500 题的各类别 Recall@5，因此可以与 MyClip 的同范围重计结果并列。此处是证据覆盖，不是推理或个性化回答正确率。

| LongMemEval 类别 | 题数 | MyClip Recall@5 | Sibyl 公布 Recall@5 | MyClip 与公开分差，百分点 |
|---|---:|---:|---:|---:|
| 用户事实 | 70 | 98.57% | 100.00% | -1.43 |
| 助手内容 | 56 | 100.00% | 100.00% | 0.00 |
| 偏好相关 | 30 | 83.33% | 100.00% | -16.67 |
| 跨会话 | 133 | 83.32% | 95.33% | -12.01 |
| 知识更新 | 78 | 98.08% | 98.72% | -0.64 |
| 时间相关 | 133 | 87.39% | 94.01% | -6.62 |
| 整体 | 500 | 90.71% | 96.96% | -6.25 |

## 对 MyClip 的判断

在“至少找到一个相关会话”这个较宽松的指标上，MyClip 与所列 AutoMem 配置及 MemPalace raw 基线接近。在覆盖多条标准证据的 Recall@5 上，MyClip 低于 Sibyl 公开结果，差距集中在偏好相关、跨会话和时间相关题。这支持优先验证查询表达处理、多次定向检索和证据汇集；不能据此单独证明引入图数据库、特定向量模型或替换后端必然有效。

本轮尚未核实 Hindsight、Graphiti、Mem0、Letta 在相同会话召回口径下的成绩，不能拿它们的最终问答分代填。也未找到可与 MyClip 完整证据发言覆盖率直接对照的公开结果；该指标仍是本地诊断项。

## 可复核产物

- [MyClip 500 题重计汇总](../build/memory-benchmark/peer-comparison-2026-09-20/myclip-500-summary.json)
- [MyClip 500 题重计明细](../build/memory-benchmark/peer-comparison-2026-09-20/myclip-500-per-question.jsonl)
- [公开来源固定版本、文件与校验值](../build/memory-benchmark/peer-comparison-2026-09-20/sources.json)
- [原始 470 题评分报告](memory-benchmark-2026-09-20.md)
