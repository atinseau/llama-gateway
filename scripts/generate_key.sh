#!/usr/bin/env bash
# Interactive CLI to provision a new API key on the LiteLLM gateway.
# Handles the "no-default-models" trap by running a user/update after creation.
#
# Usage: ./scripts/generate_key.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/gateway/.env"
ENDPOINT="${LITELLM_ENDPOINT:-http://localhost:4000}"

# --- colors ---
c_blue()  { printf '\033[36m%s\033[0m' "$*"; }
c_green() { printf '\033[32m%s\033[0m' "$*"; }
c_red()   { printf '\033[31m%s\033[0m' "$*"; }
c_dim()   { printf '\033[90m%s\033[0m' "$*"; }
c_bold()  { printf '\033[1m%s\033[0m' "$*"; }

# --- preflight ---

[[ -f "$ENV_FILE" ]] || { c_red "✗"; echo " no $ENV_FILE — did you run 'make up' yet?"; exit 1; }

MASTER=$(grep '^LITELLM_MASTER_KEY=' "$ENV_FILE" | cut -d= -f2-)
[[ -n "$MASTER" ]] || { c_red "✗"; echo " LITELLM_MASTER_KEY empty in $ENV_FILE"; exit 1; }

if ! curl -sf -o /dev/null "$ENDPOINT/health/liveliness" 2>/dev/null; then
    c_red "✗"; echo " gateway not reachable at $ENDPOINT"
    echo "  run: make up"
    exit 1
fi

command -v jq >/dev/null || { c_red "✗"; echo " jq required — sudo apt install jq"; exit 1; }

# --- prompts ---

ask() {
    # ask <prompt> <default> → echoes the user's answer (or default)
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

# --- main ---

c_blue "▸"; echo " New API key for the llama gateway"
echo

ALIAS=$(ask_nonempty "Alias (e.g. alice, slack-bot)")
USER_ID=$(ask     "User ID (empty = auto-generate)")
BUDGET=$(ask_numeric "Budget USD"        "100")
RPM=$(ask_numeric    "Rate limit req/min" "120")
MODELS_IN=$(ask   "Models (comma-separated)" "gemma4")

# Build JSON models array
MODELS_JSON=$(jq -cn --arg s "$MODELS_IN" '$s | split(",") | map(gsub("^\\s+|\\s+$"; ""))')

# Build payload
PAYLOAD=$(jq -cn \
    --arg alias "$ALIAS" \
    --arg user  "$USER_ID" \
    --argjson models "$MODELS_JSON" \
    --argjson budget "$BUDGET" \
    --argjson rpm "$RPM" \
    '{
        key_alias: $alias,
        models: $models,
        max_budget: $budget,
        rpm_limit: $rpm
    } + (if $user == "" then {} else {user_id: $user} end)')

echo
c_blue "▸"; echo " creating key..."

RESPONSE=$(curl -sS -X POST "$ENDPOINT/key/generate" \
    -H "Authorization: Bearer $MASTER" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

if ! jq -e '.key' <<<"$RESPONSE" >/dev/null 2>&1; then
    c_red "✗"; echo " key creation failed"
    echo "$RESPONSE" | jq -r '.error.message // .detail // .' 2>/dev/null || echo "$RESPONSE"
    exit 1
fi

KEY=$(jq -r '.key'     <<<"$RESPONSE")
ASSIGNED_USER=$(jq -r '.user_id // ""' <<<"$RESPONSE")

# Handle the "no-default-models" trap: when LiteLLM auto-creates a user
# for a new key, that user gets models=["no-default-models"] which
# overrides the key's own allowlist. Only apply the fix when we actually
# have a user attached.
if [[ -n "$ASSIGNED_USER" ]]; then
    c_blue "▸"; echo " granting model access at user level..."
    curl -sS -X POST "$ENDPOINT/user/update" \
        -H "Authorization: Bearer $MASTER" \
        -H "Content-Type: application/json" \
        -d "$(jq -cn --arg u "$ASSIGNED_USER" --argjson m "$MODELS_JSON" '{user_id: $u, models: $m}')" \
        >/dev/null
fi

echo
c_green "✓"; echo " key provisioned"
echo
printf '  %-10s %s\n' "Alias"   "$ALIAS"
printf '  %-10s %s\n' "User ID" "${ASSIGNED_USER:-(none)}"
printf '  %-10s %s\n' "Budget"  "\$$BUDGET"
printf '  %-10s %s\n' "RPM"     "$RPM"
printf '  %-10s %s\n' "Models"  "$(jq -r 'join(", ")' <<<"$MODELS_JSON")"
printf '  %-10s %s\n' "Key"     "$(c_bold "$KEY")"
echo
echo "$(c_dim "Share with the recipient:")"
echo "  export LLM_API_KEY=$KEY"
