import io
import pathlib
import unittest

from benchmark import retrieval


class MemoryBenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.bench = retrieval

    def test_locomo_import_does_not_include_gold_or_generated_summaries(self):
        sample = {
            "conversation": {
                "session_1_date_time": "9:00 am on 8 May, 2023",
                "session_1": [{"speaker": "Alice", "dia_id": "D1:1", "text": "I planted a tree."}],
            },
            "qa": [{"question": "Secret question", "answer": "SECRET_ANSWER", "category": 4, "evidence": ["D1:1"]}],
            "observation": {"text": "SECRET_SUMMARY"},
            "event_summary": {"text": "SECRET_EVENT"},
        }
        corpus = self.bench.locomo_corpus(sample, 0)
        content = str(corpus["documents"])
        self.assertIn("Alice: I planted a tree.", content)
        self.assertIn("8 May, 2023", content)
        for forbidden in ("SECRET", "Secret question", "D1:1"):
            self.assertNotIn(forbidden, content)
        self.assertEqual(corpus["questions"][0]["gold_documents"], ["Wiki/session-0001.md"])

    def test_longmemeval_labels_do_not_change_imported_documents(self):
        sample = {
            "question_id": "q1", "question_type": "knowledge-update", "question": "Where?", "answer": "SECRET",
            "haystack_session_ids": ["source-1"], "haystack_dates": ["2023/01/01 (Sun) 10:00"],
            "haystack_sessions": [[{"role": "user", "content": "I moved to Shanghai.", "has_answer": True}]],
            "answer_session_ids": ["source-1"],
        }
        first = self.bench.longmemeval_corpus(sample, 0)
        sample["haystack_sessions"][0][0]["has_answer"] = False
        sample["answer"] = "ANOTHER_ANSWER"
        sample["answer_session_ids"] = []
        second = self.bench.longmemeval_corpus(sample, 0)
        self.assertEqual(first["documents"], second["documents"])
        self.assertNotIn("SECRET", str(first["documents"]))

    def test_invalid_evidence_is_reported_not_silently_removed(self):
        sample = {
            "conversation": {"session_1": [{"speaker": "A", "dia_id": "D1:1", "text": "A fact."}]},
            "qa": [{"question": "Which?", "category": 4, "evidence": ["D1:1", "D99:9"]}],
        }
        question = self.bench.locomo_corpus(sample, 0)["questions"][0]
        self.assertEqual(question["skip_reason"], "invalid_evidence")
        self.assertEqual(question["invalid_evidence"], ["D99:9"])

    def test_recall_is_not_hit_rate_and_duplicate_hits_do_not_inflate_it(self):
        score = self.bench.retrieval_metrics(["a", "a", "x", "b"], ["a", "b"] , (1, 3, 4))
        self.assertEqual(score["recall@1"], 0.5)
        self.assertEqual(score["hit@1"], 1)
        self.assertEqual(score["all@3"], 0)
        self.assertEqual(score["all@4"], 1)
        self.assertEqual(score["mrr"], 1)

    def test_missing_gold_has_no_retrieval_score(self):
        self.assertIsNone(self.bench.retrieval_metrics(["a"], [], (1,)))

    def test_snippet_evidence_must_come_from_the_correct_document(self):
        gold = {"turn-1": {"path": "a", "text": "A complete fact."}}
        wrong = [{"path": "b", "matches": [{"text": "A complete fact."}]}]
        partial = [{"path": "a", "matches": [{"text": "A complete"}]}]
        right = [{"path": "a", "matches": [{"text": "Speaker: A complete\n fact."}]}]
        self.assertEqual(self.bench.covered_turns(wrong, gold), [])
        self.assertEqual(self.bench.covered_turns(partial, gold), [])
        self.assertEqual(self.bench.covered_turns(right, gold), ["turn-1"])

    def test_evidence_can_span_returned_paragraphs_in_original_order(self):
        gold = {"turn-1": {"path": "a", "text": "First fact.\n\nSecond fact."}}
        hits = [{"path": "a", "matches": [
            {"text": "Second fact.", "startOffset": 30},
            {"text": "First fact.", "startOffset": 10},
        ]}]
        self.assertEqual(self.bench.covered_turns(hits, gold), ["turn-1"])

    def test_linked_episode_counts_only_when_a_shown_line_restates_its_evidence(self):
        turns = {"t1": {"path": "Daily/2023-05-08.md", "text": "Caroline adopted a rescue puppy named Oscar."},
                 "t2": {"path": "Daily/2023-06-01.md", "text": "Melanie painted a lake sunrise."}}
        gold = ["Daily/2023-05-08.md", "Daily/2023-06-01.md"]
        raw = {"path": "Wiki/People/Caroline.md", "matches": [{"text":
            "- Adopted rescue puppy Oscar [[Daily/2023-05-08|5/8]]\n- Went hiking [[Daily/2023-06-01|6/1]]"}]}
        self.assertEqual(self.bench.delivered_documents(raw, {t["path"]: t["text"] for t in turns.values()}),
                         {"Wiki/People/Caroline.md", "Daily/2023-05-08.md"}, "Older snippets carry the raw Wikilinks")
        shown = {"path": "Wiki/People/Caroline.md", "links": ["Daily/2023-05-08.md#Puppy", "Daily/2023-06-01.md", "Wiki/People/Melanie.md"],
                 "matches": [{"text": "- Adopted rescue puppy Oscar 5/8\n- Went hiking 6/1"}]}
        metrics = self.bench.evidence_metrics([shown], gold, turns, cutoffs=(1,))
        self.assertEqual(metrics, {"evidence_recall@1": 0.5, "evidence_all@1": 0})

    def test_real_import_validation_preserves_carriage_returns(self):
        binary = pathlib.Path(__file__).resolve().parents[2] / ".build/debug/myclip-mcp"
        if not binary.exists():
            self.skipTest("Build myclip-mcp for the integration test")
        path, body = "Wiki/session-0001.md", "First line.\r\nCobalt calibration facts.\r\n"
        corpus = {"key": "line-ending-test", "documents": {path: {"title": "Conversation", "body": body}},
            "questions": [{"id": "q1", "question": "cobalt", "category": "test", "skip_reason": None,
                "gold_documents": [path], "gold_turns": {"t1": {"path": path, "text": "Cobalt calibration facts."}}}]}
        try:
            rows, _ = self.bench.run_corpus(binary, corpus, io.StringIO())
        except ValueError as error:
            self.fail(f"Preserved CRLF input must pass the import integrity check: {error}")
        self.assertEqual(rows[0]["metrics"]["all@1"], 1)


if __name__ == "__main__":
    unittest.main()
