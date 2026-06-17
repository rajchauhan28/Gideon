"""
Gideon llama-server lifecycle + capacity estimation.

The settings tab in the UI needs to (a) list installed models, (b) show live
VRAM/RAM usage with an estimate for a *pending* config plus an OOM warning, and
(c) actually apply a new config by relaunching llama-server. This module owns all
of that so main.py stays a thin coordinator.

VRAM/RAM numbers are a HEURISTIC, calibrated against two measured points on an
RTX 4050 Laptop (6 GB):
    Gemma E4B Q5_K_M, full GPU offload, ctx 8192  -> ~4.1 GB VRAM
    GLM-4.7-Flash IQ4_XS, --n-cpu-moe 38, ctx 8192 -> ~3.9 GB VRAM / ~8 GB RAM
They are labelled "estimated" in the UI for exactly this reason.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Built-in fallback only. The active GGUF directory is user-configurable: it is
# saved in gideon_config.json (set from the Settings tab) and resolved by
# models_dir(); $GIDEON_MODELS_DIR overrides everything for one-off launches.
DEFAULT_MODELS_DIR = os.path.expanduser(
    os.environ.get("GIDEON_MODELS_DIR", "~/models"))
CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gideon_config.json")
SERVER_LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "llama-server.log")
PORT = int(os.environ.get("GIDEON_LLAMA_PORT", "8080"))

# Heuristic constants (see module docstring).
_TURBO_COMPRESSION = 0.72          # turboquant load-time weight shrink vs disk
_EXPERT_FRACTION = 0.78            # share of MoE weight that lives in experts
_SAFETY_GB = 0.4                   # VRAM headroom to leave for the desktop
# bytes/element for KV cache quant types (approximate)
_KV_BYTES = {"f16": 2.0, "f32": 4.0, "q8_0": 1.06, "q4_0": 0.56, "q4_1": 0.63,
             "turbo2": 0.90, "turbo3": 0.70, "turbo4": 0.55}
_KV_BASELINE = _KV_BYTES["q8_0"] + _KV_BYTES["turbo4"]   # calibration baseline

# Per-model metadata: layer count + whether it is a MoE (has CPU-offloadable
# experts). Keyed by a substring of the filename. Estimates fall back to these.
_MODEL_META = [
    ("Gemma",        {"layers": 35, "moe": False}),
    ("GLM-4.7",      {"layers": 46, "moe": True}),
    ("GLM-4",        {"layers": 46, "moe": True}),
    ("Qwen3.6-35B",  {"layers": 48, "moe": True}),
    ("Qwen",         {"layers": 48, "moe": True}),
]

DEFAULT_CONFIG = {
    "models_dir": DEFAULT_MODELS_DIR,
    "model_path": "",          # chosen in the Settings tab (first model found)
    "ctx": 8192,
    "kv_k": "q8_0",
    "kv_v": "turbo4",
    "n_cpu_moe": 38,
    "ngl": 99,
    "flash_attn": True,
    "mlock": False,
    "no_mmap": False,
}


# --------------------------------------------------------------------------- #
# Models directory resolution
# --------------------------------------------------------------------------- #
def models_dir():
    """The directory Gideon scans for GGUF models.

    Precedence: $GIDEON_MODELS_DIR (hard override) > saved config > built-in
    default. Always returned with ``~`` expanded.
    """
    env = os.environ.get("GIDEON_MODELS_DIR")
    if env:
        return os.path.expanduser(env)
    return os.path.expanduser(load_config().get("models_dir") or DEFAULT_MODELS_DIR)


def set_models_dir(path):
    """Persist a new GGUF directory and return the refreshed model list."""
    path = os.path.expanduser((path or "").strip())
    if not path:
        return {"ok": False, "error": "Empty path."}
    if not os.path.isdir(path):
        return {"ok": False, "error": f"Not a directory: {path}"}
    save_config({"models_dir": path})
    return {"ok": True, "models_dir": path, "models": list_models()}


# --------------------------------------------------------------------------- #
# Model discovery + metadata
# --------------------------------------------------------------------------- #
def _meta_for(path):
    name = os.path.basename(path)
    for key, meta in _MODEL_META:
        if key.lower() in name.lower():
            return meta
    return {"layers": 40, "moe": False}


def _human(nbytes):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if nbytes < 1024 or unit == "TB":
            return f"{nbytes:.0f} {unit}" if unit == "B" else f"{nbytes:.1f} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} TB"


def list_models():
    """Installed *.gguf models (in the configured directory) with size + metadata."""
    out = []
    mdir = models_dir()
    try:
        for fn in sorted(os.listdir(mdir)):
            if not fn.endswith(".gguf"):
                continue
            path = os.path.join(mdir, fn)
            size = os.path.getsize(path)
            meta = _meta_for(path)
            out.append({
                "name": fn,
                "path": path,
                "size_bytes": size,
                "size_human": _human(size),
                "layers": meta["layers"],
                "moe": meta["moe"],
            })
    except OSError:
        pass
    return out


# --------------------------------------------------------------------------- #
# Live system usage
# --------------------------------------------------------------------------- #
def _gpu_usage():
    """(total, used, free) VRAM in MiB via nvidia-smi; zeros if unavailable."""
    if not shutil.which("nvidia-smi"):
        return (0, 0, 0)
    try:
        out = subprocess.run(
            ["nvidia-smi",
             "--query-gpu=memory.total,memory.used,memory.free",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=4,
        ).stdout.strip().splitlines()[0]
        total, used, free = (int(x.strip()) for x in out.split(","))
        return (total, used, free)
    except Exception:  # noqa: BLE001
        return (0, 0, 0)


def _ram_usage():
    """(total, used, available) RAM in MiB from /proc/meminfo."""
    info = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                k, _, v = line.partition(":")
                info[k] = int(v.strip().split()[0])  # kB
    except OSError:
        return (0, 0, 0)
    total = info.get("MemTotal", 0) // 1024
    avail = info.get("MemAvailable", 0) // 1024
    return (total, total - avail, avail)


def system_info():
    gt, gu, gf = _gpu_usage()
    rt, ru, ra = _ram_usage()
    return {
        "vram_total_mb": gt, "vram_used_mb": gu, "vram_free_mb": gf,
        "ram_total_mb": rt, "ram_used_mb": ru, "ram_avail_mb": ra,
    }


# --------------------------------------------------------------------------- #
# Capacity estimate for a pending config
# --------------------------------------------------------------------------- #
def estimate(cfg):
    """
    Rough VRAM/RAM footprint of llama-server for `cfg`, plus OOM verdicts.
    Returns MB values so the UI can draw bars directly.
    """
    path = cfg.get("model_path", "")
    try:
        disk_gb = os.path.getsize(path) / (1024 ** 3)
    except OSError:
        disk_gb = 0.0
    meta = _meta_for(path)
    layers = max(1, meta["layers"])
    moe = meta["moe"]
    ctx = int(cfg.get("ctx", 8192))
    n_cpu_moe = int(cfg.get("n_cpu_moe", 0))
    ngl = int(cfg.get("ngl", 99))

    full_vram_gb = disk_gb * _TURBO_COMPRESSION   # if every weight on GPU

    if moe and n_cpu_moe > 0:
        offloaded = min(n_cpu_moe, layers) / layers
        gpu_weights = full_vram_gb * (1 - _EXPERT_FRACTION * offloaded)
        ram_weights = disk_gb * _EXPERT_FRACTION * offloaded
    else:
        gpu_frac = min(ngl, layers) / layers if not moe else 1.0
        gpu_weights = full_vram_gb * gpu_frac
        ram_weights = disk_gb * (1 - gpu_frac)

    # KV cache: scale a per-layer-per-1k baseline by ctx and the chosen quant.
    kv_factor = (_KV_BYTES.get(cfg.get("kv_k", "q8_0"), 1.06)
                 + _KV_BYTES.get(cfg.get("kv_v", "turbo4"), 0.55)) / _KV_BASELINE
    kv_gb = layers * 0.0016 * (ctx / 1024.0) * kv_factor

    # Compute/CUDA context + activation overhead.
    overhead_gb = 0.45

    vram_gb = gpu_weights + kv_gb + overhead_gb
    ram_gb = ram_weights + 0.3            # process + buffers

    sysinfo = system_info()
    vram_total_gb = sysinfo["vram_total_mb"] / 1024 or 6.0
    ram_total_gb = sysinfo["ram_total_mb"] / 1024 or 16.0

    vram_oom = vram_gb + _SAFETY_GB > vram_total_gb
    ram_oom = ram_gb > ram_total_gb * 0.9

    return {
        "vram_est_mb": round(vram_gb * 1024),
        "ram_est_mb": round(ram_gb * 1024),
        "vram_total_mb": sysinfo["vram_total_mb"],
        "ram_total_mb": sysinfo["ram_total_mb"],
        "vram_oom": vram_oom,
        "ram_oom": ram_oom,
        "breakdown": {
            "gpu_weights_mb": round(gpu_weights * 1024),
            "kv_cache_mb": round(kv_gb * 1024),
            "overhead_mb": round(overhead_gb * 1024),
            "ram_weights_mb": round(ram_weights * 1024),
        },
    }


# --------------------------------------------------------------------------- #
# Config persistence
# --------------------------------------------------------------------------- #
def load_config():
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH) as f:
                cfg = json.load(f)
            return {**DEFAULT_CONFIG, **cfg}
        except (OSError, json.JSONDecodeError):
            pass
    return dict(DEFAULT_CONFIG)


def save_config(cfg):
    merged = {**load_config(), **cfg}
    with open(CONFIG_PATH, "w") as f:
        json.dump(merged, f, indent=2)
    return merged


# --------------------------------------------------------------------------- #
# Server process control
# --------------------------------------------------------------------------- #
def _find_binary():
    for c in (os.environ.get("LLAMA_SERVER_BIN", ""),
              shutil.which("llama-server"),
              os.path.join(ROOT, "llama-cpp-turboquant/build/bin/llama-server"),
              os.path.join(ROOT, "llama-cpp-turboquant/build/llama-server")):
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def _pids_on_port(port):
    try:
        out = subprocess.run(["ss", "-ltnp"], capture_output=True, text=True, timeout=4).stdout
    except Exception:  # noqa: BLE001
        return []
    pids = set()
    for line in out.splitlines():
        if f"127.0.0.1:{port}" in line or f"0.0.0.0:{port}" in line or f":::{port}" in line:
            pids.update(re.findall(r"pid=(\d+)", line))
    return [int(p) for p in pids]


def stop_server(port=PORT):
    killed = []
    for pid in _pids_on_port(port):
        try:
            os.kill(pid, signal.SIGTERM)
            killed.append(pid)
        except ProcessLookupError:
            pass
    # give them a moment, then SIGKILL stragglers
    if killed:
        time.sleep(1.5)
        for pid in _pids_on_port(port):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    return killed


def _build_args(binary, cfg, port):
    path = cfg.get("model_path", DEFAULT_CONFIG["model_path"])
    meta = _meta_for(path)
    args = [
        binary,
        "--model", path,
        "--alias", "gideon",
        "--host", "127.0.0.1", "--port", str(port),
        "--ctx-size", str(int(cfg.get("ctx", 8192))),
        "--cache-type-k", cfg.get("kv_k", "q8_0"),
        "--cache-type-v", cfg.get("kv_v", "turbo4"),
        "--flash-attn", "on" if cfg.get("flash_attn", True) else "off",
        "--no-webui",
    ]
    if meta["moe"] and int(cfg.get("n_cpu_moe", 0)) > 0:
        args += ["--n-gpu-layers", "99",
                 "--n-cpu-moe", str(int(cfg["n_cpu_moe"]))]
    else:
        args += ["--n-gpu-layers", str(int(cfg.get("ngl", 99)))]
    if cfg.get("mlock"):
        args.append("--mlock")
    if cfg.get("no_mmap"):
        args.append("--no-mmap")
    return args


def _health_now(port=PORT):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
            return r.status == 200
    except Exception:  # noqa: BLE001
        return False


def server_running(port=PORT):
    return len(_pids_on_port(port)) > 0


def server_status(port=PORT):
    """Is llama-server up, and which model is loaded (per saved config)."""
    running = server_running(port)
    cfg = load_config()
    return {
        "running": running,
        "healthy": _health_now(port) if running else False,
        "model": os.path.basename(cfg.get("model_path", "")) if running else None,
        "config": cfg,
    }


def _health_ok(port, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
                if r.status == 200:
                    return True
        except Exception:  # noqa: BLE001
            time.sleep(1.0)
    return False


def restart_server(cfg, port=PORT, wait=90):
    """Stop any server on `port`, launch llama-server with `cfg`, wait for health."""
    binary = _find_binary()
    if not binary:
        return {"ok": False, "error": "llama-server binary not found "
                "(build it or set LLAMA_SERVER_BIN)."}
    if not os.path.isfile(cfg.get("model_path", "")):
        return {"ok": False, "error": f"Model not found: {cfg.get('model_path')}"}

    save_config(cfg)
    stop_server(port)
    args = _build_args(binary, cfg, port)
    try:
        logf = open(SERVER_LOG, "ab")
        subprocess.Popen(args, stdout=logf, stderr=logf,
                         start_new_session=True)
    except OSError as e:
        return {"ok": False, "error": f"Failed to launch: {e}"}

    if _health_ok(port, wait):
        return {"ok": True, "message": "Server restarted.",
                "command": " ".join(args)}
    return {"ok": False, "error": f"Server did not become healthy within {wait}s. "
            f"Check {SERVER_LOG}.", "command": " ".join(args)}


def start_server(cfg=None, port=PORT, wait=90):
    """Start llama-server, falling back to the saved config for anything missing.

    The power toggle sends the live UI config, which is empty (``model_path: ""``)
    until the Settings tab has populated it. Merging over the saved config and
    dropping empty/None values means a blank or partial config still starts the
    last-known-good model, while a deliberately-changed field is still honored.
    """
    merged = load_config()
    if cfg:
        merged.update({k: v for k, v in cfg.items() if v not in (None, "")})
    return restart_server(merged, port=port, wait=wait)
