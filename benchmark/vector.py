#!/usr/bin/env python3
"""Offline check of hybrid vector + keyword retrieval before any Swift integration (vector design, phase 0).

The keyword side is MyClip itself: the per-question ranking saved by `retrieval.py` from the current `myclip-mcp`
(its top 20 files). The vector side embeds every passage of the same corpus (paragraphs, as MyClip splits them) with a
multilingual model and scores a file by its best three passages (weights 1, 0.5, 0.25), as the design specifies.
Fusion variants:

- `rerank`: only the 20 files MyClip returned are reordered (a lower bound that needs no retrieval change);
- `hybrid`: every file competes, so the vector side can bring in files outside MyClip's top 20;
- weighted sums `w * vector + (1 - w) * keyword` over normalized scores, and reciprocal rank fusion.

Scores are file-level all@k / recall@k against the official evidence, per category. Run on LoCoMo conversations 00–04 to
choose the fusion, then once on 05–09; LongMemEval checks for regressions.

Requires the venv from the design doc (sentence-transformers). Embeddings are cached by text hash under
benchmark/cache/vectors, so repeated runs and the heavily overlapping LongMemEval haystacks are embedded once.
"""
import argparse
import collections
import hashlib
import json
import pathlib
import statistics

import numpy as np

from . import retrieval as BENCH

PREFIXES = {"intfloat/multilingual-e5-small": ("query: ", "passage: ")}
CUTOFFS = (5, 10, 20)


class Embedder:
    def __init__(self, model_name, cache_dir, device):
        from sentence_transformers import SentenceTransformer
        self.model = SentenceTransformer(model_name, device=device)
        self.query_prefix, self.passage_prefix = PREFIXES[model_name]
        self.cache_path = cache_dir / (model_name.replace("/", "__") + ".npz")
        self.cache = {}
        if self.cache_path.exists():
            data = np.load(self.cache_path)
            self.cache = dict(zip(data["keys"].tolist(), data["vectors"]))
        self.dirty = False

    def encode(self, texts, prefix):
        keys = [hashlib.sha256((prefix + text).encode()).hexdigest()[:24] for text in texts]
        missing = sorted({(k, t) for k, t in zip(keys, texts) if k not in self.cache})
        if missing:
            vectors = self.model.encode([prefix + t for _, t in missing], batch_size=64, normalize_embeddings=True,
                                        convert_to_numpy=True, show_progress_bar=False)
            for (key, _), vector in zip(missing, vectors):
                self.cache[key] = vector.astype(np.float16)
            self.dirty = True
        return np.stack([self.cache[k].astype(np.float32) for k in keys])

    def save(self):
        if self.dirty:
            self.cache_path.parent.mkdir(parents=True, exist_ok=True)
            keys = list(self.cache)
            np.savez(self.cache_path, keys=np.array(keys), vectors=np.stack([self.cache[k] for k in keys]))
            self.dirty = False


def passages(body):
    """Paragraphs separated by blank lines, the way MyClip splits session notes into passages."""
    return [p.strip() for p in body.split("\n\n") if p.strip()]


def normalized(scores):
    """Min–max over the corpus: cosine similarities of one model sit in a narrow band, so dividing by the maximum
    alone would leave every file near 1."""
    values = list(scores.values())
    low, high = min(values), max(values)
    return {k: (v - low) / (high - low) if high > low else 0.0 for k, v in scores.items()}


def metrics(ranked, gold):
    gold = set(gold)
    result = {}
    for k in CUTOFFS:
        found = len(set(ranked[:k]) & gold)
        result[f"all@{k}"] = int(found == len(gold))
        result[f"recall@{k}"] = found / len(gold)
    return result


def evaluate(corpus, lexical_rows, embedder, variants):
    if not any(q["skip_reason"] is None for q in corpus["questions"]):
        return []  # abstention-only LongMemEval items have no evidence to score
    paths = sorted(corpus["documents"])
    chunks, owners = [], []
    for path in paths:
        for text in passages(corpus["documents"][path]["body"]):
            chunks.append(text)
            owners.append(path)
    matrix = embedder.encode(chunks, embedder.passage_prefix)
    owners = np.array(owners)
    rows = []
    questions = [q for q in corpus["questions"] if q["skip_reason"] is None]
    query_vectors = embedder.encode([q["question"] for q in questions], embedder.query_prefix)
    for question, query in zip(questions, query_vectors):
        similarity = matrix @ query
        vector = {}
        for path in paths:
            best = np.sort(similarity[owners == path])[::-1][:3]
            vector[path] = float(sum(value * weight for value, weight in zip(best, (1, 0.5, 0.25))))
        vector = normalized(vector)
        lexical_ranked = [p for p in lexical_rows[question["id"]] if p in corpus["documents"]]
        keyword = {p: (21 - rank) / 20 for rank, p in enumerate(lexical_ranked, 1)}
        vector_ranked = sorted(paths, key=lambda p: (-vector[p], p))
        vector_rank = {p: r for r, p in enumerate(vector_ranked, 1)}
        lexical_rank = {p: r for r, p in enumerate(lexical_ranked, 1)}
        row = {"id": question["id"], "category": question["category"], "gold": question["gold_documents"], "variants": {}}
        for name, (mode, weight) in variants.items():
            pool = lexical_ranked if mode.startswith("rerank") else paths
            if mode.endswith("rrf"):
                score = {p: 1 / (60 + lexical_rank.get(p, 1000)) + 1 / (60 + vector_rank[p]) for p in pool}
            elif mode == "keyword":
                score = {p: keyword.get(p, 0) for p in pool}
            else:
                score = {p: weight * vector[p] + (1 - weight) * keyword.get(p, 0) for p in pool}
            ranked = sorted(pool, key=lambda p: (-score[p], lexical_rank.get(p, 1000), p))
            row["variants"][name] = metrics(ranked, question["gold_documents"])
        rows.append(row)
    return rows


def summarize(rows, variants):
    categories = sorted({r["category"] for r in rows}) + ["ALL"]
    table = {}
    for name in variants:
        table[name] = {}
        for category in categories:
            subset = [r for r in rows if category == "ALL" or r["category"] == category]
            table[name][category] = {m: statistics.mean(r["variants"][name][m] for r in subset) for m in ("all@5", "recall@5", "all@10", "all@20")}
            table[name][category]["n"] = len(subset)
    return table


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dataset", choices=("locomo", "longmemeval"), required=True)
    parser.add_argument("--data", type=pathlib.Path, required=True)
    parser.add_argument("--lexical", type=pathlib.Path, required=True, help="retrieval.py output directory of the current myclip-mcp")
    parser.add_argument("--corpora", help="Half-open index range, e.g. 0:5")
    parser.add_argument("--model", default="intfloat/multilingual-e5-small")
    parser.add_argument("--device", default="mps")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    lexical_rows = {}
    for line in (args.lexical / "queries.jsonl").read_text(encoding="utf-8").splitlines():
        row = json.loads(line)
        lexical_rows[row["id"]] = [hit["path"] for hit in row["hits"]]
    samples = json.loads(args.data.read_text(encoding="utf-8"))
    first, last = (int(part) for part in args.corpora.split(":")) if args.corpora else (0, len(samples))
    adapter = BENCH.locomo_corpus if args.dataset == "locomo" else BENCH.longmemeval_corpus
    variants = {"keyword (MyClip)": ("keyword", 0)}
    for weight in (0.3, 0.5, 0.7, 0.9):
        variants[f"rerank w={weight}"] = ("rerank", weight)
        variants[f"hybrid w={weight}"] = ("hybrid", weight)
    variants["hybrid vector only"] = ("hybrid", 1.0)
    variants["rerank rrf"] = ("rerank-rrf", 0)
    variants["hybrid rrf"] = ("hybrid-rrf", 0)
    embedder = Embedder(args.model, pathlib.Path(__file__).resolve().parent / "cache" / "vectors", args.device)
    rows = []
    for index in range(first, min(last, len(samples))):
        corpus = adapter(samples[index], index)
        rows += evaluate(corpus, lexical_rows, embedder, variants)
        if (index - first) % 25 == 24:
            embedder.save()
            print(f"{index + 1 - first} corpora", flush=True)
    embedder.save()
    args.output.mkdir(parents=True, exist_ok=True)
    table = summarize(rows, variants)
    (args.output / "rows.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    (args.output / "summary.json").write_text(json.dumps({"model": args.model, "dataset": args.dataset, "corpora": args.corpora,
                                                          "lexical_run": str(args.lexical), "table": table}, indent=1) + "\n")
    categories = list(next(iter(table.values())))
    print(f"{'variant':22}" + "".join(f"{c[:12]:>14}" for c in categories))
    for name, cells in table.items():
        print(f"{name:22}" + "".join(f"{cells[c]['all@5'] * 100:14.1f}" for c in categories))


if __name__ == "__main__":
    main()
