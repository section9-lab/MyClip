import json
import re
import os
import sys
import uuid

scenario = os.environ.get("MYCLIP_ACP_SCENARIO", "success")
pending_prompt = None
conversation_file = os.environ.get("MYCLIP_ACP_CONVERSATIONS")
conversations = {}
if conversation_file and os.path.exists(conversation_file):
    with open(conversation_file) as saved:
        conversations = json.load(saved)

def save_conversations():
    with open(conversation_file, "w") as saved:
        json.dump(conversations, saved)

def send(value):
    data = (json.dumps(value, ensure_ascii=False) + "\n").encode("utf-8")
    # Exercise framing across partial writes, including multibyte text.
    os.write(sys.stdout.fileno(), data[:9])
    os.write(sys.stdout.fileno(), data[9:])

def result(request, value):
    send({"jsonrpc": "2.0", "id": request["id"], "result": value})

def finish(request, text="你好，已整理", reason="end_turn"):
    send({"jsonrpc":"2.0", "method":"session/update", "params":{
        "sessionId":request["params"].get("sessionId", "s1"), "update":{"sessionUpdate":"agent_message_chunk", "content":{"type":"text", "text":text}}
    }})
    result(request, {"stopReason":reason})

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if conversation_file:
        with open(conversation_file + ".requests", "a") as log:
            log.write(json.dumps(request) + "\n")
    if method == "initialize":
        capabilities = {"promptCapabilities":{"image":scenario != "no_images"}}
        if conversation_file and scenario != "conversation_no_restore":
            capabilities["loadSession"] = True
            if scenario != "conversation_load_only":
                capabilities["sessionCapabilities"] = {"resume":{}}
        result(request, {"protocolVersion":1, "agentCapabilities":capabilities, "authMethods":[]})
    elif method == "session/new":
        session = str(uuid.uuid4()) if conversation_file else "s1"
        if conversation_file:
            conversations[session] = []
            save_conversations()
        result(request, {"sessionId":session})
    elif method in ("session/resume", "session/load"):
        session = request["params"]["sessionId"]
        if scenario == "conversation_auth":
            send({"jsonrpc":"2.0", "id":request["id"], "error":{"code":-32000,"message":"Authentication required"}})
        elif scenario == "conversation_missing" or session not in conversations:
            send({"jsonrpc":"2.0", "id":request["id"], "error":{"code":-32002,"message":"Session not found"}})
        else:
            if method == "session/load":
                send({"jsonrpc":"2.0", "method":"session/update", "params":{
                    "sessionId":session, "update":{"sessionUpdate":"agent_message_chunk", "content":{"type":"text", "text":"replayed history"}}
                }})
            result(request, {})
    elif method == "session/prompt":
        if conversation_file:
            session = request["params"]["sessionId"]
            conversations[session].append(request["params"]["prompt"][0]["text"])
            save_conversations()
            finish(request, "|".join(conversations[session]))
            continue
        if scenario == "crash":
            print("fixture disconnected", file=sys.stderr, flush=True)
            sys.exit(7)
        pending_prompt = request
        if scenario == "permission":
            send({"jsonrpc":"2.0", "id":"permission-7", "method":"session/request_permission", "params":{
                "sessionId":"s1", "toolCall":{"toolCallId":"tool1", "title":"查看来源"},
                "options":[{"optionId":"allow1", "name":"允许一次", "kind":"allow_once"}, {"optionId":"reject1", "name":"拒绝", "kind":"reject_once"}]
            }})
        elif scenario == "knowledge":
            text = request["params"]["prompt"][0]["text"]
            source = re.search(r"sourceID=([0-9A-Fa-f-]{36})", text).group(1)
            finish(request, json.dumps({"entries":[{"kind":"wiki", "title":"聚焦窗口", "body":"回车触发应用截图。", "sourceIDs":[source]}]}, ensure_ascii=False))
        elif scenario == "float_metadata":
            send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"s1", "update":{"sessionUpdate":"usage_update", "cost":{"amount":0.125}}}})
            finish(request)
        elif scenario == "hang":
            send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"s1", "update":{"sessionUpdate":"tool_call", "title":"等待取消", "status":"in_progress"}}})
        else:
            content = request["params"]["prompt"]
            images = [item for item in content if item["type"] == "image"]
            if images and (images[0].get("mimeType") != "image/png" or not images[0].get("data")):
                send({"jsonrpc":"2.0", "id":request["id"], "error":{"code":-32602,"message":"Invalid image"}})
            else:
                finish(request)
    elif method == "session/cancel" and pending_prompt:
        finish(pending_prompt, "", "cancelled")
    elif request.get("id") == "permission-7" and pending_prompt:
        outcome = request["result"]["outcome"]
        finish(pending_prompt, outcome.get("optionId", "cancelled"))
    elif method:
        result(request, {})
