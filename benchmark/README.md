# MyClip Memory 评测

评测 `myclip-mcp` 的记忆检索（以及可选的问答层）在公开数据集 LoCoMo 与 LongMemEval 上的表现。口径与计分见 [评测协议](docs/memory-benchmark-protocol.md)。

## 目录

| 路径 | 内容 | 进 Git |
|---|---|---|
| `retrieval.py`、`qa.py` | 检索评测与问答评测入口 | 是 |
| `organize.py`、`compare.py`、`vector.py` | 整理语料、逐题对比、离线向量实验入口 | 是 |
| `model.py` | 问答与整理共用的模型客户端 | 是 |
| `tests/` | 评测器的单元测试与真实 MCP 集成测试 | 是 |
| `prompts/` | 整理模板 `organize.md`、问答与评审模板 `qa.py`、标签实验 `tag.txt` | 是 |
| `docs/` | 评测协议与各日期的报告 | 是 |
| `memory-benchmark.env` | 问答评测用的模型接口地址与 API 密钥 | **否** |
| `data/` | 下载的数据集与官方评测代码（按各自许可仅在本机使用） | 否 |
| `corpora/locomo/` | 由 LoCoMo 派生的整理语料：`input/`（导出的会话）、`facts/`（事实日志）、`organized/`（拼装后的语料），以及打标签实验的 `facts-tagged/`、`organized-tagged/` | 否 |
| `runs/<日期>/<运行名>/` | 每次运行的 `metadata.json`、`queries.jsonl`（逐题结果）、`summary.json` | 否 |
| `bin/` | 各次运行所测的 `myclip-mcp` 二进制，SHA-256 记录在对应运行的 `metadata.json` | 否 |
| `cache/` | Python 环境（`venv/`）、模型（`hf/`）与向量（`vectors/`）缓存 | 否 |

不进 Git 的内容由 [`.gitignore`](.gitignore) 排除，新增文件时用 `git check-ignore <路径>` 确认。

## 报告

| 日期 | 报告 |
|---|---|
| 2026-09-20 | [首次检索评测](docs/memory-benchmark-2026-09-20.md) · [同类方案对照](docs/memory-peer-comparison-2026-09-20.md) |
| 2026-09-21 | [检索层改造后复跑](docs/memory-benchmark-2026-09-21.md) · [同类方案对照](docs/memory-peer-comparison-2026-09-21.md) |
| 2026-09-23 / 24 | [召回改造评测](docs/memory-recall-benchmark-2026-09-23.md)（含向量、伪相关反馈、检索标签三项实验） |
| 2026-09-24 | [按日期版本对比与同类方案对照](docs/memory-version-comparison-2026-09-24.md) · [与 Mem0、MemU、OpenClaw、Supermemory 的评测对比](docs/memory-peer-benchmarks-2026-09-24.md) · [片段显示规则与来源补全](docs/memory-snippet-links-2026-09-24.md) |

## 运行

所有命令在仓库根目录执行，使用 `python3 -m benchmark.<模块>`。核心评测只依赖 Python 标准库；官方 LoCoMo 词干计分需要 `nltk`，是否启用会记录在 metadata 中；向量实验另外需要现有缓存环境中的 `numpy` 和 `sentence-transformers`。

应用提示词位于 `MyClip/Core/Prompt/`，与此处的评测模板分开维护。数据、历史运行、缓存和密钥位置不变。

```bash
swift build -c release --product myclip-mcp
```

```bash
bash Scripts/test.sh benchmark
```

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m benchmark.retrieval --dataset locomo --data benchmark/data/locomo10.json --output benchmark/runs/$(date +%F)/locomo
```

整理后的语料（轨道 B）加 `--organized benchmark/corpora/locomo/organized`；只跑部分对话用 `--corpora 0:5`（开发集）或 `--corpora 5:10`（测试集）。

`qa.py` 的 metadata 同时记录检索器、提示词和模型客户端的校验值，便于追溯一次评测所用的完整代码。

问答层评测读取 `benchmark/memory-benchmark.env` 中的 `OPENAI_BASE_URL` 与 `OPENAI_API_KEY`：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m benchmark.qa --dataset longmemeval --data benchmark/data/longmemeval_s_cleaned.json --output benchmark/runs/$(date +%F)/qa-longmemeval
```

版本之间逐题对比：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m benchmark.compare 旧=benchmark/runs/2026-09-21/locomo-2026-09-21 新=benchmark/runs/2026-09-23/r300-a-locomo
```

数据集的下载地址与校验值见协议中的“固定数据版本”。

整理语料的三个阶段：

```bash
python3 -m benchmark.organize export --data benchmark/data/locomo10.json --output benchmark/corpora/locomo/input
python3 -m benchmark.organize assemble --data benchmark/data/locomo10.json --facts benchmark/corpora/locomo/facts --output benchmark/corpora/locomo/organized
python3 -m benchmark.organize --help
```

`export` 和 `assemble` 可离线运行；`extract` 会使用配置的模型服务。历史命令中的 `benchmark/scripts/benchmark_memory.py`、`benchmark_memory_qa.py`、`organize_benchmark_corpus.py`、`compare_runs.py`、`vector_offline_eval.py` 依次对应模块 `benchmark.retrieval`、`benchmark.qa`、`benchmark.organize`、`benchmark.compare`、`benchmark.vector`。
