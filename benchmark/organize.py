#!/usr/bin/env python3
"""Builds the organized LoCoMo corpus for retrieval track B.

Each conversation is replayed session by session, the way MyClip organizes screenshots in batches. A fixed model reads one
session plus the entity pages written so far and returns fact lines; this script appends each line to its entity page
under a heading, linked to the session it came from:

    ## Pets
    - Took his turtles out for a walk because he was bored [[Daily/2023-10-09-session-0025|2023-10-09]]

Session transcripts are kept unchanged as episode pages under Daily/, dated by the session time, so the gold evidence
labels still point at real files. Questions, answers and evidence labels never reach the model.

Facts come either from an OpenAI-compatible model (`extract`) or from facts logs written by another organizer that was given
the exported sessions and the same prompt (`export`, then `assemble`). Page assembly is identical in both paths.

Output: one JSON file per conversation (documents and remapped questions) plus metadata with the organizer and prompt
hash. The same corpus is reused for every retrieval configuration.
"""
import argparse
import concurrent.futures
import datetime
import hashlib
import json
import pathlib
import re
import sys

from . import retrieval as BENCH
from .model import ChatModel, load_env

PROMPT = (pathlib.Path(__file__).with_name("prompts") / "organize.md").read_text(encoding="utf-8")


def session_day(date_text):
    """LoCoMo session times look like '1:56 pm on 8 May, 2023'."""
    match = re.search(r"(\d{1,2}) (\w+),? (\d{4})", date_text or "")
    if not match:
        return None
    return datetime.datetime.strptime(" ".join(match.groups()), "%d %B %Y").date()


def safe_path(path):
    """Keep model-proposed pages inside Wiki/People and Wiki/Topics with plain file names."""
    match = re.fullmatch(r"Wiki/(People|Topics)/([^/\\\[\]|#]+)\.md", path.strip())
    if not match:
        return None
    name = re.sub(r"\s+", " ", match.group(2)).strip()
    return f"Wiki/{match.group(1)}/{name}.md" if name else None


def episodes_of(sample, index):
    """Raw LoCoMo sessions as dated episode pages, plus the raw-to-episode path map for evidence labels."""
    corpus = BENCH.locomo_corpus(sample, index)
    conversation = sample["conversation"]
    sessions = sorted((key for key in conversation if re.fullmatch(r"session_\d+", key)), key=lambda key: int(key.split("_")[1]))
    episodes, renamed = {}, {}
    for number, key in enumerate(sessions, 1):
        raw_path = f"Wiki/session-{number:04d}.md"
        day = session_day(conversation.get(key + "_date_time", ""))
        path = f"Daily/{day.isoformat() if day else 'undated'}-session-{number:04d}.md"
        renamed[raw_path] = path
        episodes[path] = {**corpus["documents"][raw_path], "day": day.isoformat() if day else None, "number": number}
    return corpus, episodes, renamed


def listing(pages):
    return "\n".join(f"{p} | {page['title']} | {', '.join(page['aliases'])} | {', '.join(page['sections'])}"
                     for p, page in sorted(pages.items())) or "(none yet)"


def add_facts(pages, facts, episode_path, day):
    """Appends one session's facts to the entity pages, each linked to the session."""
    link = f"[[{episode_path[:-3]}|{day or 'undated'}]]"
    for fact in facts:
        target = safe_path(str(fact.get("path", "")))
        sentence = " ".join(str(fact.get("text", "")).split())
        if not target or not sentence:
            continue
        page = pages.setdefault(target, {"title": str(fact.get("title") or pathlib.Path(target).stem), "aliases": [], "sections": {}})
        for alias in fact.get("aliases") or []:
            alias = " ".join(str(alias).split())
            if alias and alias not in page["aliases"] and len(page["aliases"]) < 12:
                page["aliases"].append(alias)
        heading = " ".join(str(fact.get("section") or "Notes").split())[:60]
        # Optional retrieval tags (track B tag experiment) follow the link as #words; spaces become hyphens.
        tags = [re.sub(r"[^\w-]+", "", "-".join(str(tag).lower().split())) for tag in fact.get("tags") or []]
        suffix = "".join(f" #{tag}" for tag in tags if tag)
        page["sections"].setdefault(heading, []).append(f"- {sentence} {link}{suffix}")


def parse_facts(reply):
    text = reply.strip().removeprefix("```json").removeprefix("```").removesuffix("```")
    try:
        return json.loads(text).get("facts", [])
    except (json.JSONDecodeError, AttributeError):
        return None


def assemble(corpus, episodes, renamed, pages):
    documents = {path: {"title": episode["title"], "body": episode["body"]} for path, episode in episodes.items()}
    for path, page in pages.items():
        body = f"# {page['title']}\n\n" + "\n\n".join(f"## {heading}\n\n" + "\n".join(lines) for heading, lines in page["sections"].items())
        documents[path] = {"title": page["title"], "body": body, "aliases": page["aliases"]}
    questions = [{**question, "gold_documents": sorted(renamed[p] for p in question["gold_documents"]),
                  "gold_turns": {k: {**turn, "path": renamed[turn["path"]]} for k, turn in question["gold_turns"].items()}}
                 for question in corpus["questions"]]
    return {"key": corpus["key"], "documents": documents, "questions": questions,
            "entity_pages": len(pages), "fact_lines": sum(len(lines) for page in pages.values() for lines in page["sections"].values())}


def extract_with_model(sample, index, model):
    """Replays the conversation through an OpenAI-compatible model, one session at a time."""
    corpus, episodes, renamed = episodes_of(sample, index)
    pages, log = {}, []
    for path, episode in episodes.items():
        prompt = PROMPT.format(pages=listing(pages), date=episode["day"] or "unknown", transcript=episode["body"])
        facts = parse_facts(model.complete(prompt, 4000))
        if facts is None:
            print(f"{corpus['key']} {path}: unparsable reply skipped", flush=True)
            facts = []
        log.append({"session": episode["number"], "facts": facts})
        add_facts(pages, facts, path, episode["day"])
    return {**assemble(corpus, episodes, renamed, pages), "usage": dict(model.usage), "facts": log}


def assemble_from_file(sample, index, facts_file):
    """Builds the corpus from a facts log (one JSON object per session: {"session": n, "facts": [...]})."""
    corpus, episodes, renamed = episodes_of(sample, index)
    by_number = {}
    for line in facts_file.read_text(encoding="utf-8").splitlines():
        if line.strip():
            entry = json.loads(line)
            by_number[int(entry["session"])] = entry.get("facts", [])
    missing = [episode["number"] for episode in episodes.values() if episode["number"] not in by_number]
    if missing:
        raise SystemExit(f"{facts_file}: no facts recorded for sessions {missing}")
    pages = {}
    for path, episode in episodes.items():
        add_facts(pages, by_number[episode["number"]], path, episode["day"])
    return assemble(corpus, episodes, renamed, pages)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    if len(sys.argv) > 1 and sys.argv[1] == "pages":
        # pages FACTS_FILE: the "Existing pages" listing an external organizer passes into PROMPT before the next session.
        pages, facts_file = {}, pathlib.Path(sys.argv[2])
        if facts_file.exists():
            for line in facts_file.read_text(encoding="utf-8").splitlines():
                if line.strip():
                    add_facts(pages, json.loads(line).get("facts", []), "Daily/x.md", None)
        print(listing(pages))
        return
    parser.add_argument("command", choices=("export", "extract", "assemble"),
                        help="export: write dated session transcripts and the prompt for an external organizer; "
                             "extract: organize with an OpenAI-compatible model; assemble: build the corpus from facts logs")
    parser.add_argument("--data", type=pathlib.Path, required=True, help="LoCoMo locomo10.json")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--corpora", default="0:10", help="Half-open conversation index range")
    parser.add_argument("--facts", type=pathlib.Path, help="assemble: directory of locomo-XX.facts.jsonl files")
    parser.add_argument("--model", default="gpt-4.1-mini")
    parser.add_argument("--organizer", help="assemble: who extracted the facts, recorded in metadata")
    parser.add_argument("--workers", type=int, default=5)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    first, last = (int(part) for part in args.corpora.split(":"))
    samples = json.loads(args.data.read_text(encoding="utf-8"))
    indices = range(first, min(last, len(samples)))
    if args.command == "export":
        (args.output / "PROMPT.txt").write_text(PROMPT, encoding="utf-8")
        for index in indices:
            corpus, episodes, _ = episodes_of(samples[index], index)
            directory = args.output / corpus["key"]
            directory.mkdir(exist_ok=True)
            for episode in episodes.values():
                (directory / f"session-{episode['number']:04d}.md").write_text(
                    f"Session date: {episode['day'] or 'unknown'}\n{episode['body']}", encoding="utf-8")
            print(f"{corpus['key']}: {len(episodes)} sessions", flush=True)
        return
    metadata = {"data_sha256": BENCH.sha256(args.data), "prompt_sha256": hashlib.sha256(PROMPT.encode()).hexdigest(),
                "script_sha256": BENCH.sha256(pathlib.Path(__file__)), "corpora": args.corpora, "conversations": {}}
    if args.command == "extract":
        load_env()
        metadata["organizer"] = args.model
        with concurrent.futures.ThreadPoolExecutor(args.workers) as executor:
            # One client per conversation keeps each conversation's token usage separate.
            futures = [executor.submit(extract_with_model, samples[index], index, ChatModel(args.model)) for index in indices]
            results = [future.result() for future in concurrent.futures.as_completed(futures)]
    else:
        metadata["organizer"] = args.organizer or "external"
        results = [assemble_from_file(samples[index], index, args.facts / f"locomo-{index:02d}.facts.jsonl") for index in indices]
    for result in results:
        (args.output / f"{result['key']}.json").write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
        metadata["conversations"][result["key"]] = {k: result[k] for k in ("entity_pages", "fact_lines", "usage") if k in result}
        print(f"{result['key']}: {result['entity_pages']} pages, {result['fact_lines']} fact lines", flush=True)
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    main()
