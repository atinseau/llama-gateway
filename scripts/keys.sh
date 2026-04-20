#!/usr/bin/env bash
# Unified guided CLI to manage API keys on the LiteLLM gateway.
# Usage: ./scripts/keys.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/gateway/.env"
ENDPOINT="${LITELLM_ENDPOINT:-http://localhost:4000}"
MASTER=""

# ──────────────────────────────────────────────────────────────
# Display helpers
# ──────────────────────────────────────────────────────────────

c_blue()  { printf '\033[36m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_red()   { printf '\033[31m%s\033[0m' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m' "$*"; }
c_dim()   { printf '\033[90m%s\033[0m' "$*"; }
c_bold()  { printf '\033[1m%s\033[0m' "$*"; }

die()     { c_red "✗"; echo " $*"; exit 1; }
info()    { c_blue "▸"; echo " $*"; }
ok()      { c_green "✓"; echo " $*"; }
warn()    { c_yellow "!"; echo " $*"; }

# ──────────────────────────────────────────────────────────────
# Prompt helpers
# ──────────────────────────────────────────────────────────────

ask() {
    # ask <prompt> [default] → echoes the answer (or default)
    local prompt="$1" default="${2:-}" answer
    if [[ -n "$default" ]]; then
        read -rp "$(printf '  %s %s: ' "$prompt" "$(c_dim "[$default]")")" answer
        echo "${answer:-$default}"
    else
        read -rp "$(printf '  %s: ' "$prompt")" answer
        echo "$answer"
    fi
}

ask_nonempty() {
    local prompt="$1" answer
    while :; do
        answer=$(ask "$prompt")
        [[ -n "$answer" ]] && { echo "$answer"; return; }
        c_red "  ✗ required"; echo
    done
}

ask_numeric() {
    local prompt="$1" default="$2" answer
    while :; do
        answer=$(ask "$prompt" "$default")
        if [[ "$answer" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            echo "$answer"; return
        fi
        c_red "  ✗ not a number"; echo
    done
}

ask_yesno() {
    local prompt="$1" default="${2:-n}" answer hint
    [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
    read -rp "$(printf '  %s [%s]: ' "$prompt" "$hint")" answer
    answer="${answer:-$default}"
    [[ "${answer,,}" == "y" ]]
}

# ──────────────────────────────────────────────────────────────
# Preflight
# ──────────────────────────────────────────────────────────────

preflight() {
    command -v jq   >/dev/null || die "jq required — sudo apt install jq"
    command -v curl >/dev/null || die "curl required"

    [[ -f "$ENV_FILE" ]] || die "no $ENV_FILE — run 'make up' first"

    MASTER=$(grep '^LITELLM_MASTER_KEY=' "$ENV_FILE" | cut -d= -f2-)
    [[ -n "$MASTER" ]] || die "LITELLM_MASTER_KEY empty in $ENV_FILE"

    curl -sf -o /dev/null "$ENDPOINT/health/liveliness" 2>/dev/null \
        || die "gateway not reachable at $ENDPOINT — run 'make up'"
}

# ──────────────────────────────────────────────────────────────
# API wrappers (all return raw JSON on stdout)
# ──────────────────────────────────────────────────────────────

api_get()  { curl -sS -H "Authorization: Bearer $MASTER" "$ENDPOINT$1"; }
api_post() {
    curl -sS -X POST -H "Authorization: Bearer $MASTER" \
        -H "Content-Type: application/json" -d "$2" "$ENDPOINT$1"
}

fetch_keys()    { api_get "/key/list?return_full_object=true"; }
key_info()      { api_get "/key/info?key=$1"; }
key_generate()  { api_post "/key/generate" "$1"; }
key_delete_api(){ api_post "/key/delete"   "$1"; }
user_update()   { api_post "/user/update"  "$1"; }

# ──────────────────────────────────────────────────────────────
# Key picker — lists keys numbered and returns the selected one
# ──────────────────────────────────────────────────────────────

pick_key() {
    # Emits the selected key's alias to stdout, or nothing on cancel.
    # Keys without an alias are skipped (can't be addressed safely via the API).
    local msg="${1:-Select a key}"
    local keys_json count
    keys_json=$(fetch_keys)
    # Filter to keys that have an alias — the rest can't be addressed.
    keys_json=$(jq '{keys: [.keys[] | select(.key_alias != null and .key_alias != "")]}' <<<"$keys_json")
    count=$(jq -r '.keys | length' <<<"$keys_json")

    if [[ "$count" == "0" ]]; then
        warn "no keys with an alias (aliases are required to manage keys via this CLI)"
        return 1
    fi

    echo >&2
    c_blue "▸" >&2; echo " $msg:" >&2
    jq -r '.keys | to_entries[] |
        "  [\(.key + 1)] \(.value.key_alias[0:20])"
        + (" " * (24 - (.value.key_alias[0:20] | length)))
        + "spend $\(.value.spend // 0)"
        + "   \(.value.key_name)"' <<<"$keys_json" >&2
    echo >&2

    local n
    n=$(ask "Pick [1-$count, empty to cancel]")
    [[ -z "$n" ]] && return 1
    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > count )); then
        c_red "  ✗ invalid selection" >&2; echo >&2
        return 1
    fi

    jq -r ".keys[$((n-1))].key_alias" <<<"$keys_json"
}

# ──────────────────────────────────────────────────────────────
# Commands
# ──────────────────────────────────────────────────────────────

cmd_create() {
    info "New API key"
    echo

    local alias user budget rpm models_in models_json payload response key assigned

    alias=$(ask_nonempty    "Alias (e.g. alice, slack-bot)")
    user=$(ask              "User ID (empty = auto-generate)")
    budget=$(ask_numeric    "Budget USD"         "100")
    rpm=$(ask_numeric       "Rate limit req/min" "120")
    models_in=$(ask         "Models (comma-separated)" "gemma4")

    models_json=$(jq -cn --arg s "$models_in" \
        '$s | split(",") | map(gsub("^\\s+|\\s+$"; ""))')

    payload=$(jq -cn \
        --arg alias "$alias" \
        --arg user  "$user" \
        --argjson models "$models_json" \
        --argjson budget "$budget" \
        --argjson rpm "$rpm" \
        '{
            key_alias: $alias,
            models: $models,
            max_budget: $budget,
            rpm_limit: $rpm
        } + (if $user == "" then {} else {user_id: $user} end)')

    echo
    info "creating key..."
    response=$(key_generate "$payload")

    if ! jq -e '.key' <<<"$response" >/dev/null 2>&1; then
        die "$(jq -r '.error.message // .detail // .' <<<"$response")"
    fi

    key=$(jq -r '.key' <<<"$response")
    assigned=$(jq -r '.user_id // ""' <<<"$response")

    # Fix the "no-default-models" trap when a user was attached.
    if [[ -n "$assigned" ]]; then
        info "granting user-level model access..."
        user_update "$(jq -cn --arg u "$assigned" \
            --argjson m "$models_json" '{user_id: $u, models: $m}')" >/dev/null
    fi

    echo
    ok "key provisioned"
    echo
    printf '  %-10s %s\n' "Alias"   "$alias"
    printf '  %-10s %s\n' "User ID" "${assigned:-(none)}"
    printf '  %-10s %s\n' "Budget"  "\$$budget"
    printf '  %-10s %s\n' "RPM"     "$rpm"
    printf '  %-10s %s\n' "Models"  "$(jq -r 'join(", ")' <<<"$models_json")"
    printf '  %-10s %s\n' "Key"     "$(c_bold "$key")"
    echo
    echo "$(c_dim "Share with the recipient:")"
    echo "  export LLM_API_KEY=$key"
}

cmd_list() {
    info "All API keys"
    local keys_json count
    keys_json=$(fetch_keys)
    count=$(jq -r '.keys | length' <<<"$keys_json")
    echo

    if [[ "$count" == "0" ]]; then
        c_dim "  (none yet)"; echo
        return
    fi

    printf '  %s\n' "$(c_bold "$(printf '%-22s %-38s %-12s %-10s %s' ALIAS USER MODELS SPEND CREATED)")"
    jq -r '.keys[] |
        [
            (.key_alias // "(no alias)")[0:20],
            (.user_id // "(none)")[0:36],
            ((.models // []) | join(","))[0:10],
            "$" + (.spend // 0 | tostring)[0:8],
            (.created_at // "")[0:10]
        ] | @tsv' <<<"$keys_json" | \
    while IFS=$'\t' read -r alias user models spend created; do
        printf '  %-22s %-38s %-12s %-10s %s\n' "$alias" "$user" "$models" "$spend" "$created"
    done
    echo
    c_dim "  total: $count"; echo
}

cmd_info() {
    # We read the info from /key/list (which includes everything we need)
    # rather than /key/info?key=... which requires the original sk-... value.
    local key_alias
    key_alias=$(pick_key "Pick a key to inspect") || return

    echo
    ok "key details"
    echo
    fetch_keys | jq -C --arg a "$key_alias" '.keys[] | select(.key_alias == $a) | {
        key_alias, user_id, models, spend, max_budget,
        rpm_limit, tpm_limit, created_at, expires,
        last_used: .last_used_at,
        team_id, metadata,
        key_name
    }' | sed 's/^/  /'
    echo
}

cmd_delete() {
    local key_alias payload
    key_alias=$(pick_key "Pick a key to DELETE") || return

    echo
    warn "about to delete key '$key_alias'"
    if ! ask_yesno "are you sure?" "n"; then
        c_dim "  cancelled"; echo
        return
    fi

    payload=$(jq -cn --arg a "$key_alias" '{key_aliases: [$a]}')
    local response
    response=$(key_delete_api "$payload")

    if jq -e '.deleted_keys | index($a) // false' --arg a "$key_alias" <<<"$response" >/dev/null 2>&1; then
        ok "deleted '$key_alias'"
    else
        die "delete failed: $(jq -r '.error.message // .detail // .' <<<"$response")"
    fi
}

cmd_fix_user() {
    info "Fix user model access"
    c_dim "  Use this when a key returns 'No default model access, only team"
    c_dim "  models allowed'. Applies to keys created outside this CLI (e.g."
    c_dim "  via the LiteLLM admin UI)."
    echo

    local user models_in models_json
    user=$(ask_nonempty "User ID (UUID from key/info)")
    models_in=$(ask     "Models to grant (comma-separated)" "gemma4")

    models_json=$(jq -cn --arg s "$models_in" \
        '$s | split(",") | map(gsub("^\\s+|\\s+$"; ""))')

    user_update "$(jq -cn --arg u "$user" --argjson m "$models_json" \
        '{user_id: $u, models: $m}')" >/dev/null

    ok "user $user now has access to: $(jq -r 'join(", ")' <<<"$models_json")"
}

# ──────────────────────────────────────────────────────────────
# Main menu
# ──────────────────────────────────────────────────────────────

show_menu() {
    echo
    c_bold "llama-gateway keys"; echo
    c_dim  "  endpoint: $ENDPOINT"; echo
    echo
    echo "  [1] Create a new key"
    echo "  [2] List all keys"
    echo "  [3] View key details"
    echo "  [4] Delete a key"
    echo "  [5] Fix user model access"
    echo "  [q] Quit"
    echo
}

main() {
    preflight

    while :; do
        show_menu
        local choice
        read -rp "  $(c_blue "▸") choose: " choice || { echo; break; }
        case "$choice" in
            1) cmd_create    ;;
            2) cmd_list      ;;
            3) cmd_info      ;;
            4) cmd_delete    ;;
            5) cmd_fix_user  ;;
            q|Q|"") echo; break ;;
            *) c_red "  ✗ invalid choice"; echo ;;
        esac
    done
}

main "$@"
