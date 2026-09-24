import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

from benchmark import qa


class MemoryQABenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.qa = qa

    def test_locomo_normalization_and_f1_follow_the_official_rules(self):
        self.assertEqual(self.qa.normalize_answer("The Cat, and a dog!"), "cat dog")
        self.assertAlmostEqual(self.qa.locomo_f1_score("7 May 2023", "7 May 2023"), 1.0)
        self.assertAlmostEqual(self.qa.locomo_f1_score("researching corals", "research coral"), 1.0 if self.qa.STEMMING != "none" else 0.0)
        self.assertEqual(self.qa.locomo_official_score(3, "painting", "painting; drawing"), 1.0)
        self.assertAlmostEqual(self.qa.locomo_official_score(1, "Paris, hiking", "hiking, Paris"), 1.0)
        self.assertEqual(self.qa.locomo_official_score(5, "There is no information available.", "x"), 1.0)
        self.assertEqual(self.qa.locomo_official_score(5, "She went to Paris.", "x"), 0.0)

    def test_prompts_use_official_templates_and_abstention_judge(self):
        q = {"id": "q_abs", "category": "knowledge-update", "question": "Q?", "answer": "explanation", "question_date": "2023/05/30"}
        self.assertIn("unanswerable", self.qa.judge_prompt("longmemeval", q, "I don't know"))
        q["id"] = "q"
        self.assertIn("updated answer", self.qa.judge_prompt("longmemeval", q, "x"))
        reader = self.qa.reader_prompt("longmemeval", q, "CONTEXT")
        self.assertIn("Current Date: 2023/05/30", reader)
        self.assertTrue(reader.startswith("I will give you several history chats"))
        temporal = {"id": "l", "category": "temporal", "question": "When?", "answer": "May"}
        prompt = self.qa.reader_prompt("locomo", temporal, "CONTEXT", ["Caroline", "Melanie"])
        self.assertIn("Use DATE of CONVERSATION", prompt)
        self.assertIn("Caroline and Melanie", prompt)
        adversarial = {"id": "l", "category": "adversarial", "question": "Which car?", "answer": "x"}
        self.assertIn("No information available", self.qa.reader_prompt("locomo", adversarial, "CONTEXT", ["A", "B"]))

    def test_context_respects_budget_and_keeps_rank_order(self):
        hits = [{"path": f"Wiki/s{i}.md", "title": f"Conversation {i}", "matches": [{"text": "x" * 500}]} for i in range(5)]
        hits.insert(0, {"path": "Memory.md", "title": "Memory", "matches": [{"text": "template"}]})
        context, used = self.qa.build_context(hits, 1_200)
        self.assertEqual(used, ["Wiki/s0.md", "Wiki/s1.md"], "Two full blocks fit; a third would leave under 200 chars")
        self.assertLessEqual(len(context), 1_200)
        self.assertNotIn("template", context)

    def test_dry_run_end_to_end_with_real_mcp(self):
        binary = pathlib.Path(".build/debug/myclip-mcp")
        if not binary.exists():
            self.skipTest("build the MCP executable first")
        sample = {"question_id": "q_abs", "question_type": "knowledge-update", "question": "Where do I live now?",
                  "question_date": "2023/06/01 (Thu) 10:00", "answer": "Never stated",
                  "haystack_session_ids": ["s1"], "haystack_dates": ["2023/05/01 (Mon) 09:00"],
                  "haystack_sessions": [[{"role": "user", "content": "I moved to Shanghai last year.", "has_answer": False}]],
                  "answer_session_ids": []}
        with tempfile.TemporaryDirectory() as directory:
            data = pathlib.Path(directory) / "data.json"
            data.write_text(json.dumps([sample]))
            out = pathlib.Path(directory) / "out"
            result = subprocess.run([sys.executable, "-m", "benchmark.qa", "--dataset", "longmemeval",
                                     "--data", str(data), "--binary", str(binary), "--output", str(out), "--dry-run", "--concurrency", "1"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            row = json.loads((out / "queries.jsonl").read_text().splitlines()[0])
            self.assertEqual(row["response"], "No information available")
            self.assertGreater(row["context_chars"], 0)
            self.assertEqual(row["context_documents"], ["Wiki/session-0001.md"])
            summary = json.loads((out / "summary.json").read_text())
            self.assertTrue(summary["dry_run"])
            self.assertEqual(summary["overall"]["questions"], 1)
            self.assertNotIn("Never stated", (out / "metadata.json").read_text(), "Gold answers stay out of metadata")


if __name__ == "__main__":
    unittest.main()
