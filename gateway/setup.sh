#!/usr/bin/env bash
# Generate secrets on first run, then start the stack.
# Usage: ./setup.sh
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

if [[ ! -f .env ]]; then
    echo "▸ generating .env with random secrets"
    umask 077
    cat > .env <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 24)
LITELLM_MASTER_KEY=sk-$(openssl rand -hex 24)
LITELLM_SALT_KEY=sk-$(openssl rand -hex 24)
UI_USERNAME=admin
UI_PASSWORD=$(openssl rand -hex 12)
EOF
    echo "  → .env (chmod 600)"
else
    echo "▸ .env exists, keeping it"
fi

mkdir -p data/postgres

echo "▸ docker compose up -d"
docker compose up -d

echo ""
echo "▸ waiting for LiteLLM to be ready..."
for i in {1..60}; do
    if curl -sf -o /dev/null http://localhost:4000/health/liveliness; then
        echo "  ✓ ready"
        break
    fi
    sleep 1
    [[ $i -eq 60 ]] && { echo "  ✗ timeout"; docker compose logs --tail 30 litellm; exit 1; }
done

# Source .env for the final summary
set -a; source .env; set +a

cat <<EOF

✓ gateway up

  API endpoint     : http://localhost:4000
  Admin UI         : http://localhost:4000/ui
  UI login         : ${UI_USERNAME} / ${UI_PASSWORD}
  Master key       : ${LITELLM_MASTER_KEY}

Next steps:
  1. Open http://localhost:4000/ui in your browser, login, and create user keys.
  2. Or via API:
     curl -X POST http://localhost:4000/key/generate \\
       -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \\
       -H "Content-Type: application/json" \\
       -d '{"models":["gemma4"],"max_budget":10.0,"rpm_limit":60}'
  3. Test the new key:
     curl http://localhost:4000/v1/chat/completions \\
       -H "Authorization: Bearer <the-new-key>" \\
       -H "Content-Type: application/json" \\
       -d '{"model":"gemma4","messages":[{"role":"user","content":"hi"}]}'

To expose on internet later, we will add a cloudflared service.
EOF
