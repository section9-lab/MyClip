#!/usr/bin/env python3
"""Compares benchmark runs question by question.

Each argument is `label=run_directory` (a `retrieval.py` output). The first run is the reference: every other run
reports per-category means and how many questions it gained or lost against it. Runs must cover the same questions.

- Scored questions (evidence-bearing, non-abstention): all@5, recall@5, MRR@20, complete-turn recall@5 and returned
  snippet characters.
- `--evidence` scores organized-corpus runs by strict evidence delivery (`retrieval.evidence_metrics`).
- `--longmemeval500` adds the 500-question session-level Recall@5 / Hit@5 that includes the 30 abstention questions,
  counting only whether their annotated sessions were found (the definition Sibyl publishes).
- `--corpora` limits LoCoMo to conversations, e.g. `locomo-05,locomo-06`.
"""
import argparse
import collections
import json
import pathlib
import statistics

from . import retrieval as BENCH


def load(directory, corpora):
    rows = {}
    for line in (pathlib.Path(directory) / "queries.jsonl").read_text(encoding="utf-8").splitlines():
        row = json.loads(line)
        if corpora is None or row["corpus"] in corpora:
            rows[row["id"]] = row
    return rows


def scored(row, evidence):
    metrics = dict(row["metrics"])
    if evidence:
        strict = BENCH.evidence_metrics(row["hits"], row["gold_documents"], row["gold_turns"])
        metrics["all@5"], metrics["recall@5"] = strict["evidence_all@5"], strict["evidence_recall@5"]
    return metrics


def session_recall(row, k=5):
    gold = set(row["gold_documents"])
    found = len(gold & {hit["path"] for hit in row["hits"][:k]})
    return found / len(gold), int(found > 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("runs", nargs="+", help="label=run_directory; the first is the reference")
    parser.add_argument("--evidence", action="store_true")
    parser.add_argument("--longmemeval500", action="store_true")
    parser.add_argument("--corpora")
    args = parser.parse_args()
    corpora = set(args.corpora.split(",")) if args.corpora else None
    runs = [(label, load(path, corpora)) for label, path in (item.split("=", 1) for item in args.runs)]
    reference = runs[0][1]
    ids = [i for i, row in reference.items() if row["metrics"]]
    categories = sorted({reference[i]["category"] for i in ids}) + ["ALL"]
    columns = ("all@5", "recall@5", "mrr")
    print("| 题型 | 题数 | 版本 | all@5 | recall@5 | MRR | 发言覆盖@5 | 返回字数 | 逐题翻转（all@5） |")
    print("|---|---:|---|---:|---:|---:|---:|---:|---|")
    for category in categories:
        subset = [i for i in ids if category == "ALL" or reference[i]["category"] == category]
        base = {i: scored(reference[i], args.evidence) for i in subset}
        for label, rows in runs:
            metrics = {i: scored(rows[i], args.evidence) for i in subset}
            values = [statistics.mean(metrics[i][c] for i in subset) for c in columns]
            turns = statistics.mean(metrics[i].get("full_turn_recall@5", 0) for i in subset)
            characters = statistics.mean(rows[i]["returned_passage_characters"] for i in subset)
            up = sum(metrics[i]["all@5"] > base[i]["all@5"] for i in subset)
            down = sum(metrics[i]["all@5"] < base[i]["all@5"] for i in subset)
            flips = "—" if rows is reference else f"+{up} / −{down}"
            print(f"| {category} | {len(subset)} | {label} | {values[0] * 100:.1f}% | {values[1] * 100:.1f}% | {values[2]:.3f} | "
                  f"{turns * 100:.1f}% | {characters:,.0f} | {flips} |")
    if args.longmemeval500:
        print("\n| 题型（含拒答） | 题数 | " + " | ".join(f"{label} Recall@5 | {label} Hit@5" for label, _ in runs) + " |")
        print("|---|---:|" + "---:|---:|" * len(runs))
        all_ids = list(reference)
        groups = collections.defaultdict(list)
        for i in all_ids:
            groups[reference[i]["category"]].append(i)
        groups["ALL"] = all_ids
        for category in sorted(groups, key=lambda c: (c == "ALL", c)):
            cells = []
            for _, rows in runs:
                pairs = [session_recall(rows[i]) for i in groups[category]]
                cells.append(f"{statistics.mean(p[0] for p in pairs) * 100:.2f}% | {statistics.mean(p[1] for p in pairs) * 100:.2f}%")
            print(f"| {category} | {len(groups[category])} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
