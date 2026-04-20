# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A self-hosted LLM stack running **Gemma 4 31B** on an RTX 4090, exposed as an OpenAI-compatible API with per-key quotas and usage tracking, reachable publicly over HTTPS via Cloudflare Tunnel. **Not a git repo** — treat it as a personal ops project.

Three layers, each a separate Docker container, wired together:

```
cloudflared  ──►  litellm (:4000)  ──►  llama.cpp server (:8080)  ──►  RTX 4090
(tunnel egress)    (auth/quotas)         (host, not the gateway net)   (Gemma Q4_K_XL)
                        │
                   postgres (keys, logs, usage)
```

LiteLLM reaches llama.cpp via `http://host.docker.internal:8080` because the llama.cpp container is on the default bridge network, while the gateway stack has its own `llama-gateway_gateway` bridge. Don't try to put them on the same network unless you restart the llama.cpp container.

## Layout

- `README.md` — operator/admin-facing. How to set up, run, and maintain the stack.
- `CLAUDE.md` — this file.
- `EXAMPLE.md` — client-facing. Inlined code snippets for curl/Node/Python/opencode/Continue/Open WebUI/shell. Uses `LLM_API_KEY` from env only; no key file in the repo.
- `llama.sh` — sourced into zsh; defines `llama`, `llama-status`, `llama-stop`, `llama-logs`, `llama-bench-api`, `llama-bench-native`. Manages the llama.cpp Docker container.
- `gateway/` — LiteLLM proxy stack. `docker-compose.yml` declares `postgres` + `litellm` + (optional) `cloudflared` under a `tunnel` profile. Secrets in `gateway/.env` only.
- `install-docker.sh` — one-shot installer for Docker Engine + NVIDIA Container Toolkit on Ubuntu 25.10. Falls back to the `noble` repo since Docker doesn't publish `questing` packages yet.

## Common commands

```bash
# Inference
llama "prompt"                          # starts container if needed, streams response
llama-status                            # running / starting / stopped
llama-stop                              # frees VRAM (24 GB)
llama-logs                              # docker logs -f on the server

# Bench
llama-bench-api                         # via /completion on running server
llama-bench-native                      # stops server, runs official llama-bench

# Gateway
cd gateway && ./setup.sh                # idempotent: generates .env on first run
docker compose ps                       # state
docker compose logs -f litellm          # proxy logs
docker compose --profile tunnel up -d   # add cloudflared
docker compose --profile tunnel down    # stop everything including tunnel
```

## Non-obvious things that bit us (don't re-debug)

- **llama.cpp `-fa` now requires a value.** It's `-fa on` / `-fa off` / `-fa auto`, not the bare flag. Bare `-fa` makes the next arg (`-c 32768`) look like the value and the server refuses to start. Same change applies to `llama-bench` (uses `-fa 1`).

- **Gemma 4 31B Q4_K_XL on a 24 GB GPU OOMs without `--parallel 1`.** llama.cpp server defaults to `--parallel 4`, which quadruples the KV cache. At `-c 32768`, KV cache alone asks for ~6 GB; model weights are ~18 GB → total hits the ceiling. Keep `--parallel 1` in `_llama_start_container`.

- **Host RAM OOM is a real risk even with `-ngl 99`.** Observed in practice: the container's anon-rss climbed to ~56 GB over a few hours of use (CUDA pinned memory and CUDA_Host buffers grow with request volume). On a 64 GB box that triggers the kernel OOM killer → `exit 137`. Mitigations in place: `--restart unless-stopped` (auto-respawn after OOM) and `--memory 48g` via `LLAMA_MEMORY` (container dies inside its own cgroup before dragging the host down). If these kick in regularly, lower `LLAMA_CTX` or raise `LLAMA_MEMORY` — not both.

- **`--rm` on the server container hides startup errors.** The container is removed on exit, so `docker logs llama-server` after a crash returns "No such container". To debug a startup failure, re-run the same `docker run` command in the foreground (no `-d`, no `--rm`). See the `_llama_start_container` function for the exact args.

- **`llama-bench` binary isn't in PATH inside the `:full-cuda` image.** It lives at `/app/llama-bench`. The Docker invocation uses `--entrypoint /app/llama-bench` — do not shorten to `llama-bench`.

- **Container config drift is detected via a `llama.config-hash` label.** `_llama_ensure_up` compares the running container's label against `_llama_config_hash` of the current env vars (MODEL_PATH + IMAGE + CTX + NGL + PORT). If they differ, it auto-restarts. Flags hardcoded in the `docker run` line (`-fa on`, `--gpus all`, `--parallel 1`) are NOT in the hash — if you make them env-configurable, extend the hash.

- **zsh arrays are 1-indexed, bash is 0-indexed.** `_llama_wait_ready` detects `$ZSH_VERSION` and offsets the spinner frame index accordingly. Don't assume one or the other.

- **Concurrent `llama` calls from two shells use `flock` on `/tmp/llama-server.$UID.lock`.** Only the "ensure up" phase is serialized; inference runs freely once the server is ready. fd 9, not 200 (zsh choked on high fd numbers).

- **The `cloudflared` image is distroless.** No shell, no `nslookup`, no `wget`. Debug connectivity from a throwaway `curlimages/curl` container joined to the `llama-gateway_gateway` network.

- **Cloudflare Bot Fight Mode 403's the OpenAI SDK.** It flags the `OpenAI/JS` / `OpenAI/Python` User-Agent as a bot and returns a 403 body of literally `Your request was blocked.`. Fix: WAF → Custom Rules → Skip (managed rules + BFM + Browser Integrity Check) when `Hostname equals llm.at-tech.cloud`. Examples default to `localhost:4000` to avoid the issue for local scripts.

- **MCP servers spawned by Claude Code don't inherit the interactive shell PATH.** The chrome-devtools-mcp plugin uses `npx`, which lives in `~/.nvm/...` — absent from the minimal env Claude uses to launch MCP servers. Symptom: "Failed to reconnect to plugin". Fix: use the absolute path in settings.json, or install node globally in a system PATH.

## Where secrets live

- `gateway/.env` — chmod 600. Postgres password, LiteLLM master key + salt, UI password, tunnel token. Generated once by `setup.sh`; do not regenerate, that orphans existing user keys (they're encrypted with `LITELLM_SALT_KEY`).
- **User API keys are never stored in the repo.** They're issued via `/key/generate` and the receiver puts them in their own env (`export LLM_API_KEY=...`). If a user loses their key, regenerate — don't try to recover.
- This repo isn't under git today; if it ever is, add `gateway/.env` and `gateway/data/` to `.gitignore` first.

## Making changes

- Editing `llama.sh` — the script is `source`d from `~/.zshrc`. After changes, either `source ~/.zshrc` in open shells or open a new one. Run `bash -n` AND `zsh -n` for syntax — the script runs under zsh but the shebang is bash.
- Editing `gateway/config/litellm.yaml` — mounted read-only into the container. Restart with `docker compose restart litellm` for changes to take effect.
- Editing `gateway/docker-compose.yml` — `docker compose up -d` picks up changes (recreates the affected services only).
- Adding a new backend model to LiteLLM — add to `model_list` in `litellm.yaml` and restart. Keys with `models: [...]` restrictions won't see the new model unless listed there.

## Performance ceiling for reference

On the RTX 4090 with this model+quant combo, `llama-bench-native` reports steady-state numbers around **pp512 ≈ 2940 tok/s** and **tg128 ≈ 42 tok/s** (average of 3 runs). Anything materially below this after a change means the change broke something (e.g., model fell back to CPU, FA disabled, wrong quant loaded).

## Things that look wrong but aren't

- `_llama_is_ready` probes `/health` on the llama.cpp server, but `llama-status` reports "running" only if that endpoint returns 200. A container that's up but still loading the model shows "starting", which is intentional.
- `docker logs --since 2m cloudflared` returning empty is not a bug — cloudflared logs connection lifecycle, not per-request traffic. To confirm traffic, hit the endpoint and watch `litellm` logs instead.
- The `short` bench run reports `gen_tok/s = 1000000` — it's a divide-by-near-zero artifact because the model stops immediately on a 2-word prompt. Ignore the short row; `medium`/`long` are the real numbers.
