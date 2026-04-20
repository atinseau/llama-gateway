#!/usr/bin/env bash
# Source this file: `source ~/Documents/llama/llama.sh`
# Then use: `llama "your prompt"`

LLAMA_CONTAINER_NAME="${LLAMA_CONTAINER_NAME:-llama-server}"
LLAMA_MODEL_PATH="${LLAMA_MODEL_PATH:-$HOME/models/gemma4/gemma-4-31B-it-UD-Q4_K_XL.gguf}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_IMAGE="${LLAMA_IMAGE:-ghcr.io/ggml-org/llama.cpp:server-cuda}"
LLAMA_CTX="${LLAMA_CTX:-32768}"
LLAMA_NGL="${LLAMA_NGL:-99}"
LLAMA_STARTUP_TIMEOUT="${LLAMA_STARTUP_TIMEOUT:-300}"

_llama_endpoint() { echo "http://localhost:${LLAMA_PORT}"; }

_llama_is_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$LLAMA_CONTAINER_NAME"
}

_llama_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$LLAMA_CONTAINER_NAME"
}

_llama_is_ready() {
    curl -sf -o /dev/null "$(_llama_endpoint)/health" 2>/dev/null
}

# Short hash of the config that would be used to start the container.
# Used to detect stale config on a running container.
# Note: hardcoded flags in _llama_start_container (-fa, --gpus all) are NOT
# hashed. If they become env-configurable, add them here too.
_llama_config_hash() {
    printf '%s|%s|%s|%s|%s' \
        "$LLAMA_MODEL_PATH" "$LLAMA_IMAGE" "$LLAMA_CTX" "$LLAMA_NGL" "$LLAMA_PORT" \
        | sha1sum | cut -c1-12
}

_llama_running_hash() {
    docker inspect --format '{{index .Config.Labels "llama.config-hash"}}' \
        "$LLAMA_CONTAINER_NAME" 2>/dev/null
}

# Remove a stopped/zombie container with our name (no-op if running or absent).
_llama_cleanup_stale() {
    if _llama_exists && ! _llama_is_running; then
        docker rm -f "$LLAMA_CONTAINER_NAME" >/dev/null 2>&1
    fi
}

_llama_start_container() {
    if [[ ! -f "$LLAMA_MODEL_PATH" ]]; then
        printf '\033[31m✗\033[0m Model not found: %s\n' "$LLAMA_MODEL_PATH" >&2
        printf '  Set LLAMA_MODEL_PATH or download a GGUF first.\n' >&2
        return 1
    fi

    local model_dir model_file
    model_dir="$(dirname "$LLAMA_MODEL_PATH")"
    model_file="$(basename "$LLAMA_MODEL_PATH")"

    # `--restart unless-stopped` auto-respawns the container on OOM/crash
    # (observed: CUDA pinned memory can balloon anon-rss to ~56 GB over time
    # and trigger the kernel OOM killer; exit 137).
    # `--memory` caps the container's RSS at a value that still fits the
    # working set but forces early failure rather than dragging the host down.
    docker run -d --restart unless-stopped --gpus all \
        --memory "${LLAMA_MEMORY:-48g}" \
        --name "$LLAMA_CONTAINER_NAME" \
        --label "llama.config-hash=$(_llama_config_hash)" \
        -p "${LLAMA_PORT}:8080" \
        -v "${model_dir}:/models:ro" \
        "$LLAMA_IMAGE" \
        -m "/models/${model_file}" \
        -ngl "$LLAMA_NGL" -fa on -c "$LLAMA_CTX" \
        --parallel 1 \
        --host 0.0.0.0 --port 8080 \
        >/dev/null || return 1
}

_llama_wait_ready() {
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0 start=$SECONDS elapsed frame
    # zsh arrays are 1-indexed by default; bash is 0-indexed.
    local idx_off=0
    [[ -n "${ZSH_VERSION:-}" ]] && idx_off=1

    # Restore cursor on interrupt; exit the (sub)shell so caller sees failure.
    trap 'printf "\033[?25h"; exit 130' INT TERM
    printf '\033[?25l'

    while ! _llama_is_ready; do
        elapsed=$((SECONDS - start))
        if (( elapsed > LLAMA_STARTUP_TIMEOUT )); then
            printf '\r\033[K\033[?25h\033[31m✗\033[0m Timeout after %ds\n' "$elapsed" >&2
            trap - INT TERM
            return 1
        fi
        if ! _llama_is_running; then
            printf '\r\033[K\033[?25h\033[31m✗\033[0m Container died during startup\n' >&2
            docker logs --tail 20 "$LLAMA_CONTAINER_NAME" >&2 2>&1
            trap - INT TERM
            return 1
        fi
        frame="${frames[$((i + idx_off))]}"
        printf '\r\033[K\033[36m%s\033[0m loading model into VRAM... %ds' \
            "$frame" "$elapsed"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.1
    done
    printf '\r\033[K\033[?25h\033[32m✓\033[0m ready in %ds\n' "$((SECONDS - start))"
    trap - INT TERM
}

_llama_ensure_up() {
    # Serialize concurrent startups across shells via flock.
    # uid-scoped to avoid colliding with other users on shared hosts.
    local lockfile="${TMPDIR:-/tmp}/${LLAMA_CONTAINER_NAME}.${UID:-$(id -u)}.lock"
    (
        flock -x 9 || exit 1

        # If running, check that its config matches ours — else restart.
        if _llama_is_running; then
            local want got
            want="$(_llama_config_hash)"
            got="$(_llama_running_hash)"
            if [[ -n "$got" && "$got" != "$want" ]]; then
                printf '\033[33m!\033[0m config changed (%s → %s), restarting...\n' \
                    "$got" "$want"
                docker stop "$LLAMA_CONTAINER_NAME" >/dev/null 2>&1
                # --rm auto-removes on stop; loop briefly to confirm
                local n=0
                while _llama_exists && (( n < 20 )); do sleep 0.2; n=$((n+1)); done
            fi
        fi

        _llama_cleanup_stale

        if _llama_is_ready; then exit 0; fi

        if ! _llama_is_running; then
            printf '\033[36m▸\033[0m starting %s...\n' "$LLAMA_CONTAINER_NAME"
            _llama_start_container || exit 1
        fi

        _llama_wait_ready || exit 1
    ) 9>"$lockfile"
}

_llama_infer() {
    local prompt="$1"
    local payload
    payload=$(jq -n --arg p "$prompt" '{
        model: "gemma4",
        messages: [{role:"user", content:$p}],
        stream: true
    }')
    curl -sN "$(_llama_endpoint)/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
    | while IFS= read -r line; do
        if [[ "$line" == data:* ]]; then
            # SSE spec allows "data:foo" without the space.
            local data="${line#data:}"
            data="${data# }"
            [[ "$data" == "[DONE]" ]] && break
            printf '%s' "$(jq -rj '.choices[0].delta.content // empty' <<<"$data")"
        elif [[ -z "$line" || "$line" == :* ]]; then
            # SSE keepalive (empty line or comment) — ignore.
            continue
        else
            # Non-SSE body: likely an error response. Surface it.
            printf '\n\033[31m✗\033[0m API error: %s\n' "$line" >&2
        fi
    done
    printf '\n'
}

llama() {
    if [[ $# -eq 0 && -t 0 ]]; then
        printf 'usage: llama "<prompt>"   |   echo "..." | llama\n' >&2
        return 2
    fi
    local prompt
    if [[ $# -gt 0 ]]; then
        prompt="$*"
    else
        prompt="$(cat)"
    fi
    _llama_ensure_up || return 1
    _llama_infer "$prompt"
}

llama-status() {
    if _llama_is_ready; then
        printf '\033[32m●\033[0m running  %s\n' "$(_llama_endpoint)"
    elif _llama_is_running; then
        printf '\033[33m●\033[0m starting (not ready yet)\n'
    else
        printf '\033[90m○\033[0m stopped\n'
    fi
}

llama-stop() {
    if _llama_is_running; then
        docker stop "$LLAMA_CONTAINER_NAME" >/dev/null && \
            printf '\033[32m✓\033[0m stopped\n'
    else
        printf '\033[90m○\033[0m already stopped\n'
    fi
}

llama-logs() { docker logs -f "$LLAMA_CONTAINER_NAME"; }

# ---- benchmarks ----

_llama_bench_one() {
    local label="$1" prompt="$2" n_predict="${3:-128}"
    local endpoint result pn pps gps total t0 t1
    endpoint="$(_llama_endpoint)"
    t0=$(date +%s.%N)
    result=$(curl -s "${endpoint}/completion" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg p "$prompt" --argjson n "$n_predict" \
            '{prompt: $p, n_predict: $n, cache_prompt: false}')") || return 1
    t1=$(date +%s.%N)
    pn=$(jq -r '.timings.prompt_n // 0'          <<<"$result")
    pps=$(jq -r '.timings.prompt_per_second // 0' <<<"$result")
    gps=$(jq -r '.timings.predicted_per_second // 0' <<<"$result")
    total=$(awk -v a="$t1" -v b="$t0" 'BEGIN{printf "%.2f", a-b}')
    printf '  %-8s %-10s %-12.1f %-12.1f %-10s\n' "$label" "$pn" "$pps" "$gps" "$total"
}

llama-bench-api() {
    if ! _llama_is_ready; then
        printf '\033[31m✗\033[0m server not running. Start it: `llama "test"`\n' >&2
        return 1
    fi

    printf '\033[36m▸\033[0m warmup (ignored)...\n'
    curl -s "$(_llama_endpoint)/completion" \
        -H 'Content-Type: application/json' \
        -d '{"prompt":"hi","n_predict":16}' >/dev/null

    printf '\n  \033[1m%-8s %-10s %-12s %-12s %-10s\033[0m\n' \
        "run" "prompt_n" "pp_tok/s" "gen_tok/s" "total_s"
    printf '  %-8s %-10s %-12s %-12s %-10s\n' \
        "---" "-----" "-----" "-----" "-----"

    _llama_bench_one short "Say hello."
    local medium long
    medium=$(printf 'The quick brown fox jumps over the lazy dog. %.0s' {1..40})
    _llama_bench_one medium "$medium"
    long=$(printf 'The quick brown fox jumps over the lazy dog. %.0s' {1..160})
    _llama_bench_one long "$long"

    printf '\n\033[32m✓\033[0m done\n'
}

llama-bench-native() {
    if [[ ! -f "$LLAMA_MODEL_PATH" ]]; then
        printf '\033[31m✗\033[0m Model not found: %s\n' "$LLAMA_MODEL_PATH" >&2
        return 1
    fi

    if _llama_is_running; then
        printf '\033[33m!\033[0m stopping server to free VRAM for native bench...\n'
        docker stop "$LLAMA_CONTAINER_NAME" >/dev/null
        sleep 1
    fi

    local model_dir model_file bench_image
    model_dir="$(dirname "$LLAMA_MODEL_PATH")"
    model_file="$(basename "$LLAMA_MODEL_PATH")"
    bench_image="${LLAMA_BENCH_IMAGE:-ghcr.io/ggml-org/llama.cpp:full-cuda}"

    printf '\033[36m▸\033[0m running llama-bench (first run pulls ~2GB image)...\n\n'
    docker run --rm --gpus all \
        -v "${model_dir}:/models:ro" \
        --entrypoint /app/llama-bench \
        "$bench_image" \
        -m "/models/${model_file}" \
        -ngl 99 -fa 1 \
        -p 512 -n 128 -r 3

    printf '\n\033[32m✓\033[0m bench done. Next `llama "..."` will restart the server.\n'
}
