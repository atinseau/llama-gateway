SHELL := /bin/bash
.DEFAULT_GOAL := help

GATEWAY := gateway
WRAPPER := ./llama.sh

.PHONY: help install download-model serve stop status logs-server bench bench-native \
        up up-tunnel down restart logs ps keys monitor monitor-gpu monitor-containers \
        open-ui open-tunnel nuke

help:  ## Show this help
	@echo "Usage: make <target>"
	@echo ""
	@echo "Setup:"
	@grep -E '^(install|download-model):.*##' $(MAKEFILE_LIST) | awk -F':.*##' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Llama.cpp server:"
	@grep -E '^(serve|stop|status|logs-server|bench|bench-native):.*##' $(MAKEFILE_LIST) | awk -F':.*##' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Gateway (LiteLLM + Postgres):"
	@grep -E '^(up|up-tunnel|down|restart|logs|ps):.*##' $(MAKEFILE_LIST) | awk -F':.*##' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "API keys:"
	@grep -E '^(keys):.*##' $(MAKEFILE_LIST) | awk -F':.*##' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Monitoring:"
	@grep -E '^(monitor|monitor-gpu|monitor-containers):.*##' $(MAKEFILE_LIST) | awk -F':.*##' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Maintenance:"
	@grep -E '^(open-ui|open-tunnel|nuke):.*##' $(MAKEFILE_LIST) | awk -F':.*##' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ----- setup -----

install:  ## Install Docker + NVIDIA Container Toolkit (requires sudo)
	sudo bash install-docker.sh

download-model:  ## Download Gemma 4 31B Q4_K_XL (~18.8 GB) to ~/models/gemma4
	mkdir -p $$HOME/models/gemma4
	wget -c --directory-prefix=$$HOME/models/gemma4 \
	  "https://huggingface.co/unsloth/gemma-4-31b-it-GGUF/resolve/main/gemma-4-31B-it-UD-Q4_K_XL.gguf"

# ----- llama.cpp server -----

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

# ----- keys -----

keys:  ## Guided CLI to manage API keys (create, list, info, delete, fix access)
	@bash ./scripts/keys.sh

# ----- monitoring -----

monitor:  ## Real-time dashboard: CPU, RAM, GPU, containers (Ctrl-C to exit)
	@bash ./scripts/monitor.sh

monitor-gpu:  ## Just GPU: watch nvidia-smi every second
	@watch -n 1 -c nvidia-smi

monitor-containers:  ## Just containers: docker stats live
	@docker stats

# ----- maintenance -----

open-ui:  ## Open LiteLLM admin UI in browser
	xdg-open http://localhost:4000/ui 2>/dev/null || echo "→ http://localhost:4000/ui"

open-tunnel:  ## Open public URL in browser
	xdg-open https://llm.at-tech.cloud 2>/dev/null || echo "→ https://llm.at-tech.cloud"

nuke:  ## ⚠  Stop gateway AND delete Postgres data (loses all keys!)
	@read -p "Erase all keys + logs + container state? [y/N] " c && [[ "$$c" == "y" ]] || exit 1
	cd $(GATEWAY) && docker compose --profile tunnel down -v
	rm -rf $(GATEWAY)/data
