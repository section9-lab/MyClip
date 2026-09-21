#!/usr/bin/env python3
"""End-to-end QA benchmark: MyClip retrieval, then a reader model answers, then a judge scores.

Retrieval reuses benchmark_memory.py (raw session Markdown, real MCP). Prompts and scoring follow the
official LoCoMo (token F1 with Porter stemming, category rules) and LongMemEval (per-type judge templates)
code that is vendored under build/memory-benchmark/data. The LoCoMo LLM-judge accuracy is an additional,
non-official metric reported separately for comparison with vendor self-reports.
"""

import argparse
import collections
import concurrent.futures
import importlib.util
import json
import os
import pathlib
import platform
import re
import statistics
import string
import tempfile
import threading
import time
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
ENV_FILE = pathlib.Path.home() / ".config/myclip/memory-benchmark.env"
CATEGORY_NUMBERS = {"multi-hop": 1, "temporal": 2, "open-domain": 3, "single-hop": 4, "adversarial": 5}

LOCOMO_HEADER = ("Below are excerpts from conversations between two people, {} and {}. The conversations take place over "
                 "multiple days and the date of each conversation is written at the beginning of each excerpt.\n\n")
LOCOMO_QA = ("\nBased on the above context, write an answer in the form of a short phrase for the following question. "
             "Answer with exact words from the context whenever possible.\n\nQuestion: {} Short answer:\n")
LOCOMO_QA_CAT5 = ("\nBased on the above context, answer the following question. If the information is not available in the "
                  "context, answer 'No information available'.\n\nQuestion: {} Short answer:\n")
LOCOMO_TEMPORAL_SUFFIX = " Use DATE of CONVERSATION to answer with an approximate date."
LOCOMO_JUDGE = ("I will give you a question, a correct answer, and a response from a model. Please answer yes if the response "
                "contains the correct answer or is semantically equivalent to it. Minor wording differences, extra context, or "
                "approximate dates within the same week are fine. If the response contradicts the correct answer or only contains "
                "part of the information required, answer no.\n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\n"
                "Is the model response correct? Answer yes or no only.")

LME_READER = ("I will give you several history chats between you and a user. Please answer the question based on the relevant "
              "chat history.\n\n\nHistory Chats:\n\n{}\n\nCurrent Date: {}\nQuestion: {}\nAnswer:")
LME_JUDGE_DEFAULT = ("I will give you a question, a correct answer, and a response from a model. Please answer yes if the response "
                     "contains the correct answer. Otherwise, answer no. If the response is equivalent to the correct answer or "
                     "contains all the intermediate steps to get the correct answer, you should also answer yes. If the response "
                     "only contains a subset of the information required by the answer, answer no. \n\nQuestion: {}\n\nCorrect "
                     "Answer: {}\n\nModel Response: {}\n\nIs the model response correct? Answer yes or no only.")
LME_JUDGE = {
    "single-session-user": LME_JUDGE_DEFAULT, "single-session-assistant": LME_JUDGE_DEFAULT, "multi-session": LME_JUDGE_DEFAULT,
    "temporal-reasoning": LME_JUDGE_DEFAULT.replace(
        "answer no. \n\nQuestion",
        "answer no. In addition, do not penalize off-by-one errors for the number of days. If the question asks for the number of "
        "days/weeks/months, etc., and the model makes off-by-one errors (e.g., predicting 19 days when the answer is 18), the "
        "model's response is still correct. \n\nQuestion"),
    "knowledge-update": ("I will give you a question, a correct answer, and a response from a model. Please answer yes if the response "
                         "contains the correct answer. Otherwise, answer no. If the response contains some previous information along "
                         "with an updated answer, the response should be considered as correct as long as the updated answer is the "
                         "required answer.\n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\nIs the model response "
                         "correct? Answer yes or no only."),
    "single-session-preference": ("I will give you a question, a rubric for desired personalized response, and a response from a "
                                  "model. Please answer yes if the response satisfies the desired response. Otherwise, answer no. The "
                                  "model does not need to reflect all the points in the rubric. The response is correct as long as it "
                                  "recalls and utilizes the user's personal information correctly.\n\nQuestion: {}\n\nRubric: {}\n\n"
                                  "Model Response: {}\n\nIs the model response correct? Answer yes or no only."),
}
LME_JUDGE_ABSTENTION = ("I will give you an unanswerable question, an explanation, and a response from a model. Please answer yes if "
                        "the model correctly identifies the question as unanswerable. The model could say that the information is "
                        "incomplete, or some other information is given but the asked information is not.\n\nQuestion: {}\n\n"
                        "Explanation: {}\n\nModel Response: {}\n\nDoes the model correctly identify the question as unanswerable? "
                        "Answer yes or no only.")


def load_module(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BENCH = load_module("benchmark_memory")


def load_env(path=ENV_FILE):
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


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


def reader_prompt(dataset, question, context, speakers=None):
    if dataset == "locomo":
        category = CATEGORY_NUMBERS[question["category"]]
        text = question["question"] + (LOCOMO_TEMPORAL_SUFFIX if category == 2 else "")
        return LOCOMO_HEADER.format(*speakers) + context + (LOCOMO_QA_CAT5 if category == 5 else LOCOMO_QA).format(text)
    return LME_READER.format(context, question.get("question_date") or "unknown", question["question"])


def judge_prompt(dataset, question, response):
    if dataset == "locomo":
        return LOCOMO_JUDGE.format(question["question"], question["answer"], response)
    if question["id"].endswith("_abs"):
        return LME_JUDGE_ABSTENTION.format(question["question"], question["answer"], response)
    return LME_JUDGE[question["category"]].format(question["question"], question["answer"], response)


class ChatModel:
    def __init__(self, model, base_url=None, api_key=None, mock=False, timeout=180, retries=6):
        self.model, self.mock, self.timeout, self.retries = model, mock, timeout, retries
        self.base_url = (base_url or os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1")).rstrip("/")
        self.api_key = api_key or os.environ.get("OPENAI_API_KEY", "")
        self.usage = collections.Counter()
        self.lock = threading.Lock()
        if not mock and not self.api_key:
            raise SystemExit(f"OPENAI_API_KEY is not set; fill it in {ENV_FILE} (never paste it into chat).")

    def complete(self, prompt, max_tokens):
        if self.mock:
            return "No information available" if max_tokens > 8 else "no"
        body = json.dumps({"model": self.model, "temperature": 0, "max_tokens": max_tokens,
                           "messages": [{"role": "user", "content": prompt}]}).encode()
        request = urllib.request.Request(self.base_url + "/chat/completions", data=body, method="POST",
                                         headers={"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"})
        delay = 2
        for attempt in range(self.retries):
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    payload = json.loads(response.read().decode())
                usage = payload.get("usage") or {}
                with self.lock:
                    self.usage["prompt_tokens"] += usage.get("prompt_tokens", 0)
                    self.usage["completion_tokens"] += usage.get("completion_tokens", 0)
                    self.usage["requests"] += 1
                return (payload["choices"][0]["message"]["content"] or "").strip()
            except urllib.error.HTTPError as error:
                detail = error.read().decode(errors="replace")[:300]
                if error.code in (400, 401, 403, 404):
                    raise RuntimeError(f"{self.model}: HTTP {error.code} {detail}") from None
                last = f"HTTP {error.code} {detail}"
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, KeyError) as error:
                last = repr(error)
            time.sleep(delay)
            delay = min(delay * 2, 60)
        raise RuntimeError(f"{self.model}: gave up after {self.retries} attempts: {last}")


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
                hits = client.call("tools/call", {"name": "search_memories", "arguments": {
                    "query": question["question"], "limit": args.top_k, "expand": args.expand}})["structuredContent"]
                latency = time.perf_counter() - started
                context, used = build_context(hits["memories"], args.context_chars)
                if args.expand:
                    related = "\n\n".join(f"[Related: {r.get('title', '')}]\n" + "\n".join(v.get("passage", "") for v in r.get("via", []))
                                          for r in hits.get("related", []))
                    if related and len(context) + len(related) <= args.context_chars * 1.25:
                        context += "\n\n" + related
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
    parser.add_argument("--top-k", type=int, default=10, help="Memories requested from search_memories")
    parser.add_argument("--context-chars", type=int, default=12_000)
    parser.add_argument("--expand", action="store_true", help="Also feed one-hop related passages to the reader")
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
                "harness_sha256": BENCH.sha256(pathlib.Path(__file__)), "retrieval_harness_sha256": BENCH.sha256(HERE / "benchmark_memory.py"),
                "reader": args.reader, "judge": args.judge, "top_k": args.top_k, "context_chars": args.context_chars, "expand": args.expand,
                "stemming": STEMMING, "dry_run": args.dry_run, "platform": platform.platform(), "python": platform.python_version(),
                "protocol": "question as query; one search_memories call; passages of top-k memories in rank order; official LoCoMo/LongMemEval prompts and scoring",
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
