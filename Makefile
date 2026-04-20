SHELL := /bin/bash
.DEFAULT_GOAL := help

GATEWAY := gateway
WRAPPER := ./llama.sh
MASTER   = $$(grep LITELLM_MASTER_KEY $(GATEWAY)/.env | cut -d= -f2)

# Allow `make key-create name=alice budget=5 rpm=60 models=gemma4`
name    ?= default
budget  ?= 100
rpm     ?= 120
models  ?= gemma4
key     ?=
user    ?=

.PHONY: help
help:  ## Show this help
	@echo "Usage: make <target>"
	@echo ""
	@echo "Setup:"
	@grep -E '^(install|download-model):.*##' $(MAKEFILE_LIST) | awk -F':.*##' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Llama.cpp server (wrapper):"
	@grep -E '^(serve|stop|status|logs-server|bench|bench-native):.*##' $(MAKEFILE_LIST) | awk -F':.*##' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Gateway (LiteLLM + Postgres):"
	@grep -E '^(up|up-tunnel|down|restart|logs|ps):.*##' $(MAKEFILE_LIST) | awk -F':.*##' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Keys (LiteLLM admin):"
	@grep -E '^(key-create|key-list|key-info|key-delete|key-allow):.*##' $(MAKEFILE_LIST) | awk -F':.*##' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Maintenance:"
	@grep -E '^(open-ui|open-tunnel|nuke):.*##' $(MAKEFILE_LIST) | awk -F':.*##' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ----- setup -----

install:  ## Install Docker + NVIDIA Container Toolkit (requires sudo)
	sudo bash install-docker.sh

download-model:  ## Download Gemma 4 31B Q4_K_XL (~18.8 GB) to ~/models/gemma4
	mkdir -p $$HOME/models/gemma4
	wget -c --directory-prefix=$$HOME/models/gemma4 \
	  "https://huggingface.co/unsloth/gemma-4-31b-it-GGUF/resolve/main/gemma-4-31B-it-UD-Q4_K_XL.gguf"

# ----- llama.cpp server (via wrapper functions) -----

serve:  ## Start the llama.cpp server container (triggers model load)
	@bash -c 'source $(WRAPPER) && llama "ping"' >/dev/null

stop:  ## Stop the llama.cpp server (frees VRAM)
	@bash -c 'source $(WRAPPER) && llama-stop'

status:  ## Show llama.cpp server status
	@bash -c 'source $(WRAPPER) && llama-status'

logs-server:  ## Tail llama.cpp server logs (Ctrl-C to exit)
	@bash -c 'source $(WRAPPER) && llama-logs'

bench:  ## Bench via running server's /completion endpoint
	@bash -c 'source $(WRAPPER) && llama-bench-api'

bench-native:  ## Bench with official llama-bench (stops the server!)
	@bash -c 'source $(WRAPPER) && llama-bench-native'

# ----- gateway -----

up:  ## Start LiteLLM + Postgres
	cd $(GATEWAY) && ./setup.sh

up-tunnel:  ## Start gateway + cloudflared (requires TUNNEL_TOKEN in .env)
	cd $(GATEWAY) && docker compose --profile tunnel up -d

down:  ## Stop gateway (keeps Postgres data)
	cd $(GATEWAY) && docker compose --profile tunnel down

restart:  ## Restart litellm (apply config changes)
	cd $(GATEWAY) && docker compose restart litellm

logs:  ## Tail LiteLLM logs (Ctrl-C to exit)
	cd $(GATEWAY) && docker compose logs -f litellm

ps:  ## Show gateway container state
	cd $(GATEWAY) && docker compose ps

# ----- keys (LiteLLM admin API) -----

key-create:  ## Create an API key: make key-create name=alice budget=10 rpm=60 models=gemma4
	@curl -s -X POST http://localhost:4000/key/generate \
	  -H "Authorization: Bearer $(MASTER)" \
	  -H "Content-Type: application/json" \
	  -d '{"key_alias":"$(name)","models":["$(models)"],"max_budget":$(budget),"rpm_limit":$(rpm)}' \
	  | jq '{key, alias: .key_alias, models, max_budget, rpm_limit}'
	@echo ""
	@echo "⚠  If user was auto-created with 'no-default-models', also run:"
	@echo "   make key-allow user=<user_id> models=gemma4"

key-list:  ## List all API keys (requires jq)
	@curl -s "http://localhost:4000/key/list?return_full_object=true" \
	  -H "Authorization: Bearer $(MASTER)" \
	  | jq '.keys[] | {alias: .key_alias, user_id, models, spend, rpm_limit}'

key-info:  ## Show info for one key: make key-info key=sk-...
	@[[ -n "$(key)" ]] || { echo "usage: make key-info key=sk-..."; exit 1; }
	@curl -s "http://localhost:4000/key/info?key=$(key)" \
	  -H "Authorization: Bearer $(MASTER)" | jq '.info'

key-delete:  ## Revoke a key: make key-delete key=sk-...
	@[[ -n "$(key)" ]] || { echo "usage: make key-delete key=sk-..."; exit 1; }
	@curl -s -X POST http://localhost:4000/key/delete \
	  -H "Authorization: Bearer $(MASTER)" \
	  -H "Content-Type: application/json" \
	  -d '{"keys":["$(key)"]}' | jq

key-allow:  ## Grant model access at user level: make key-allow user=<user_id> models=gemma4
	@[[ -n "$(user)" ]] || { echo "usage: make key-allow user=<user_id> models=gemma4"; exit 1; }
	@curl -s -X POST http://localhost:4000/user/update \
	  -H "Authorization: Bearer $(MASTER)" \
	  -H "Content-Type: application/json" \
	  -d '{"user_id":"$(user)","models":["$(models)"]}' | jq '{user_id, models}'

# ----- maintenance -----

open-ui:  ## Open LiteLLM admin UI in browser (localhost)
	xdg-open http://localhost:4000/ui 2>/dev/null || echo "→ http://localhost:4000/ui"

open-tunnel:  ## Open public URL in browser
	xdg-open https://llm.at-tech.cloud 2>/dev/null || echo "→ https://llm.at-tech.cloud"

nuke:  ## ⚠  Stop gateway AND delete Postgres data (loses all keys!)
	@read -p "Erase all keys + logs + container state? [y/N] " c && [[ "$$c" == "y" ]] || exit 1
	cd $(GATEWAY) && docker compose --profile tunnel down -v
	rm -rf $(GATEWAY)/data
