"""OpenAI-compatible model client shared by QA and corpus organization."""

import collections
import json
import os
import pathlib
import threading
import time
import urllib.error
import urllib.request

# The ignored key file stays in benchmark/, next to this module.
ENV_FILE = pathlib.Path(__file__).with_name("memory-benchmark.env")


def load_env(path=ENV_FILE):
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))

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
