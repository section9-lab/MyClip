import json
import re
import os
import sys
import uuid
import time

scenario = os.environ.get("MYCLIP_ACP_SCENARIO", "success")
pending_prompt = None
prompt_count = 0
conversation_file = os.environ.get("MYCLIP_ACP_CONVERSATIONS")
conversations = {}
ephemeral_sessions = set()
if conversation_file and os.path.exists(conversation_file):
    with open(conversation_file) as saved:
        conversations = json.load(saved)

def save_conversations():
    with open(conversation_file, "w") as saved:
        json.dump({key: value for key, value in conversations.items() if key not in ephemeral_sessions}, saved)

def send(value):
    data = (json.dumps(value, ensure_ascii=False) + "\n").encode("utf-8")
    # Exercise framing across partial writes, including multibyte text.
    os.write(sys.stdout.fileno(), data[:9])
    os.write(sys.stdout.fileno(), data[9:])

def result(request, value):
    send({"jsonrpc": "2.0", "id": request["id"], "result": value})

def finish(request, text="你好，已整理", reason="end_turn", **extra):
    send({"jsonrpc":"2.0", "method":"session/update", "params":{
        "sessionId":request["params"].get("sessionId", "s1"), "update":{"sessionUpdate":"agent_message_chunk", "content":{"type":"text", "text":text}}
    }})
    result(request, {"stopReason":reason, **extra})

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
            options = request.get("params", {}).get("_meta", {}).get("claudeCode", {}).get("options", {})
            if options.get("persistSession") is False or os.path.basename(os.environ.get("CODEX_PATH", "")) == "codex-ephemeral.cjs":
                ephemeral_sessions.add(session)
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
        prompt_count += 1
        if conversation_file:
            session = request["params"]["sessionId"]
            conversations[session].append(request["params"]["prompt"][0]["text"])
            save_conversations()
            if scenario == "conversation_delayed":
                time.sleep(0.5)
            finish(request, "|".join(conversations[session]))
            continue
        if scenario == "crash":
            print("fixture disconnected", file=sys.stderr, flush=True)
            sys.exit(7)
        pending_prompt = request
        if scenario == "slow_progress":
            updates = [
                {"sessionUpdate":"tool_call", "toolCallId":"compact", "title":"Compact conversation", "status":"in_progress"},
                {"sessionUpdate":"tool_call_update", "toolCallId":"compact", "status":"completed"},
                {"sessionUpdate":"agent_thought_chunk", "content":{"type":"text","text":"organizing"}},
                {"sessionUpdate":"agent_message_chunk", "content":{"type":"text","text":"working:"}},
            ]
            for update in updates:
                send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"s1", "update":update}})
                time.sleep(0.3)
            finish(request, "done")
        elif scenario in ("other_session_progress", "metadata_progress", "continuous_progress"):
            for _ in range(12):
                session = "other-session" if scenario == "other_session_progress" else "s1"
                update = {"sessionUpdate":"usage_update", "used":100} if scenario == "metadata_progress" else {"sessionUpdate":"agent_thought_chunk", "content":{"type":"text","text":"working"}}
                send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":session, "update":update}})
                time.sleep(0.2)
            finish(request)
        elif scenario in ("permission", "permission_choices", "permission_always", "permission_unavailable"):
            options = [{"optionId":"allow1", "name":"允许一次", "kind":"allow_once"}, {"optionId":"reject1", "name":"拒绝", "kind":"reject_once"}]
            if scenario == "permission_choices":
                options.insert(0, {"optionId":"always7", "name":"允许并保存规则", "kind":"allow_always"})
            elif scenario == "permission_always":
                options = [{"optionId":"always7", "name":"始终允许", "kind":"allow_always"}]
            elif scenario == "permission_unavailable":
                options = [{"optionId":"unknown", "name":"Yes", "kind":"unknown"}, {"optionId":"reject1", "name":"拒绝", "kind":"reject_once"}]
            send({"jsonrpc":"2.0", "id":"permission-7", "method":"session/request_permission", "params":{
                "sessionId":"s1", "toolCall":{"toolCallId":"tool1", "title":"查看来源"},
                "options":options
            }})
        elif scenario == "permission_after_cancel":
            send({"jsonrpc":"2.0", "method":"session/update", "params":{
                "sessionId":"s1", "update":{"sessionUpdate":"tool_call", "toolCallId":"tool1", "title":"等待取消", "status":"pending"}
            }})
        elif scenario == "knowledge":
            text = request["params"]["prompt"][0]["text"]
            source = re.search(r"sourceID=([0-9A-Fa-f-]{36})", text).group(1)
            finish(request, json.dumps({"entries":[{"kind":"wiki", "title":"聚焦窗口", "body":"回车触发应用截图。", "sourceIDs":[source]}]}, ensure_ascii=False))
        elif scenario == "float_metadata":
            send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"s1", "update":{"sessionUpdate":"usage_update", "cost":{"amount":0.125}}}})
            finish(request)
        elif scenario == "usage":
            finish(request, usage={"totalTokens":120 * prompt_count, "inputTokens":70 * prompt_count,
                "outputTokens":30 * prompt_count, "cachedReadTokens":20 * prompt_count, "thoughtTokens":10 * prompt_count})
        elif scenario == "quota_usage":
            finish(request, _meta={"quota":{"token_count":{"totalTokens":120,"inputTokens":90,
                "outputTokens":30,"cachedInputTokens":20,"reasoningOutputTokens":10}}})
        elif scenario in ("cumulative_cost", "cost_gaps"):
            costs = [(0.125, "USD"), None, (0.5, "USD"), (0.6, "EUR"), (0.2, "EUR")]
            cost = costs[prompt_count - 1] if scenario == "cost_gaps" else (prompt_count * 0.125, "USD")
            if cost:
                send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":request["params"]["sessionId"],
                    "update":{"sessionUpdate":"usage_update", "used":100, "size":200000,
                              "cost":{"amount":cost[0], "currency":cost[1]}}}})
            finish(request)
        elif scenario in ("tool_details", "execution_details", "execution_failure"):
            updates = [
                {"sessionUpdate":"tool_call", "toolCallId":"read-1", "name":"shell", "title":"cat Memory/notes.md",
                 "kind":"execute", "status":"in_progress", "rawInput":{"command":"cat Memory/notes.md"},
                 "locations":[{"path":"/workspace/Memory/notes.md", "line":3}]},
                {"sessionUpdate":"tool_call_update", "toolCallId":"read-1", "status":"completed",
                 "rawInput":None, "rawOutput":{"exitCode":0},
                 "content":[{"type":"content","content":{"type":"text","text":"Stored notes"}}]},
            ]
            for update in updates:
                send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"s1", "update":update}})
            if scenario == "tool_details":
                finish(request)
                continue
            send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"s1", "update":{
                "sessionUpdate":"tool_call", "toolCallId":"edit-1", "title":"Edit notes", "kind":"edit", "status":"completed",
                "content":[{"type":"diff", "path":"/workspace/Memory/notes.md", "oldText":"Before", "newText":"After"}]}}})
            send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"other", "update":{
                "sessionUpdate":"tool_call", "toolCallId":"wrong-session", "title":"Unrelated tool"}}})
            for _ in range(2):
                send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"s1", "update":{
                    "sessionUpdate":"usage_update", "used":100, "size":200000, "cost":{"amount":prompt_count * 0.125,"currency":"USD"}}}})
            if scenario == "execution_failure":
                send({"jsonrpc":"2.0", "id":request["id"], "error":{"code":-32000,"message":"Fixture failed after editing"}})
            else:
                finish(request, usage={"totalTokens":20,"inputTokens":10,"outputTokens":5,"cachedWriteTokens":5})
        elif scenario == "model_usage":
            counts = [{"model":"main", "token_count":{"totalTokens":120,"inputTokens":70,"outputTokens":30,"cachedInputTokens":20}},
                      {"model":"subagent", "token_count":{"totalTokens":50,"inputTokens":20,"outputTokens":10,"cachedInputTokens":15,"cachedWriteTokens":5}}]
            finish(request, usage={"totalTokens":120,"inputTokens":70,"outputTokens":30}, _meta={"quota":{"model_usage":counts}})
        elif scenario == "invalid_model_usage":
            finish(request, usage={"totalTokens":15,"inputTokens":10,"outputTokens":5}, _meta={"quota":{"model_usage":[{"token_count":{"totalTokens":999}}]}})
        elif scenario == "invalid_usage":
            values = [{"totalTokens":-1,"inputTokens":1,"outputTokens":2},
                      {"totalTokens":1.5,"inputTokens":1,"outputTokens":2},
                      {"totalTokens":3,"inputTokens":True,"outputTokens":2}, None]
            finish(request, usage=values[(prompt_count - 1) % len(values)])
        elif scenario == "context_usage":
            send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"s1", "update":{"sessionUpdate":"usage_update", "used":90000,"size":200000,"cost":{"amount":0.125}}}})
            finish(request)
        elif scenario == "thinking":
            send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"s1", "update":{"sessionUpdate":"agent_thought_chunk", "content":{"type":"text","text":"thinking"}}}})
            finish(request)
        elif scenario in ("hang", "cancel_usage"):
            send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"s1", "update":{"sessionUpdate":"tool_call", "toolCallId":"waiting", "title":"等待取消", "status":"in_progress"}}})
        else:
            content = request["params"]["prompt"]
            images = [item for item in content if item["type"] == "image"]
            if images and (images[0].get("mimeType") != "image/png" or not images[0].get("data")):
                send({"jsonrpc":"2.0", "id":request["id"], "error":{"code":-32602,"message":"Invalid image"}})
            else:
                finish(request)
    elif method == "session/cancel" and pending_prompt:
        if scenario == "permission_after_cancel":
            send({"jsonrpc":"2.0", "id":"permission-7", "method":"session/request_permission", "params":{
                "sessionId":"s1", "toolCall":{"toolCallId":"tool1", "title":"迟到的授权请求"},
                "options":[{"optionId":"allow1", "name":"允许一次", "kind":"allow_once"}]
            }})
            continue
        extra = {"usage":{"totalTokens":12,"inputTokens":10,"outputTokens":2}} if scenario == "cancel_usage" else {}
        finish(pending_prompt, "", "cancelled", **extra)
    elif request.get("id") == "permission-7" and pending_prompt:
        outcome = request["result"]["outcome"]
        finish(pending_prompt, outcome.get("optionId", "cancelled"))
    elif method:
        result(request, {})
