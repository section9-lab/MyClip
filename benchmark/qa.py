#!/usr/bin/env python3
"""End-to-end QA benchmark: MyClip retrieval, then a reader model answers, then a judge scores.

Retrieval reuses retrieval.py (raw session Markdown, real MCP). Prompts and scoring follow the
official LoCoMo (token F1 with Porter stemming, category rules) and LongMemEval (per-type judge templates)
code that is vendored under benchmark/data. The LoCoMo LLM-judge accuracy is an additional,
non-official metric reported separately for comparison with vendor self-reports.
"""

import argparse
import collections
import concurrent.futures
import json
import pathlib
import platform
import re
import statistics
import string
import tempfile
import threading
import time

from . import retrieval as BENCH
from . import model
from .model import ChatModel, load_env
from .prompts import qa as qa_prompts
from .prompts.qa import CATEGORY_NUMBERS, reader_prompt, judge_prompt


try:
    from nltk.stem.porter import PorterStemmer
    STEMMER = PorterStemmer()
    STEMMING = "nltk-porter"
except ImportError:  # pragma: no cover - environment dependent
    class _Identity:
        def stem(self, word):
            return word
    STEMMER = _Identity()
    STEMMING = "none"


def normalize_answer(text):
    """LoCoMo task_eval/evaluation.py normalize_answer, using re instead of regex."""
    text = text.replace(",", "")
    text = text.lower()
    text = "".join(ch for ch in text if ch not in set(string.punctuation))
    text = re.sub(r"\b(a|an|the|and)\b", " ", text)
    return " ".join(text.split())


def locomo_f1_score(prediction, ground_truth):
    prediction_tokens = [STEMMER.stem(w) for w in normalize_answer(prediction).split()]
    truth_tokens = [STEMMER.stem(w) for w in normalize_answer(ground_truth).split()]
    common = collections.Counter(prediction_tokens) & collections.Counter(truth_tokens)
    same = sum(common.values())
    if same == 0:
        return 0.0
    precision, recall = same / len(prediction_tokens), same / len(truth_tokens)
    return 2 * precision * recall / (precision + recall)


def locomo_multi_f1(prediction, ground_truth):
    predictions = [p.strip() for p in prediction.split(",")]
    truths = [g.strip() for g in ground_truth.split(",")]
    return statistics.mean(max(locomo_f1_score(p, g) for p in predictions) for g in truths)


def locomo_official_score(category, prediction, answer):
    """Official per-category LoCoMo scoring: F1 for 2/3/4, split F1 for 1, keyword rule for 5."""
    answer = str(answer)
    if category == 3:
        answer = answer.split(";")[0].strip()
    if category in (2, 3, 4):
        return locomo_f1_score(prediction, answer)
    if category == 1:
        return locomo_multi_f1(prediction, answer)
    if category == 5:
        lowered = prediction.lower()
        return 1.0 if ("no information available" in lowered or "not mentioned" in lowered) else 0.0
    raise ValueError(category)


def conversation_speakers(corpus):
    counts = collections.Counter()
    for document in corpus["documents"].values():
        for line in document["body"].split("\n"):
            match = re.match(r"^([^:\n]{1,40}): ", line)
            if match and match.group(1) not in ("Session recorded", "Image caption"):
                counts[match.group(1)] += 1
    names = [name for name, _ in counts.most_common(2)]
    while len(names) < 2:
        names.append("the other person")
    return names


def build_context(hits, budget):
    """Concatenate returned passages in rank order until the character budget is spent."""
    blocks, used, total = [], [], 0
    for hit in hits:
        # Root files are MyClip's own navigation templates, not benchmark corpus.
        if hit.get("path") in ("Memory.md", "Now.md", "Profile.md"):
            continue
        passages = [p["text"] for p in hit.get("matches", [])] or [hit.get("summary", "")]
        block = f"[{hit.get('title', '')}]\n" + "\n".join(passages)
        if total + len(block) > budget:
            remaining = budget - total
            if remaining < 200:
                break
            block = block[:remaining]
        blocks.append(block)
        used.append(hit["path"])
        total += len(block)
        if total >= budget:
            break
    return "\n\n".join(blocks), used


def verdict(text):
    return 1 if text.strip().lower().startswith("yes") else 0


def attach_answers(dataset, sample, corpus):
    if dataset == "locomo":
        for question, item in zip(corpus["questions"], sample["qa"]):
            # Adversarial questions carry the distractor under adversarial_answer; scoring is rule-based for them.
            question["answer"] = item.get("answer", item.get("adversarial_answer", ""))
    else:
        corpus["questions"][0]["answer"] = sample["answer"]
    return corpus


def run_corpus(args, corpus, reader, judge, executor, emit, done):
    """Retrieve sequentially through one MCP process, then score questions on the executor."""
    futures = []
    speakers = conversation_speakers(corpus) if args.dataset == "locomo" else None
    with tempfile.TemporaryDirectory(prefix="myclip-qa-benchmark-") as directory:
        root = pathlib.Path(directory)
        BENCH.write_library(root, corpus)
        client = BENCH.MCP(args.binary, root)
        try:
            client.search("")
            for question in corpus["questions"]:
                if question["id"] in done:
                    continue
                started = time.perf_counter()
                hits = client.search(question["question"], limit=args.top_k)
                latency = time.perf_counter() - started
                context, used = build_context(hits, args.context_chars)
                futures.append(executor.submit(score_question, args, question, corpus["key"], context, used, latency, reader, judge, emit))
        finally:
            client.close()
    return futures


def score_question(args, question, corpus_key, context, used, latency, reader, judge, emit):
    response = reader.complete(reader_prompt(args.dataset, question, context, None if args.dataset != "locomo" else args.speakers.get(corpus_key, ["A", "B"])),
                               args.reader_max_tokens)
    row = {"id": question["id"], "corpus": corpus_key, "category": question["category"], "question": question["question"],
           "answer": question["answer"], "gold_documents": question.get("gold_documents", []), "retrieval_skip_reason": question.get("skip_reason"),
           "context_documents": used, "context_chars": len(context), "retrieval_latency_ms": latency * 1000, "response": response}
    if args.dataset == "locomo":
        category = CATEGORY_NUMBERS[question["category"]]
        row["official_f1"] = locomo_official_score(category, response, question["answer"])
        row["judge"] = None if category == 5 else judge.complete(judge_prompt(args.dataset, question, response), 5)
        row["correct"] = (1 if row["official_f1"] == 1.0 else 0) if category == 5 else verdict(row["judge"])
    else:
        row["judge"] = judge.complete(judge_prompt(args.dataset, question, response), 5)
        row["correct"] = verdict(row["judge"])
    emit(row)
    return row


def aggregate(dataset, rows):
    def mean(values):
        return statistics.mean(values) if values else None
    summary = {"questions": len(rows)}
    if dataset == "locomo":
        core = [r for r in rows if CATEGORY_NUMBERS[r["category"]] != 5]
        summary["official_f1_all_categories"] = mean([r["official_f1"] for r in rows])
        summary["official_f1_categories_1_to_4"] = mean([r["official_f1"] for r in core])
        summary["judge_accuracy_categories_1_to_4"] = mean([r["correct"] for r in core])
        summary["adversarial_abstention_rate"] = mean([r["correct"] for r in rows if CATEGORY_NUMBERS[r["category"]] == 5])
        summary["by_category"] = {c: {"questions": len(g), "official_f1": mean([r["official_f1"] for r in g]),
                                      "judge_accuracy": None if c == "adversarial" else mean([r["correct"] for r in g])}
                                  for c, g in sorted(collections.defaultdict(list, {c: [r for r in rows if r["category"] == c] for c in {r["category"] for r in rows}}).items())}
    else:
        answerable = [r for r in rows if not r["id"].endswith("_abs")]
        summary["accuracy_all_500"] = mean([r["correct"] for r in rows])
        summary["accuracy_answerable"] = mean([r["correct"] for r in answerable])
        summary["abstention_accuracy"] = mean([r["correct"] for r in rows if r["id"].endswith("_abs")])
        summary["by_type"] = {c: {"questions": len(g), "accuracy": mean([r["correct"] for r in g])}
                              for c, g in sorted({c: [r for r in rows if r["category"] == c] for c in {r["category"] for r in rows}}.items())}
    summary["context_chars_mean"] = mean([r["context_chars"] for r in rows])
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", choices=("locomo", "longmemeval"), required=True)
    parser.add_argument("--data", type=pathlib.Path, required=True)
    parser.add_argument("--binary", type=pathlib.Path, default=pathlib.Path(".build/release/myclip-mcp"))
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--reader", default="gpt-4.1-mini")
    parser.add_argument("--judge", default="gpt-4o")
    parser.add_argument("--top-k", type=int, default=10, help="Results requested from memory_search")
    parser.add_argument("--context-chars", type=int, default=12_000)
    parser.add_argument("--reader-max-tokens", type=int, default=200)
    parser.add_argument("--concurrency", type=int, default=6)
    parser.add_argument("--max-corpora", type=int)
    parser.add_argument("--resume", action="store_true", help="Continue an existing output directory")
    parser.add_argument("--dry-run", action="store_true", help="No model calls; fixed mock answers to test the pipeline")
    args = parser.parse_args()
    load_env()
    args.binary = args.binary.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=args.resume)
    reader = ChatModel(args.reader, mock=args.dry_run)
    judge = ChatModel(args.judge, mock=args.dry_run)
    samples = json.loads(args.data.read_text(encoding="utf-8"))
    if args.max_corpora is not None:
        samples = samples[:args.max_corpora]
    adapter = BENCH.locomo_corpus if args.dataset == "locomo" else BENCH.longmemeval_corpus
    metadata = {"dataset": args.dataset, "data_sha256": BENCH.sha256(args.data), "binary_sha256": BENCH.sha256(args.binary),
                "harness_sha256": BENCH.sha256(pathlib.Path(__file__)), "retrieval_harness_sha256": BENCH.sha256(pathlib.Path(BENCH.__file__)),
                "prompts_sha256": BENCH.sha256(pathlib.Path(qa_prompts.__file__)), "model_client_sha256": BENCH.sha256(pathlib.Path(model.__file__)),
                "reader": args.reader, "judge": args.judge, "top_k": args.top_k, "context_chars": args.context_chars,
                "stemming": STEMMING, "dry_run": args.dry_run, "platform": platform.platform(), "python": platform.python_version(),
                "protocol": "question as query; one memory_search call; passages of top-k memories in rank order; official LoCoMo/LongMemEval prompts and scoring",
                "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    output_path = args.output / "queries.jsonl"
    done, rows = set(), []
    if args.resume and output_path.exists():
        for line in output_path.read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            done.add(row["id"])
            rows.append(row)
        print(f"resuming with {len(done)} scored questions", flush=True)
    lock = threading.Lock()
    output = output_path.open("a", encoding="utf-8")

    def emit(row):
        with lock:
            output.write(json.dumps(row, ensure_ascii=False) + "\n")
            output.flush()

    args.speakers = {}
    failures, futures = [], []
    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        for index, sample in enumerate(samples):
            try:
                corpus = attach_answers(args.dataset, sample, adapter(sample, index))
                if all(q["id"] in done for q in corpus["questions"]):
                    continue
                if args.dataset == "locomo":
                    args.speakers[corpus["key"]] = conversation_speakers(corpus)
                futures.extend(run_corpus(args, corpus, reader, judge, executor, emit, done))
                pending = sum(1 for f in futures if not f.done())
                print(f"{index + 1}/{len(samples)} {corpus['key']}: retrieved, {pending} answers pending", flush=True)
            except Exception as error:
                failures.append({"index": index, "error": str(error)})
                print(f"FAILED corpus {index}: {error}", flush=True)
        for future in concurrent.futures.as_completed(futures):
            try:
                rows.append(future.result())
            except Exception as error:
                failures.append({"error": str(error)})
                print(f"FAILED question: {error}", flush=True)
    output.close()
    summary = {**metadata, "wall_seconds": time.perf_counter() - started, "failures": failures,
               "usage": {"reader": dict(reader.usage), "judge": dict(judge.usage)}, "overall": aggregate(args.dataset, rows)}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(summary["overall"], indent=2, ensure_ascii=False), flush=True)
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
