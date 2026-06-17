# Gideon

> *Named for Sir Gideon Ofnir, the All-Knowing, of the Lands Between — he who
> hoarded every secret that the world would yield. So too does this servant keep
> vigil over thy machine, that no log, no file, nor folly upon it stay hidden
> from thee.*

A local, tool-calling AI assistant for **Arch Linux + Hyprland**, built to run
entirely on-device on a 6 GB-VRAM laptop. Gideon lives in a slide-out Quickshell
sidebar, drives a local `llama-server` through a multi-step agent loop, and can
actually *do* things on your machine — search files, read documents, inspect
logs and system state, run gated shell commands, and pull live answers off the
web.

No cloud. No API keys. The model, the tools, and the UI all run on your laptop.

---

## Highlights

- **Runs on tiny VRAM.** Tuned for an RTX 4050 Laptop (6 GB). MoE models keep
  attention on the GPU and offload experts to CPU RAM (`--n-cpu-moe`); dense
  models full-offload via TurboQuant weight compression. Both leave ~2 GB free
  for the desktop.
- **Agentic tool loop.** The model emits `<action name='tool'>arg</action>`
  tags; the backend runs every tool, feeds results back, and repeats until the
  model answers — up to `GIDEON_MAX_STEPS` rounds.
- **Streaming UI with thinking.** Tokens, tool-status chips, clickable file
  results, model reasoning (GLM thinking mode), and tokens/sec all stream live
  into the sidebar.
- **In-UI model management.** A Settings tab lists installed GGUFs, shows live
  VRAM/RAM usage with an OOM-aware capacity estimate for a *pending* config, and
  starts/stops/swaps `llama-server` on demand — the GPU stays free until you
  turn it on.
- **Safety-gated execution.** Dangerous commands (`sudo`, `rm -rf`, `dd`,
  `mkfs`, `pacman -R`, …) are never auto-run; they surface an EXECUTE button for
  explicit user confirmation.

---

## Architecture

```
┌─────────────────────────┐        ┌──────────────────────────┐
│  Quickshell sidebar      │  HTTP  │  FastAPI orchestrator     │
│  frontend/shell.qml      │◄──────►│  backend/main.py          │
│  (chat, settings, files) │  :8000 │  • agent / tool loop      │
└─────────────────────────┘        │  • streaming (ndjson)     │
                                    │  • session memory         │
                                    └──────────┬───────────────┘
                                               │ OpenAI-compatible
                                               │ /v1/chat/completions
                                               ▼  :8080
                                    ┌──────────────────────────┐
                                    │  llama-server (TurboQuant │
                                    │  + CUDA)                  │
                                    │  managed by               │
                                    │  server_manager.py        │
                                    └──────────────────────────┘
```

| Path | Role |
|------|------|
| `backend/main.py` | FastAPI app + the agent loop (blocking and streaming). Thin coordinator — no model loading happens here. |
| `backend/tools.py` | The tool layer. Every tool returns a uniform `{summary, files, action, command}` result. |
| `backend/server_manager.py` | `llama-server` lifecycle (start/stop/restart), model discovery, and a heuristic VRAM/RAM capacity estimator. |
| `backend/gideon_config.json` | Per-machine launch config (models dir, model, ctx, KV-quant, offload). Written by the Settings tab; git-ignored — see `gideon_config.example.json`. |
| `frontend/shell.qml` | The entire Quickshell UI: edge handle, chat, settings, file chips. |
| `gideon-serve.sh` | Launch `llama-server` directly from a CLI with a `glm`/`gemma` profile. |
| `bench-offload.sh` | Sweep `--n-gpu-layers` to find the largest GPU offload that still leaves VRAM headroom. |
| `hypr-gideon.conf` | Hyprland `exec-once` + `SUPER+G` toggle keybind. |
| `systemd/gideon-backend.service` | Run the backend as a user service. |

### Tools available to the model

| Tool | What it does |
|------|--------------|
| `execute_app` | Launch a GUI app via `hyprctl dispatch exec`. |
| `find_files` | Locate files by name/recency (`fd`), e.g. *"recent 5 resumes"*. |
| `grep_files` | Find files containing text (`ripgrep`). |
| `open_path` | Open a file/folder in its default app (`xdg-open`). |
| `extract_text` | Read a PDF / DOCX / text file. |
| `online_search` | DuckDuckGo web search for live info. |
| `fetch_url` | Fetch and extract readable text from a page. |
| `read_logs` | Forensic `journalctl`/`systemctl` log inspection. |
| `system_query` | Disk, memory, GPU, pacman updates/packages. |
| `execute_terminal_command` | Run a shell command — dangerous ones require confirmation. |

---

## Requirements

**System (Arch Linux):**
- [Hyprland](https://hyprland.org/) + [Quickshell](https://quickshell.org/) (`qs`)
- An NVIDIA GPU with CUDA (developed on RTX 4050 Laptop, 6 GB) — `nvidia-smi`
- CLI tools the tool layer shells out to: `fd`, `ripgrep` (`rg`), `xdg-utils`
  (`xdg-open`), `systemd` (`journalctl`/`systemctl`), `pacman`, `iproute2`
  (`ss`), and coreutils (`df`, `free`).
- Python **3.14**

**Inference engine — TurboQuant llama.cpp fork.**
Gideon uses the asymmetric TurboQuant KV-cache ladder (`turbo2`/`turbo3`/`turbo4`),
so it needs the fork rather than upstream llama.cpp. Clone and build it
**separately** (it is intentionally *not* vendored here):

```bash
git clone https://github.com/TheTom/llama-cpp-turboquant.git
cd llama-cpp-turboquant
cmake -B build -DGGML_CUDA=ON
cmake --build build --config Release -j
```

Gideon finds the binary via `$LLAMA_SERVER_BIN`, your `$PATH`, or
`./llama-cpp-turboquant/build/bin/llama-server`.

**Models.** Place GGUF files in any folder — you choose where. Set the **Models
folder** in the Settings tab (type the path and hit **Scan**) and Gideon reads
every `*.gguf` from there; the choice is saved to `gideon_config.json`. The
default is `~/models`, and `$GIDEON_MODELS_DIR` overrides it for one-off
launches. Two profiles are tuned out of the box:

| Profile | Model | Offload | VRAM | Speed | Notes |
|---------|-------|---------|------|-------|-------|
| `glm` *(recommended)* | GLM-4.7-Flash-REAP-23B-A3B IQ4_XS | `--n-cpu-moe 38` | ~3.9 GB | ~25 tok/s | Strong reasoning + clean tool-calling. |
| `gemma` | Gemma E4B Q5_K_M | full GPU offload | ~4.1 GB | ~43 tok/s | Faster; weaker reasoning. |

---

## Setup

```bash
git clone <your-repo-url> Gideon
cd Gideon

# 1. Python backend
python -m venv env
env/bin/pip install -r backend/requirements.txt

# 2. Build the inference engine (see Requirements above)
#    -> llama-cpp-turboquant/build/bin/llama-server

# 3. Drop GGUF models into your models dir and set GIDEON_MODELS_DIR if needed.
```

---

## Running

**Backend** (lightweight; does *not* load the model):

```bash
env/bin/python -m uvicorn main:app --host 127.0.0.1 --port 8000   # from backend/
# or install the user service:
cp systemd/gideon-backend.service ~/.config/systemd/user/
systemctl --user enable --now gideon-backend
```

**Frontend** — add to your Hyprland config and reload:

```ini
source = /path/to/Gideon/hypr-gideon.conf
```

This auto-starts the sidebar on login and binds **`SUPER+G`** to toggle it.
Click the left-edge handle (or hit the keybind), then start the model from the
**Settings** tab — or launch `llama-server` directly:

```bash
./gideon-serve.sh glm      # or: gemma
```

---

## Configuration

Most behavior is environment-driven; defaults match the 6 GB-VRAM target.

| Variable | Default | Used by | Meaning |
|----------|---------|---------|---------|
| `GIDEON_LLAMA_URL` | `http://127.0.0.1:8080` | backend | llama-server endpoint |
| `GIDEON_MODEL` | `gideon` | backend | model alias |
| `GIDEON_MAX_STEPS` | `4` | backend | max tool-loop rounds |
| `GIDEON_TEMP` | `0.2` | backend | sampling temperature |
| `GIDEON_MODELS_DIR` | `~/models` | server_manager | GGUF search dir (overrides the Settings-tab value) |
| `GIDEON_LLAMA_PORT` | `8080` | server_manager | llama-server port |
| `LLAMA_SERVER_BIN` | *(auto-detected)* | server_manager / serve | path to `llama-server` |
| `PORT` `CTX` `KV_K` `KV_V` `NGL` `N_CPU_MOE` `GIDEON_PROFILE` | see script | `gideon-serve.sh` | direct launch overrides |

> **Note on hard-coded paths.** A few files were written for the author's
> machine and contain absolute paths (`/home/reign/ddrive/GenAI/...` in the
> systemd unit, `hypr-gideon.conf`, and the config/default model paths). Adjust
> them to your setup, or override via the environment variables above.

---

## How the agent loop works

```
user prompt
  → llama-server emits zero or more <action name='tool'>arg</action> tags
  → backend runs every tool this turn, appends TOOL_RESULTS to the session
  → repeat until the model answers with no tags  (or GIDEON_MAX_STEPS hit)
```

The parser is tolerant of three call shapes — the instructed `<action>` tags,
the model's native `<|tool_call …>` fallback, and GLM's bare `<tool_name>` tags
— so different models work without prompt surgery. The streaming endpoint
distinguishes a tool-call turn from a real answer within the first ~40
characters, so only genuine answer text is streamed token-by-token.

---

## A note on the VRAM estimator

`server_manager.estimate()` is a **heuristic**, calibrated against two measured
points on an RTX 4050 (6 GB) — Gemma E4B Q5_K_M full-offload (~4.1 GB) and
GLM-4.7-Flash IQ4_XS `--n-cpu-moe 38` (~3.9 GB / ~8 GB RAM). Numbers are
labelled "estimated" in the UI for that reason; treat the OOM warnings as
guidance, not a guarantee.

---

## License

GPL-3.0. See [LICENSE](LICENSE).

The TurboQuant llama.cpp fork is a separate project under its own (MIT) license.
