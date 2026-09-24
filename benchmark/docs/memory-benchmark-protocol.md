# MyClip 记忆召回评测

这套脚本用公开 LoCoMo / LongMemEval 数据调用真实的 `myclip-mcp`，测量当前检索层的证据覆盖率。它不是官方端到端问答成绩，也不能直接用于给 MyClip、Hindsight、Mem0、Zep 排名。

## 评测边界

测试路径为：原始对话 → 按会话写入 Markdown → MyClip 文件同步与 SQLite 索引 → `memory_search` → 对照官方证据标签计分。2026-09-23 起工具由 `search_memories` 改为 `memory_search`（见[召回改造方案](../../docs/memory-recall-redesign-2026-09-23.md)），此前报告中的数字按旧工具测得。

- 每个 LoCoMo 对话、每道 LongMemEval 题使用独立的临时记忆库，结束后删除。
- 每个会话对应一份 Markdown，保留原始发言、说话人、会话时间。LoCoMo 保留数据集自带的图片说明，不下载图片。
- 标准答案、问题、`has_answer`、证据 ID、人工事件摘要和预生成总结不进入记忆。只有计分阶段使用证据标签。
- Markdown 的文件更新时间统一固定为 `2000-01-01T00:00:00Z`，避免导入顺序产生虚假的新旧信息。会话时间在正文保留，不伪造成事件时间或截图时间。
- 问题原文直接作为 `query`；每题只调用一次搜索，`limit=20`。记录前 1、5、10、20 个结果。
- 不调用 Agent 改写查询、不追加 `memory_get`。原始会话语料没有 Wiki Link，`memory_search` 内置的链接图传播在这条路径上不起作用，因此结果与关闭扩展的旧口径可比。这是单次检索基线；MCP 声明接受关键词，所以不能把直接输入自然语言问题的成绩等同于完整 Agent 的成绩。
- 导入完成后检查所有正文完整保留；超出产品文件大小限制会报错，不截断输入。
- 不使用私人记忆、截图、模型 API 或外部记忆服务。临时库通过 `--library` 显式指定。

此次不覆盖截图/OCR、Agent 提取与维护 Markdown、事件标注、中文检索、Wiki Link 扩展、最终答案与拒答。英语对话结果不能代替 MyClip 自身使用场景的评测。

## 指标

| 字段 | 定义 |
|---|---|
| `recall@k` | 前 k 个文件覆盖的标准证据文件数 / 标准证据文件总数；逐题计算后平均 |
| `hit@k` | 至少命中一个标准证据文件的问题比例 |
| `all@k` | 标准证据文件全部进入前 k 的问题比例；比“命中过一个”严格 |
| `mrr` | 第一个证据文件排名的倒数；前 20 未命中则为 0，即 MRR@20 |
| `full_turn_recall@k` | 返回片段完整包含的标准证据发言数 / 该题标准证据发言数；逐题平均 |
| `full_turn_all@k` | 返回片段完整覆盖全部标准证据发言的问题比例 |
| `random_document_recall@k` | 在全部会话文件及三个根文件中随机取 k 个的期望文件召回率，用于解释文件数较少时的高分；不是运行过的竞争产品 |
| `latency_ms` | 导入结束后一次真实 MCP 搜索的墙钟耗时，包括同步文件、检索、序列化和本地 IPC |
| `returned_passage_characters` | 前 20 个结果中 `snippet` 文本（旧工具为 `matches`）的 Python Unicode 字符数；不是 token 数，也不含 JSON/summary 元信息开销 |

片段指标要求：将同一文件返回的段落（`snippet` 按省略行拆开）按返回顺序连接，证据原文需完整出现，只归一化 Unicode NFC 和空白；一条发言跨多个返回段落也可以计分。它是严格的诊断指标，**不是答案正确率**：长发言里可能只有一句含答案，即使完整发言没被覆盖，模型也可能得到足够信息；反过来，命中文件也不表示答案已经返回给模型。`memory_get` 后续阅读可能补全证据。`memory_search` 的片段每段最多 300 字（旧工具最多 1,600 字），长发言因此更难完整覆盖。

LoCoMo 的 adversarial 和 LongMemEval 的 abstention 问题照常执行搜索，但不参与正证据召回计分。空证据、无法解析或指向不存在发言的证据单独列为排除项；不缩小标准证据集合后给它们评分。LoCoMo 证据列表允许分号/空格分隔和编号前导零，不猜测错误编号。所有排除原因逐题保存。

## 固定数据版本

| 数据 | 版本 | SHA-256 |
|---|---|---|
| LoCoMo `data/locomo10.json` | `snap-research/locomo` commit `3eb6f2c585f5e1699204e3c3bdf7adc5c28cb376` | `79fa87e90f04081343b8c8debecb80a9a6842b76a7aa537dc9fdf651ea698ff4` |
| LongMemEval-S cleaned | Hugging Face revision `98d7416c24c778c2fee6e6f3006e7a073259d48f` | `d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442` |

数据放在 `benchmark/data/`，运行结果放在 `benchmark/runs/<日期>/<运行名>/`，两者都被 `benchmark/.gitignore` 排除，不把数据集复制到产品或仓库中。使用和再分发遵循各数据集的原始许可：[LoCoMo 许可](https://github.com/snap-research/locomo/blob/3eb6f2c585f5e1699204e3c3bdf7adc5c28cb376/LICENSE.txt)、[LongMemEval 数据卡](https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/blob/98d7416c24c778c2fee6e6f3006e7a073259d48f/README.md)。

```bash
mkdir -p benchmark/data
curl -fL 'https://raw.githubusercontent.com/snap-research/locomo/3eb6f2c585f5e1699204e3c3bdf7adc5c28cb376/data/locomo10.json' \
  -o benchmark/data/locomo10.json
curl -fL 'https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/98d7416c24c778c2fee6e6f3006e7a073259d48f/longmemeval_s_cleaned.json' \
  -o benchmark/data/longmemeval_s_cleaned.json
shasum -a 256 benchmark/data/locomo10.json benchmark/data/longmemeval_s_cleaned.json
swift build -c release --product myclip-mcp
bash Scripts/test.sh benchmark
PYTHONDONTWRITEBYTECODE=1 python3 -m benchmark.retrieval \
  --dataset locomo --data benchmark/data/locomo10.json \
  --output benchmark/runs/$(date +%F)/locomo-run
PYTHONDONTWRITEBYTECODE=1 python3 -m benchmark.retrieval \
  --dataset longmemeval --data benchmark/data/longmemeval_s_cleaned.json \
  --output benchmark/runs/$(date +%F)/longmemeval-run
```

输出目录必须尚不存在，避免混入旧结果。可用 `--max-corpora 1` 做连通性检查，但不能把它称作完整评测。脚本只使用 Python 标准库；真实检索器需要 macOS 和项目要求的 Swift 工具链。

每次生成：

- `metadata.json`：数据、二进制和评测脚本的 SHA-256，系统版本及参数。
- `queries.jsonl`：每题的原始搜索结果、证据、计分、排除原因、耗时，便于复核失败案例。
- `summary.json`：总体、分类汇总、导入耗时及失败列表。失败不会变成通过，存在失败时脚本返回非零状态。

## 与业界结果对齐

公开基准的最终问答成绩同时受到记忆生成模型、检索策略、答案模型、评审模型、上下文预算和是否包含拒答题影响。要做可比较的结果，需固定这些条件，给同样的原始历史，盲测全部问题，并保留逐题答案和评审记录。

建议下一层使用 LongMemEval 官方回答评估格式（`question_id`、`hypothesis`）与固定评审模型；对 MyClip、同预算的文件检索基线以及一个候选后端进行同场对照。通过答案模型读到的上下文才算交付证据，不能直接把正确文件的全部内容算作已返回。对记忆生成还需要测事实准确率、重要事实覆盖率、来源正确率、时间和状态更新错误率。

本地回归测试通过数量不是行业 Benchmark 分数。检索召回率也不能与厂商公布的最终问答正确率混排。

## 问答层评测（2026-09-21 新增）

`benchmark/qa.py` 在同一检索路径之上加答案模型与评审模型，产出可与公开榜单口径对齐的最终问答成绩。检索、导入与语料序列化与上文完全一致。

- 检索：问题原文调用一次 `memory_search`，`limit=10`；按排名拼接返回段落，总预算 12,000 字符，Memory.md、Now.md、Profile.md 三个模板文件不进入上下文。
- 阅读模型默认 `gpt-4.1-mini`（对齐 ProsusAI MemEval），评审模型默认 `gpt-4o`（对齐 LongMemEval 官方）。两者通过 `benchmark/memory-benchmark.env` 中的 OpenAI 兼容接口调用；密钥只保存在本机。
- LoCoMo：阅读提示词取自官方 `task_eval/gpt_utils.py`（短语作答、时间题附加日期提示、对抗题允许回答 "No information available"）；主指标是官方 `task_eval/evaluation.py` 的 token F1（Porter 词干，类别 1 拆分子答案、类别 3 取首答案、类别 5 关键词判定）。另报 1 到 4 类的 LLM 评审准确率，评审提示词为本项目自拟，仅用于与厂商自报的准确率并列。
- LongMemEval：阅读提示词取自官方 `src/generation/run_generation.py` 的非 CoT 模板并传入 `question_date`；评审提示词逐字取自官方 `src/evaluation/evaluate_qa.py`，按题型选择模板，拒答题用拒答模板。报告 500 题总准确率、470 题可答准确率、30 题拒答准确率与分类型准确率。
- 结果目录含 `metadata.json`（数据、二进制、两份脚本的 SHA-256、模型名、上下文预算）、`queries.jsonl`（逐题回答、评审原文、上下文文件与字符数）、`summary.json`（汇总与 token 用量）。支持 `--resume` 续跑与 `--dry-run` 无模型自检。

```bash
bash Scripts/test.sh benchmark
PYTHONDONTWRITEBYTECODE=1 python3 -m benchmark.qa \
  --dataset longmemeval --data benchmark/data/longmemeval_s_cleaned.json \
  --output benchmark/runs/$(date +%F)/qa-longmemeval-run
PYTHONDONTWRITEBYTECODE=1 python3 -m benchmark.qa \
  --dataset locomo --data benchmark/data/locomo10.json \
  --output benchmark/runs/$(date +%F)/qa-locomo-run
```

问答成绩同时受阅读模型影响，报告时必须注明阅读与评审模型；不同模型下的成绩不能混排。

## 轨道 B：整理后的语料（2026-09-23 新增）

原始会话没有实体页和 Wiki Link，测不到链接图召回。轨道 B 先把 LoCoMo 按会话顺序“整理”成 MyClip 的记忆形态，再用同一套检索与计分。

- 生成：`benchmark/organize.py`。会话原文保留为按会话日期命名的 Daily 页（`Daily/2023-05-08-session-0001.md`），证据标签随之改写到新路径。整理者逐会话读取原文和“已有页面”列表（路径、标题、别名、小节），按固定提示词输出事实行；脚本把每条事实追加到 `Wiki/People` 或 `Wiki/Topics` 的对应小节，行末链接到来源会话：`- Took his turtles out for a walk [[Daily/2023-10-09-session-0025|2023-10-09]]`。问题、答案和证据标签不进入整理者的输入。
- 整理者：`extract` 子命令调用 OpenAI 兼容接口；`export` + `assemble` 允许其他整理者（例如 Agent）按导出的会话和同一提示词写出事实日志，再由同一段代码拼装页面。metadata 记录整理者、提示词和脚本的 SHA-256。生成一次后固定，所有检索配置复用同一份语料。
- 计分：除文件级指标外，增加 `evidence_recall@k` / `evidence_all@k`：前 k 个结果“送达”的证据文件 = 结果本身的路径 ∪ 片段中复述该证据的链接行所指的会话。链接行须与该会话的标准证据发言共享至少两个实词（去停用词），才计为送达；只要有链接就计分的宽口径会把同一会话里无关的事实行也算进来，在 LoCoMo 多跳上约 40% 的链接计分属于这种情况（2026-09-23 复核）。2026-09-24 起片段把链接显示为标签，链接目标改由每条结果的 `links` 列出，无法再对应到具体行，计分改为：`links` 中的会话只要被该结果任一片段行复述即计为送达（旧版本的片段从原始 Wikilink 读出目标，按同一规则计分，版本之间可直接比较）。同一份 r300 轨道 B 数据上，新规则比“必须是持有链接的那一行”高 0.4（测试集）到 0.7（开发集）个百分点，只有加分翻转；此前报告中的轨道 B 数字按旧规则计算。
- 运行：`benchmark_memory.py --organized DIR`，其余参数与轨道 A 相同。
- 口径限制：事实行由整理者写成，整理质量直接影响分数；比较检索配置时必须用同一份语料。轨道 B 与轨道 A 的数字不可直接相减归因于检索。
