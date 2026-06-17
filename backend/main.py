"""
Gideon orchestrator.

FastAPI service that drives a local llama-server (OpenAI-compatible) through a
multi-step tool-calling loop:

    user prompt
      -> LLM emits zero or more <action name='tool'>arg</action> tags
      -> we run every tool, feed results back
      -> repeat until the model answers with no tags (or MAX_STEPS hit)

Inference runs in llama-server so VRAM/offload/KV-quant are tuned at the
binary launch (see gideon-serve.sh), not here. This process is a thin,
dependency-light coordinator.
"""

import json
import os
import urllib.request
import urllib.error

from fastapi import FastAPI
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel

import re

import tools
import server_manager

# Signature that tells a tool-call turn apart from a plain answer, early.
# Covers all three call shapes the parser accepts: <action ...>, the native
# <|tool_call name=...> fallback, and GLM's bare <tool_name> named tags.
_TOOLSIG = re.compile(
    r"<action|<\|tool_call|name=[\"']|</?(?:"
    + "|".join(map(re.escape, tools.TOOLS)) + r")\b",
    re.I,
)

# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #
LLAMA_SERVER = os.environ.get("GIDEON_LLAMA_URL", "http://127.0.0.1:8080")
MODEL_NAME = os.environ.get("GIDEON_MODEL", "gideon")  # llama-server alias
MAX_STEPS = int(os.environ.get("GIDEON_MAX_STEPS", "4"))
TEMPERATURE = float(os.environ.get("GIDEON_TEMP", "0.2"))

SYSTEM_PROMPT = (
    "You are Gideon, a local assistant running on an Arch Linux / Hyprland laptop. "
    "You help with the system, files, troubleshooting, and forensic investigation of errors.\n\n"
    "TOOLS — call one or more by emitting tags exactly like:\n"
    "  <action name='tool_name'>argument</action>\n"
    "Available tools:\n"
    "  execute_app           - launch a GUI app, arg = app name (e.g. firefox)\n"
    "  find_files            - locate files by name/recency, arg = phrase (e.g. 'recent 5 resumes', '*.pdf')\n"
    "  grep_files            - find files containing text, arg = 'word' or 'word in ~/Documents'\n"
    "  open_path             - open a file/folder in its default app, arg = path\n"
    "  extract_text          - read a PDF/DOCX/text file, arg = path\n"
    "  online_search         - web search for latest info, arg = query\n"
    "  fetch_url             - read the text of a web page, arg = URL\n"
    "  read_logs             - inspect logs: 'errors', 'kernel', 'failed', or a unit name\n"
    "  system_query          - inspect system: 'disk', 'memory', 'gpu', 'updates', 'recent packages', 'package <name>'\n"
    "  execute_terminal_command - run a shell command (dangerous ones require user confirmation)\n\n"
    "WORKFLOW:\n"
    "- Use tools to gather facts before answering. You may issue several tags in one turn.\n"
    "- For investigating errors/crashes: read_logs first, then online_search/fetch_url for current fixes.\n"
    "- For prices, stock, news or other fast-changing/real-time data, rely on online_search "
    "snippets. Use fetch_url only for stable articles, wikis, docs or forum threads — many "
    "sites are JavaScript-rendered or login-gated and a static fetch returns nothing.\n"
    "- When you have enough information, reply with a concise answer and NO action tags.\n"
    "- Reference files by name; the UI makes them clickable for the user.\n"
    "- Be direct and practical. Prefer recent, verified information over assumptions."
)


# --------------------------------------------------------------------------- #
# llama-server client
# --------------------------------------------------------------------------- #
def chat_completion(messages):
    """Single blocking call to llama-server's OpenAI-compatible endpoint."""
    payload = json.dumps({
        "model": MODEL_NAME,
        "messages": messages,
        "temperature": TEMPERATURE,
        "stream": False,
    }).encode()
    req = urllib.request.Request(
        f"{LLAMA_SERVER}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.loads(resp.read())
    return data["choices"][0]["message"]["content"]


def stream_completion(messages):
    """
    Yield (kind, text) pairs from llama-server's streaming endpoint, where kind
    is "content" (the answer) or "reasoning" (the model's thinking, when the
    server splits it into a reasoning_content delta).
    """
    payload = json.dumps({
        "model": MODEL_NAME,
        "messages": messages,
        "temperature": TEMPERATURE,
        "stream": True,
    }).encode()
    req = urllib.request.Request(
        f"{LLAMA_SERVER}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    resp = urllib.request.urlopen(req, timeout=120)
    for raw in resp:
        line = raw.decode("utf-8", "ignore").strip()
        if not line.startswith("data:"):
            continue
        chunk = line[5:].strip()
        if chunk == "[DONE]":
            break
        try:
            delta = json.loads(chunk)["choices"][0]["delta"]
        except (json.JSONDecodeError, KeyError, IndexError):
            continue
        reasoning = delta.get("reasoning_content")
        if reasoning:
            yield ("reasoning", reasoning)
        content = delta.get("content")
        if content:
            yield ("content", content)


# --------------------------------------------------------------------------- #
# Session
# --------------------------------------------------------------------------- #
class SessionManager:
    def __init__(self, system_prompt):
        self.system_prompt = system_prompt
        self.clear()

    def add(self, role, content):
        self.history.append({"role": role, "content": content})
        if len(self.history) > 21:  # system + last 20
            self.history = [self.history[0]] + self.history[-20:]

    def messages(self):
        return self.history

    def clear(self):
        self.history = [{"role": "system", "content": self.system_prompt}]


session = SessionManager(SYSTEM_PROMPT)


# --------------------------------------------------------------------------- #
# Agent loop
# --------------------------------------------------------------------------- #
def run_agent(user_prompt):
    """Drive the tool-calling loop. Returns a UI payload dict."""
    session.add("user", user_prompt)
    collected_files = []

    for _ in range(MAX_STEPS):
        answer = chat_completion(session.messages())
        calls = tools.parse_tool_calls(answer)

        if not calls:
            session.add("assistant", answer)
            return {"response": answer, "files": collected_files}

        # Run every requested tool this turn.
        session.add("assistant", answer)
        observations = []
        for name, arg in calls:
            res = tools.execute_tool(name, arg)
            # A tool may demand explicit user confirmation (dangerous command).
            if res.get("action") == "prompt_user":
                return {"action": "prompt_user", "command": res["command"],
                        "response": res["summary"], "files": collected_files}
            collected_files.extend(res.get("files") or [])
            observations.append(f"[{name}] {res['summary']}")

        session.add("user", "TOOL_RESULTS:\n" + "\n\n".join(observations))

    # Ran out of steps — ask for a final answer without more tools.
    session.add("user", "Now give your final answer to the user, with no action tags.")
    answer = chat_completion(session.messages())
    session.add("assistant", answer)
    return {"response": answer, "files": collected_files}


def _split_think(s):
    """Separate inline <think>...</think> reasoning from the answer text.
    Tolerates an unclosed <think> mid-stream (rest is treated as thinking)."""
    answer, think = [], []
    i = 0
    while True:
        start = s.find("<think>", i)
        if start == -1:
            answer.append(s[i:])
            break
        answer.append(s[i:start])
        end = s.find("</think>", start)
        if end == -1:
            think.append(s[start + 7:])
            break
        think.append(s[start + 7:end])
        i = end + 8
    return "".join(answer), "".join(think)


def run_agent_stream(user_prompt):
    """
    Generator yielding event dicts for the streaming UI:
        {"type": "status",   "tool": ...}   a tool is running
        {"type": "files",    "files": [..]} clickable results
        {"type": "thinking", "text": ...}   model reasoning (GLM thinking mode)
        {"type": "token",    "text": ...}   a chunk of the final answer
        {"type": "action",   ...}           dangerous command needs confirmation
        {"type": "stats",    "tok_s": ...}  generation speed for the answer
        {"type": "done"}                    finished
    Tool-call turns are consumed silently (surfaced as status), only the final
    natural-language answer is streamed token-by-token.
    """
    import time
    session.add("user", user_prompt)

    t_start = None
    tok_count = 0

    for _ in range(MAX_STEPS):
        content_raw = ""        # all answer-channel content this turn
        sent_answer = 0         # answer chars already streamed to UI
        sent_think = 0          # thinking chars already streamed
        answer_head = ""        # accumulates answer for the tool/answer decision
        is_tool = None

        for kind, text in stream_completion(session.messages()):
            if kind == "reasoning":
                yield {"type": "thinking", "text": text}
                continue

            content_raw += text
            answer_text, think_text = _split_think(content_raw)

            if len(think_text) > sent_think:
                yield {"type": "thinking", "text": think_text[sent_think:]}
                sent_think = len(think_text)

            new_answer = answer_text[sent_answer:]
            if not new_answer:
                continue
            sent_answer = len(answer_text)

            if is_tool is None:
                answer_head += new_answer
                if len(answer_head) >= 40:
                    is_tool = bool(_TOOLSIG.search(answer_head))
                    if not is_tool:
                        if t_start is None:
                            t_start = time.time()
                        tok_count += 1
                        yield {"type": "token", "text": answer_head}
            elif is_tool is False:
                if t_start is None:
                    t_start = time.time()
                tok_count += 1
                yield {"type": "token", "text": new_answer}

        answer_text, _ = _split_think(content_raw)

        # Short turn that never crossed the 40-char decision threshold.
        if is_tool is None:
            is_tool = bool(_TOOLSIG.search(answer_text))
            if not is_tool and answer_text[sent_answer:]:
                yield {"type": "token", "text": answer_text[sent_answer:]}

        session.add("assistant", answer_text or content_raw)

        if not is_tool:
            if t_start and tok_count:
                dt = time.time() - t_start
                if dt > 0:
                    yield {"type": "stats", "tok_s": round(tok_count / dt, 1)}
            yield {"type": "done"}
            return

        # Tool-call turn: run them, stream status/files, feed results back.
        observations = []
        for name, arg in tools.parse_tool_calls(answer_text):
            yield {"type": "status", "tool": name, "arg": arg}
            res = tools.execute_tool(name, arg)
            if res.get("action") == "prompt_user":
                yield {"type": "action", "command": res["command"],
                       "response": res["summary"]}
                return
            if res.get("files"):
                yield {"type": "files", "files": res["files"]}
            observations.append(f"[{name}] {res['summary']}")
        session.add("user", "TOOL_RESULTS:\n" + "\n\n".join(observations))

    # Out of steps — stream a forced final answer.
    session.add("user", "Now give your final answer to the user, with no action tags.")
    final_raw = ""
    final_sent = 0
    for kind, text in stream_completion(session.messages()):
        if kind == "reasoning":
            yield {"type": "thinking", "text": text}
            continue
        final_raw += text
        ans, _ = _split_think(final_raw)
        if len(ans) > final_sent:
            if t_start is None:
                t_start = time.time()
            tok_count += 1
            yield {"type": "token", "text": ans[final_sent:]}
            final_sent = len(ans)
    ans, _ = _split_think(final_raw)
    session.add("assistant", ans or final_raw)
    if t_start and tok_count:
        dt = time.time() - t_start
        if dt > 0:
            yield {"type": "stats", "tok_s": round(tok_count / dt, 1)}
    yield {"type": "done"}


# --------------------------------------------------------------------------- #
# API
# --------------------------------------------------------------------------- #
app = FastAPI()


class ChatRequest(BaseModel):
    prompt: str


@app.post("/api/chat")
def chat_endpoint(request: ChatRequest):
    try:
        return run_agent(request.prompt)
    except urllib.error.URLError as e:
        return JSONResponse(status_code=503,
                            content={"response": f"llama-server unreachable at {LLAMA_SERVER}: {e}"})
    except Exception as e:  # noqa: BLE001
        print(f"Backend error: {e}")
        return JSONResponse(status_code=500, content={"response": f"Error: {e}"})


@app.post("/api/chat/stream")
def chat_stream_endpoint(request: ChatRequest):
    def gen():
        try:
            for event in run_agent_stream(request.prompt):
                yield json.dumps(event) + "\n"
        except urllib.error.URLError as e:
            yield json.dumps({"type": "error",
                              "message": f"llama-server unreachable: {e}"}) + "\n"
        except Exception as e:  # noqa: BLE001
            yield json.dumps({"type": "error", "message": str(e)}) + "\n"
    return StreamingResponse(gen(), media_type="application/x-ndjson")


@app.post("/api/open")
def open_endpoint(request: ChatRequest):
    """UI calls this when a file chip is clicked; arg is the path."""
    return tools.open_path(request.prompt)


@app.post("/api/clear")
def clear_endpoint():
    session.clear()
    return {"status": "cleared"}


# --------------------------------------------------------------------------- #
# Settings: models, live usage, capacity estimate, server control
# --------------------------------------------------------------------------- #
class ConfigRequest(BaseModel):
    config: dict


@app.get("/api/models")
def models_endpoint():
    return {"models": server_manager.list_models(),
            "current": server_manager.load_config(),
            "models_dir": server_manager.models_dir()}


class ModelsDirRequest(BaseModel):
    path: str


@app.post("/api/models_dir")
def set_models_dir_endpoint(request: ModelsDirRequest):
    result = server_manager.set_models_dir(request.path)
    return JSONResponse(status_code=200 if result.get("ok") else 400,
                        content=result)


@app.get("/api/system/info")
def system_info_endpoint():
    return server_manager.system_info()


@app.post("/api/estimate")
def estimate_endpoint(request: ConfigRequest):
    return server_manager.estimate(request.config)


@app.post("/api/server/restart")
def restart_endpoint(request: ConfigRequest):
    result = server_manager.restart_server(request.config)
    return JSONResponse(status_code=200 if result.get("ok") else 503,
                        content=result)


@app.get("/api/server/status")
def server_status_endpoint():
    return server_manager.server_status()


class StartRequest(BaseModel):
    config: dict | None = None


@app.post("/api/server/start")
def server_start_endpoint(request: StartRequest):
    result = server_manager.start_server(request.config)
    return JSONResponse(status_code=200 if result.get("ok") else 503,
                        content=result)


@app.post("/api/server/stop")
def server_stop_endpoint():
    killed = server_manager.stop_server()
    return {"ok": True, "killed": killed,
            "message": "Server stopped." if killed else "No server was running."}


class CommandRequest(BaseModel):
    command: str


@app.post("/api/execute")
def execute_endpoint(request: CommandRequest):
    """Run a command the user explicitly confirmed via the EXECUTE button."""
    return tools.run_command_confirmed(request.command)


@app.get("/api/health")
def health():
    try:
        urllib.request.urlopen(f"{LLAMA_SERVER}/health", timeout=3)
        return {"backend": "ok", "llama_server": "ok"}
    except Exception:  # noqa: BLE001
        return {"backend": "ok", "llama_server": "down"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000)
