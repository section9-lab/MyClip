#!/usr/bin/env python3
"""Retrieval diagnostics on public memory datasets through the real MyClip MCP.

This is not an end-to-end QA benchmark. No LLM, extraction, answer generation,
gold-driven query rewriting, screenshot fabrication, or judge is involved.
"""

import argparse
import collections
import hashlib
import json
import pathlib
import platform
import re
import select
import statistics
import subprocess
import tempfile
import time
import unicodedata
import uuid


CUTOFFS = (1, 5, 10, 20)
CATEGORIES = {1: "multi-hop", 2: "temporal", 3: "open-domain", 4: "single-hop", 5: "adversarial"}


def session_document(number, date, turns):
    path = f"Wiki/session-{number:04d}.md"
    title = f"Conversation on {date}" if date else "Conversation"
    paragraphs = [f"Session recorded: {date}"] if date else []
    for speaker, text, caption in turns:
        paragraphs.append(f"{speaker}: {text}")
        if caption:
            paragraphs.append(f"Image caption: {caption}")
    body = "\n\n".join(paragraphs)
    if len(body.encode("utf-8")) > 128_000:
        raise ValueError(f"{path} exceeds MyClip's 128 KB document limit; do not silently truncate")
    return path, {"title": title, "body": body}


def locomo_corpus(sample, index):
    documents, turns = {}, {}
    conversation = sample["conversation"]
    sessions = sorted((key for key in conversation if re.fullmatch(r"session_\d+", key)),
                      key=lambda key: int(key.split("_")[1]))
    for number, key in enumerate(sessions, 1):
        original = conversation[key]
        path, document = session_document(number, conversation.get(key + "_date_time", ""),
            [(t["speaker"], t["text"], t.get("blip_caption", "")) for t in original])
        documents[path] = document
        for turn in original:
            turns[turn["dia_id"]] = {"path": path, "text": turn["text"]}
    questions = []
    for number, item in enumerate(sample["qa"]):
        evidence, invalid = [], []
        for raw in item.get("evidence", []):
            # Accept lists separated by punctuation/whitespace and leading zeroes.
            # Reject nonexistent IDs and malformed leftovers instead of fixing labels.
            ids = re.findall(r"D(\d+):(\d+)", raw)
            leftover = re.sub(r"D\d+:\d+", "", raw).strip(" ,;[]\t\n")
            normalized = [f"D{int(a)}:{int(b)}" for a, b in ids]
            if leftover or not normalized:
                invalid.append(raw)
            invalid.extend(e for e in normalized if e not in turns)
            evidence.extend(e for e in normalized if e in turns)
        reason = ("adversarial" if item["category"] == 5 else "invalid_evidence" if invalid
                  else "no_evidence" if not evidence else None)
        questions.append({"id": f"locomo-{index:02d}-{number:04d}", "question": item["question"],
            "category": CATEGORIES[item["category"]], "skip_reason": reason, "invalid_evidence": invalid,
            "gold_documents": sorted({turns[e]["path"] for e in evidence}),
            "gold_turns": {e: turns[e] for e in evidence}})
    return {"key": f"locomo-{index:02d}", "documents": documents, "questions": questions}


def longmemeval_corpus(sample, index):
    documents, sessions, gold_turns = {}, {}, {}
    rows = zip(sample["haystack_session_ids"], sample["haystack_dates"], sample["haystack_sessions"])
    for number, (session_id, date, original) in enumerate(rows, 1):
        path, document = session_document(number, date, [(t["role"], t["content"], "") for t in original])
        documents[path] = document
        sessions[session_id] = path
        for turn_index, turn in enumerate(original):
            if turn.get("has_answer"):
                gold_turns[f"{session_id}:{turn_index}"] = {"path": path, "text": turn["content"]}
    evidence = sample.get("answer_session_ids", [])
    invalid = [e for e in evidence if e not in sessions]
    reason = ("abstention" if sample["question_id"].endswith("_abs") else "invalid_evidence" if invalid
              else "no_evidence" if not evidence else None)
    question = {"id": sample["question_id"], "question": sample["question"],
        "question_date": sample.get("question_date"), "category": sample["question_type"],
        "skip_reason": reason, "invalid_evidence": invalid,
        "gold_documents": sorted({sessions[e] for e in evidence if e in sessions}), "gold_turns": gold_turns}
    return {"key": f"longmemeval-{index:04d}", "documents": documents, "questions": [question]}


def retrieval_metrics(ranked, gold, cutoffs=CUTOFFS):
    gold = set(gold)
    if not gold:
        return None
    metrics = {"mrr": next((1 / rank for rank, item in enumerate(ranked, 1) if item in gold), 0)}
    for k in cutoffs:
        count = len(set(ranked[:k]) & gold)
        metrics.update({f"recall@{k}": count / len(gold), f"hit@{k}": int(count > 0),
                        f"all@{k}": int(count == len(gold))})
    return metrics


def normalized(text):
    return " ".join(unicodedata.normalize("NFC", text).split())


def covered_turns(hits, gold):
    passages = collections.defaultdict(list)
    for hit in hits:
        passages[hit["path"]].extend((p.get("startOffset", 0), normalized(p["text"])) for p in hit.get("matches", []))
    contexts = {path: " ".join(text for _, text in sorted(parts, key=lambda part: part[0]))
                for path, parts in passages.items()}
    return [key for key, turn in gold.items() if normalized(turn["text"])
            and normalized(turn["text"]) in contexts.get(turn["path"], "")]


class MCP:
    def __init__(self, binary, root):
        self.process = subprocess.Popen([str(binary), "--library", str(root)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.sequence = 0
        self.call("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                 "clientInfo": {"name": "myclip-retrieval-benchmark", "version": "1"}})

    def call(self, method, params):
        self.sequence += 1
        request = {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params}
        self.process.stdin.write((json.dumps(request) + "\n").encode())
        self.process.stdin.flush()
        if not select.select([self.process.stdout], [], [], 180)[0]:
            raise TimeoutError(f"MCP request timed out: {method}")
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("MCP exited: " + self.process.stderr.read().decode())
        reply = json.loads(line)
        if reply.get("id") != self.sequence or "error" in reply:
            raise RuntimeError(str(reply))
        result = reply["result"]
        if result.get("isError"):
            raise RuntimeError(str(result))
        return result

    def search(self, query):
        return self.call("tools/call", {"name": "search_memories", "arguments": {"query": query, "limit": 20, "expand": False}})["structuredContent"]["memories"]

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process.stdout.close()
        self.process.stderr.close()


def write_library(root, corpus):
    for path, document in corpus["documents"].items():
        destination = root / "Memory" / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        identity = uuid.uuid5(uuid.NAMESPACE_URL, corpus["key"] + "/" + path)
        metadata = (f"---\nid: {identity}\nkind: memory\ntitle: {json.dumps(document['title'])}\n"
                    "revision: 1\nagent: codex\nupdated_at: 2000-01-01T00:00:00Z\nsource_ids: []\n---\n")
        destination.write_text(metadata + document["body"], encoding="utf-8")


def run_corpus(binary, corpus, output):
    rows = []
    with tempfile.TemporaryDirectory(prefix="myclip-benchmark-") as directory:
        root = pathlib.Path(directory)
        write_library(root, corpus)
        client = MCP(binary, root)
        try:
            started = time.perf_counter()
            client.search("")  # Import/index all documents before timing queries.
            ingestion_seconds = time.perf_counter() - started
            # Verify every input file survived the real importer without truncation.
            for path, document in corpus["documents"].items():
                imported = (root / "Memory" / path).read_bytes().decode("utf-8").split("\n---\n", 1)[1]
                if imported != document["body"]:
                    raise ValueError(f"Importer changed benchmark text: {path}")
            for question in corpus["questions"]:
                started = time.perf_counter()
                hits = client.search(question["question"])
                elapsed = time.perf_counter() - started
                metrics = None
                if question["skip_reason"] is None:
                    metrics = retrieval_metrics([h["path"] for h in hits], question["gold_documents"])
                    for k in CUTOFFS:
                        if question["gold_turns"]:
                            covered = covered_turns(hits[:k], question["gold_turns"])
                            metrics[f"full_turn_recall@{k}"] = len(covered) / len(question["gold_turns"])
                            metrics[f"full_turn_all@{k}"] = int(len(covered) == len(question["gold_turns"]))
                        metrics[f"random_document_recall@{k}"] = min(k / (len(corpus["documents"]) + 3), 1)
                row = {**question, "corpus": corpus["key"], "document_count": len(corpus["documents"]),
                    "latency_ms": elapsed * 1000, "metrics": metrics,
                    "returned_passage_characters": sum(len(p["text"]) for h in hits for p in h.get("matches", [])),
                    "hits": hits}
                # Ground truth is only written here, outside the temporary library.
                output.write(json.dumps(row, ensure_ascii=False) + "\n")
                output.flush()
                rows.append(row)
        finally:
            client.close()
    return rows, ingestion_seconds


def percentile(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int((len(values) - 1) * p))] if values else None


def aggregate(rows):
    scored = [row["metrics"] for row in rows if row["metrics"] is not None]
    names = sorted({name for metrics in scored for name in metrics})
    latency = [row["latency_ms"] for row in rows]
    return {"queries": len(rows), "scored_queries": len(scored),
        "excluded": dict(collections.Counter(row["skip_reason"] for row in rows if row["skip_reason"])),
        "metrics": {name: statistics.mean(m[name] for m in scored if name in m) for name in names},
        "metric_denominators": {name: sum(name in m for m in scored) for name in names},
        "latency_ms": {"p50": percentile(latency, .5), "p95": percentile(latency, .95)},
        "returned_passage_characters_mean": statistics.mean(row["returned_passage_characters"] for row in rows) if rows else 0}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", choices=("locomo", "longmemeval"), required=True)
    parser.add_argument("--data", type=pathlib.Path, required=True)
    parser.add_argument("--binary", type=pathlib.Path, default=pathlib.Path(".build/release/myclip-mcp"))
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--max-corpora", type=int, help="Smoke test only; omit for the full dataset")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    binary = args.binary.resolve(strict=True)
    samples = json.loads(args.data.read_text(encoding="utf-8"))
    if args.max_corpora is not None:
        samples = samples[:args.max_corpora]
    adapter = locomo_corpus if args.dataset == "locomo" else longmemeval_corpus
    metadata = {"dataset": args.dataset, "data_sha256": sha256(args.data), "binary_sha256": sha256(binary),
        "harness_sha256": sha256(pathlib.Path(__file__)), "platform": platform.platform(),
        "python": platform.python_version(), "corpora_requested": len(samples),
        "protocol": "raw session Markdown; unmodified question; one real MCP search; limit=20; no LLM",
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    rows, imports, failures = [], [], []
    started = time.perf_counter()
    with (args.output / "queries.jsonl").open("w", encoding="utf-8") as output:
        for index, sample in enumerate(samples):
            try:
                corpus = adapter(sample, index)
                results, ingestion = run_corpus(binary, corpus, output)
                rows.extend(results)
                imports.append({"corpus": corpus["key"], "seconds": ingestion,
                                "documents": len(corpus["documents"])})
                print(f"{index + 1}/{len(samples)} {corpus['key']}: {len(results)} queries, import {ingestion:.2f}s", flush=True)
            except Exception as error:
                failures.append({"index": index, "error": str(error)})
                print(f"FAILED corpus {index}: {error}", flush=True)
    summary = {**metadata, "wall_seconds": time.perf_counter() - started, "failures": failures,
        "overall": aggregate(rows), "by_category": {category: aggregate([r for r in rows if r["category"] == category])
            for category in sorted({row["category"] for row in rows})}, "imports": imports}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"overall": summary["overall"], "failed_corpora": len(failures)}, indent=2), flush=True)
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
