"""
Gideon tool layer.

Every tool returns a ToolResult dict:
    {
        "summary": str,          # text fed back to the model for synthesis
        "files":   [FileRef],    # optional structured items the UI renders as clickable
        "action":  str | None,   # optional UI directive, e.g. "prompt_user"
        "command": str | None,   # payload for that directive
    }

Keeping a single shape means the orchestrator can always forward `summary`
to the LLM and `files`/`action` straight to the Quickshell sidebar.
"""

import os
import re
import shutil
import subprocess
from datetime import datetime, timezone

import fitz  # PyMuPDF
from docx import Document
from duckduckgo_search import DDGS

HOME = os.path.expanduser("~")

# Noisy / huge dirs we never want to walk during file search — caches,
# build artifacts, and browser profile asset stores (full of junk PNGs etc.).
_NOISE_DIRS = (".cache", ".local/share/Trash", "node_modules", ".git",
               ".venv", "venv", "__pycache__", ".rustup", ".cargo",
               "Cache", "Code Cache", "GPUCache", "Service Worker",
               "Extensions", ".mozilla", "Crashpad")


def _nested_mounts(root):
    """Mountpoints that live *under* `root` (e.g. big data drives mounted in HOME)."""
    found = []
    try:
        with open("/proc/mounts") as f:
            for line in f:
                parts = line.split()
                if len(parts) < 2:
                    continue
                mp = parts[1].replace("\\040", " ")
                if mp != root and mp.startswith(root.rstrip("/") + "/"):
                    found.append(mp)
    except OSError:
        pass
    return found


def _fd_excludes(root):
    """Build `fd --exclude` args so searches stay fast and bounded to one drive."""
    args = []
    for mp in _nested_mounts(root):
        args += ["--exclude", os.path.basename(mp.rstrip("/")) or mp]
    for d in _NOISE_DIRS:
        args += ["--exclude", d]
    return args


# --------------------------------------------------------------------------- #
# Result helpers
# --------------------------------------------------------------------------- #
def result(summary, files=None, action=None, command=None):
    return {
        "summary": summary,
        "files": files or [],
        "action": action,
        "command": command,
    }


def _human_size(num):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if num < 1024 or unit == "TB":
            return f"{num:.0f}{unit}" if unit == "B" else f"{num:.1f}{unit}"
        num /= 1024


def _file_ref(path):
    """Build a structured, clickable reference for one filesystem path."""
    try:
        st = os.stat(path)
        mtime = datetime.fromtimestamp(st.st_mtime, timezone.utc).astimezone()
        return {
            "path": os.path.abspath(path),
            "name": os.path.basename(path.rstrip("/")) or path,
            "dir": os.path.dirname(os.path.abspath(path)),
            "size": _human_size(st.st_size),
            "mtime": mtime.strftime("%Y-%m-%d %H:%M"),
            "mtime_ts": st.st_mtime,
            "is_dir": os.path.isdir(path),
        }
    except OSError:
        return {"path": path, "name": os.path.basename(path), "dir": "",
                "size": "", "mtime": "", "mtime_ts": 0, "is_dir": False}


def _run(cmd, timeout=15):
    """Run an argv list, return (stdout, stderr, rc). Never raises."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.stdout, p.stderr, p.returncode
    except FileNotFoundError:
        return "", f"{cmd[0]}: not installed", 127
    except subprocess.TimeoutExpired:
        return "", f"{cmd[0]}: timed out after {timeout}s", 124
    except Exception as e:  # noqa: BLE001
        return "", str(e), 1


# --------------------------------------------------------------------------- #
# App launching
# --------------------------------------------------------------------------- #
def execute_app(app_name: str):
    out, err, rc = _run(["hyprctl", "dispatch", "exec", app_name], timeout=5)
    if rc != 0:
        return result(f"Failed to launch {app_name}: {err or out}")
    return result(f"Launched {app_name}.")


# --------------------------------------------------------------------------- #
# File discovery (by name / recency)  ->  clickable results
# --------------------------------------------------------------------------- #
_RECENT_RE = re.compile(r"\brecent(?:ly)?\b|\blatest\b|\blast\b", re.I)
_COUNT_RE = re.compile(r"\b(\d+)\b")


def find_files(spec: str):
    """
    Locate files by name. Understands natural phrases such as:
        "recent 5 resumes"  -> 5 newest files matching 'resume'
        "~/Documents/*.pdf" -> glob in a directory
        "screenshot"        -> anything named *screenshot*
    Returns structured, clickable file refs sorted newest-first.
    """
    raw = spec.strip()
    want_recent = bool(_RECENT_RE.search(raw))
    count_match = _COUNT_RE.search(raw)
    limit = int(count_match.group(1)) if count_match else 20

    # strip control words to leave the actual search term
    term = _RECENT_RE.sub(" ", raw)
    term = _COUNT_RE.sub(" ", term)
    for w in ("file", "files", "find", "show", "me", "my", "named", "called", "the"):
        term = re.sub(rf"\b{w}\b", " ", term, flags=re.I)
    term = term.strip()

    # crude plural -> stem so "resumes" matches "resume.pdf"
    if term.endswith("s") and len(term) > 3 and "." not in term and "/" not in term:
        term = term[:-1]

    search_dir = HOME
    pattern = term
    if "/" in term:
        expanded = os.path.expanduser(term)
        d = os.path.dirname(expanded)
        if os.path.isdir(d):
            search_dir = d
        pattern = os.path.basename(expanded)

    pattern = pattern.replace("*", "").strip()
    base = ["fd", "-H", "-t", "f"] + _fd_excludes(search_dir)
    # A bare extension word ("pdf", "mp4") should match by extension, not substring.
    _EXTS = {"pdf", "docx", "doc", "txt", "md", "odt", "csv", "xlsx", "pptx",
             "png", "jpg", "jpeg", "gif", "svg", "webp", "mp4", "mkv", "mp3",
             "zip", "tar", "gz", "iso", "py", "rs", "js", "ts", "json"}
    if pattern.lower() in _EXTS:
        cmd = base + ["-e", pattern.lower(), ".", search_dir]
    elif not pattern:
        cmd = base + [".", search_dir]
    else:
        cmd = base + [pattern, search_dir]

    out, err, rc = _run(cmd, timeout=20)
    if err and rc not in (0,):
        return result(f"File search error: {err}")

    paths = [p for p in out.splitlines() if p.strip()]
    refs = [_file_ref(p) for p in paths]
    refs.sort(key=lambda r: r["mtime_ts"], reverse=True)  # newest first
    refs = refs[:limit]

    if not refs:
        return result(f"No files matching '{pattern}' under {search_dir}.")

    label = "most recent" if want_recent else "matching"
    lines = [f"- {r['name']}  ({r['size']}, {r['mtime']})  {r['path']}" for r in refs]
    summary = f"Found {len(refs)} {label} file(s) for '{pattern}':\n" + "\n".join(lines)
    return result(summary, files=refs)


def grep_files(spec: str):
    """
    Content search: 'word in ~/Documents' -> files containing that word.
    Returns clickable file refs.
    """
    m = re.search(r"^(.*?)\s+in\s+(.+)$", spec.strip(), re.I)
    if m:
        word = m.group(1).strip()
        where = [os.path.expanduser(m.group(2).strip())]
    else:
        word = spec.strip().strip("'\"")
        # default to the user's document folders — full-HOME content scan is too slow
        where = [d for d in (os.path.join(HOME, x)
                             for x in ("Documents", "Downloads", "Desktop"))
                 if os.path.isdir(d)] or [HOME]
    where = [w for w in where if os.path.exists(w)] or [HOME]

    word = word.strip("'\"")
    # -l: files with matches, -i: case-insensitive, --no-messages: skip perm errors
    glob_excludes = []
    for mp in _nested_mounts(where[0]):
        glob_excludes += ["-g", f"!{os.path.basename(mp.rstrip('/'))}/**"]
    for d in _NOISE_DIRS:
        glob_excludes += ["-g", f"!**/{d}/**"]
    out, err, rc = _run(
        ["rg", "-l", "-i", "--no-messages", "--max-count", "1",
         "--max-filesize", "8M", "--threads", "4",
         *glob_excludes, word, *where],
        timeout=25,
    )
    paths = [p for p in out.splitlines() if p.strip()][:25]
    if not paths:
        return result(f"No files containing '{word}' found under {where}.")
    refs = [_file_ref(p) for p in paths]
    refs.sort(key=lambda r: r["mtime_ts"], reverse=True)
    lines = [f"- {r['name']}  ({r['mtime']})  {r['path']}" for r in refs]
    summary = f"Found {len(refs)} file(s) containing '{word}':\n" + "\n".join(lines)
    return result(summary, files=refs)


def open_path(path: str):
    """Open a file/dir with the desktop default handler (used by UI clicks)."""
    path = os.path.expanduser(path.strip())
    if not os.path.exists(path):
        return result(f"Path not found: {path}")
    subprocess.Popen(["xdg-open", path],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result(f"Opened {path}.")


def extract_text(file_path: str):
    file_path = os.path.expanduser(file_path.strip())
    if not os.path.exists(file_path):
        return result(f"File not found: {file_path}")
    ext = os.path.splitext(file_path)[1].lower()
    try:
        if ext == ".pdf":
            doc = fitz.open(file_path)
            text = "".join(page.get_text() for page in doc)
        elif ext == ".docx":
            doc = Document(file_path)
            text = "\n".join(p.text for p in doc.paragraphs)
        else:
            with open(file_path, "r", errors="ignore") as f:
                text = f.read(8000)
    except Exception as e:  # noqa: BLE001
        return result(f"Extraction error: {e}")
    return result(f"Contents of {os.path.basename(file_path)}:\n{text[:6000]}",
                  files=[_file_ref(file_path)])


# --------------------------------------------------------------------------- #
# Web-augmented research
# --------------------------------------------------------------------------- #
def online_search(query: str):
    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, max_results=8, safesearch="off"))
    except Exception as e:  # noqa: BLE001
        return result(f"Online search error: {e}")
    if not results:
        return result("No online results found.")
    out = "\n".join(
        f"Title: {r.get('title','')}\nURL: {r.get('href','')}\nSnippet: {r.get('body','')}\n"
        for r in results
    )
    return result(out)


def fetch_url(url: str):
    """Fetch a page and return its readable text (for reading wiki/forum pages)."""
    url = url.strip()
    if not url.startswith(("http://", "https://")):
        url = "https://" + url
    try:
        import primp  # browser-impersonating client (ships with duckduckgo_search)
        client = primp.Client(impersonate="chrome_131", timeout=20)
        resp = client.get(url)
        html = resp.text
    except Exception as e:  # noqa: BLE001
        return result(f"Fetch error for {url}: {e}")
    try:
        import lxml.html
        tree = lxml.html.fromstring(html)
        for bad in tree.xpath("//script | //style | //nav | //footer | //header"):
            bad.getparent().remove(bad)
        text = " ".join(tree.text_content().split())
    except Exception:  # noqa: BLE001
        text = re.sub(r"<[^>]+>", " ", html)
        text = " ".join(text.split())
    # A near-empty extraction means the page is JS-rendered or login-gated; the
    # static fetch can't see the real content. Tell the model so it falls back
    # to online_search snippets instead of inventing data.
    if len(text) < 200:
        return result(
            f"{url} returned little readable text — it is likely JavaScript-rendered "
            f"or login-gated, so a static fetch can't read it. Use online_search "
            f"snippets for this kind of live/dynamic data instead. "
            f"Partial text: {text or '(none)'}"
        )
    return result(f"Readable content of {url}:\n{text[:6000]}")


# --------------------------------------------------------------------------- #
# Log / error forensics  (Arch + systemd)
# --------------------------------------------------------------------------- #
def read_logs(spec: str):
    """
    Forensic log inspection via journalctl (no sudo needed for the journal group).
    Spec keywords:
        'errors'         -> priority error+ since last boot
        'kernel'         -> kernel ring buffer (journalctl -k)
        'boot'           -> this boot's messages
        'failed'         -> failed systemd units
        '<unit>'         -> logs for a specific unit/service
    """
    s = spec.strip().lower()

    if "failed" in s:
        out, err, rc = _run(["systemctl", "--failed", "--no-legend", "--no-pager"])
        body = out.strip() or "No failed units."
        return result(f"Failed systemd units:\n{body}")

    if "kernel" in s or "dmesg" in s:
        out, err, rc = _run(["journalctl", "-k", "-p", "warning", "-b",
                             "--no-pager", "-n", "60"])
        return result(f"Kernel warnings/errors (this boot):\n{out[-5000:] or err}")

    if "boot" in s and "error" not in s:
        out, err, rc = _run(["journalctl", "-b", "--no-pager", "-n", "80"])
        return result(f"Recent messages this boot:\n{out[-5000:] or err}")

    # specific unit?  e.g. "NetworkManager" / "bluetooth.service"
    m = re.search(r"([\w.@-]+\.(?:service|socket|timer|target))", spec)
    if m:
        unit = m.group(1)
        out, err, rc = _run(["journalctl", "-u", unit, "--no-pager", "-n", "60"])
        return result(f"Logs for {unit}:\n{out[-5000:] or err or 'no entries'}")

    # default: recent errors across the system, this boot
    out, err, rc = _run(["journalctl", "-p", "err", "-b", "--no-pager", "-n", "80"])
    body = out.strip() or "No error-priority messages this boot."
    return result(f"System errors (priority err+, this boot):\n{body[-5000:]}")


# --------------------------------------------------------------------------- #
# System introspection
# --------------------------------------------------------------------------- #
def system_query(spec: str):
    """
    Inspect Arch/system state. Keywords:
        'disk'/'space'     -> df
        'memory'/'ram'     -> free
        'updates'          -> pacman -Qu (available upgrades)
        'recent packages'  -> last installed/upgraded packages from pacman log
        'gpu'              -> nvidia-smi summary
        'package <name>'   -> pacman -Qi <name>
        'who owns <path>'  -> pacman -Qo <path>
    """
    s = spec.strip().lower()

    if "disk" in s or "space" in s:
        out, _, _ = _run(["df", "-h", "-x", "tmpfs", "-x", "devtmpfs"])
        return result(f"Disk usage:\n{out}")

    if "memory" in s or "ram" in s:
        out, _, _ = _run(["free", "-h"])
        return result(f"Memory:\n{out}")

    if "gpu" in s or "vram" in s or "nvidia" in s:
        out, err, _ = _run(["nvidia-smi"])
        return result(f"GPU status:\n{out or err}")

    if "update" in s or "upgrade" in s:
        out, _, _ = _run(["pacman", "-Qu"])
        n = len([l for l in out.splitlines() if l.strip()])
        return result(f"{n} package update(s) available:\n{out or 'System up to date.'}")

    if "recent" in s and ("package" in s or "install" in s):
        log = "/var/log/pacman.log"
        if not os.path.exists(log):
            return result("pacman log not found.")
        with open(log, errors="ignore") as f:
            lines = [l for l in f if "installed" in l or "upgraded" in l]
        return result("Recent package activity:\n" + "".join(lines[-25:]))

    m = re.search(r"owns?\s+(\S+)", s)
    if m:
        out, err, _ = _run(["pacman", "-Qo", os.path.expanduser(m.group(1))])
        return result(out or err)

    m = re.search(r"package\s+(\S+)", s)
    if m:
        out, err, _ = _run(["pacman", "-Qi", m.group(1)])
        return result(out or f"Package '{m.group(1)}' not installed: {err}")

    # default snapshot
    df, _, _ = _run(["df", "-h", "/"])
    mem, _, _ = _run(["free", "-h"])
    return result(f"System snapshot.\nRoot disk:\n{df}\nMemory:\n{mem}")


# --------------------------------------------------------------------------- #
# Gated terminal execution
# --------------------------------------------------------------------------- #
_DANGEROUS = [
    r"\bsudo\b", r"\bdoas\b", r"\bsu\b",
    r"\brm\s+-[rf]{1,2}\b", r"\bmkfs\b", r"\bdd\b",
    r">\s*/dev/sd", r":\(\)\s*\{", r"\bshutdown\b", r"\breboot\b",
    r"\bpacman\b.*-R", r"\bchmod\s+-R\b",
]


def execute_terminal_command(command: str):
    for pat in _DANGEROUS:
        if re.search(pat, command):
            # hand off to the user for explicit confirmation
            return result(
                f"Command requires your confirmation: {command}",
                action="prompt_user",
                command=command,
            )
    out, err, rc = _run(["bash", "-lc", command], timeout=20)
    body = out or err or "Command executed with no output."
    return result(body[:3000])


def run_command_confirmed(command: str):
    """
    Actually run a command the user has explicitly confirmed (the EXECUTE button
    in the UI). The danger gate already surfaced it; clicking is the consent, so
    we run it regardless. Returns combined output + exit code.
    """
    out, err, rc = _run(["bash", "-lc", command], timeout=60)
    body = (out or "")
    if err:
        body += ("\n" if body else "") + err
    return {
        "command": command,
        "returncode": rc,
        "output": (body or "(no output)")[:6000],
    }


# --------------------------------------------------------------------------- #
# Dispatch
# --------------------------------------------------------------------------- #
TOOLS = {
    "execute_app": execute_app,
    "find_files": find_files,
    "grep_files": grep_files,
    "open_path": open_path,
    "extract_text": extract_text,
    "online_search": online_search,
    "fetch_url": fetch_url,
    "read_logs": read_logs,
    "system_query": system_query,
    "execute_terminal_command": execute_terminal_command,
}

# Format A — the instructed protocol:  <action name='tool'>arg</action>
_ACTION_RE = re.compile(
    r"<action\s+name=[\"']([^\"']+)[\"']\s*>(.*?)</action>",
    re.S | re.I,
)
# Format B — the model's own trained syntax, which it falls back to:
#   <|tool_call>call name='tool' argument='arg' action='tool'
# (also matches the bare `name=... argument=...` variant on a line).
_TOOLCALL_RE = re.compile(
    r"name=[\"']([^\"']+)[\"']\s+argument=[\"'](.*?)[\"']\s*(?=action=|name=|$)",
    re.S | re.I | re.M,
)
# Format C — the model names the tool as the tag itself:  <tool_name>arg</tool_name>
# GLM falls back to this. Restricted to known tool names so we never capture
# unrelated markup like <think> or stray HTML.
_NAMED_TAG_RE = re.compile(
    r"<(" + "|".join(map(re.escape, TOOLS)) + r")\s*>(.*?)</\1\s*>",
    re.S | re.I,
)


def parse_tool_calls(model_output: str):
    """
    Return [(tool_name, argument)] for every tool call, tolerant of both the
    instructed <action> tags and the model's native <|tool_call> fallback.
    Order is preserved; duplicates collapsed.
    """
    seen = set()
    calls = []
    for rx in (_ACTION_RE, _TOOLCALL_RE, _NAMED_TAG_RE):
        for m in rx.finditer(model_output):
            name = m.group(1).strip()
            arg = m.group(2).strip()
            if name in TOOLS and (name, arg) not in seen:
                seen.add((name, arg))
                calls.append((name, arg))
    return calls


def execute_tool(name: str, argument: str):
    fn = TOOLS.get(name)
    if not fn:
        return result(f"Unknown tool: {name}")
    return fn(argument)


# Backwards-compatible single-call helper (old main.py entrypoint).
def parse_and_execute_tool(model_output: str):
    calls = parse_tool_calls(model_output)
    if not calls:
        return None
    name, arg = calls[0]
    return execute_tool(name, arg)
