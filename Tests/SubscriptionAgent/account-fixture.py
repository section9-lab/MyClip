import json
import os
import sys

pending = None
answers = {}

def send(message):
    print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)

for line in sys.stdin:
    request = json.loads(line)
    if request.get("method") == "initialize":
        send({"id": request["id"], "result": {"protocolVersion": 1,
              "agentCapabilities": {"promptCapabilities": {"image": True}}, "authMethods": []}})
    elif request.get("method") == "authenticate":
        pending = request
        for key, method, params in [
            ("read", "read", {}),
            ("save", "save", {"credential": {"type": "oauth", "uid": "fixture", "access": "fixture-rotated"}}),
            ("bad-url", "open_url", {"url": "https://unrelated.example/login"}),
            ("good-url", "open_url", {"url": "https://gateway.qwenwork.cn/device/selectAccounts"}),
            ("status", "status", {"account": "Fixture", "accountID": "fixture", "plan": "Fixture plan",
                                   "credits": {"used": None, "total": None, "remaining": 42.5}}),
        ]:
            send({"id": key, "method": "myclip/account/" + method, "params": params})
    elif request.get("id") in ("read", "save", "bad-url", "good-url", "status"):
        answers[request["id"]] = request
        if len(answers) == 5:
            if os.environ.get("FIXTURE_ACCOUNT_ALLOWED") == "1":
                valid = (answers["read"].get("result", {}).get("access") == "fixture-original"
                         and "result" in answers["save"] and "error" in answers["bad-url"]
                         and "result" in answers["good-url"] and "result" in answers["status"])
            else:
                valid = all("error" in value for value in answers.values())
            if valid:
                send({"id": pending["id"], "result": {}})
            else:
                send({"id": pending["id"], "error": {"code": -32603, "message": "Account scope assertion failed"}})
