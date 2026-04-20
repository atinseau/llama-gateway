# llama

Stack LLM self-hosted : **Gemma 4 31B** sur RTX 4090, exposé en API OpenAI-compatible avec clés virtuelles, quotas, tracking de conso, et accès HTTPS public via Cloudflare Tunnel.

## Architecture

```
Internet  ──►  Cloudflare Tunnel  ──►  LiteLLM  ──►  llama.cpp  ──►  RTX 4090
 (HTTPS)         (cloudflared)         (:4000)        (:8080)        Gemma 4 31B
                                          │                          UD-Q4_K_XL
                                          ▼
                                      Postgres
                                  (keys + usage logs)
```

## Structure

```
llama/
├── README.md                 ← ce fichier (admin/opérateur)
├── CLAUDE.md                 ← contexte pour Claude Code
├── EXAMPLE.md                ← exemples d'utilisation de l'API (client-facing)
├── llama.sh                  ← wrapper shell llama.cpp
├── install-docker.sh         ← bootstrap Docker + NVIDIA
└── gateway/
    ├── docker-compose.yml    ← LiteLLM + Postgres + cloudflared
    ├── setup.sh              ← génère .env et démarre la stack
    ├── config/litellm.yaml   ← routing LiteLLM → llama.cpp
    └── .env                  ← secrets (chmod 600, gitignored)
```

## Setup from scratch

### 1. Prérequis host (une fois)

```bash
sudo bash install-docker.sh
# déco/reco session pour le groupe docker
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

### 2. Télécharger le modèle (~18.8 Go)

```bash
mkdir -p ~/models/gemma4
wget -c --directory-prefix=$HOME/models/gemma4 \
  "https://huggingface.co/unsloth/gemma-4-31b-it-GGUF/resolve/main/gemma-4-31B-it-UD-Q4_K_XL.gguf"
```

### 3. Activer le wrapper llama.cpp

```bash
echo 'source ~/Documents/llama/llama.sh' >> ~/.zshrc
source ~/.zshrc
llama "test"   # démarre le container + infère
```

### 4. Démarrer le gateway

```bash
cd gateway && ./setup.sh
```

Affiche l'URL de l'UI admin, les identifiants, et la master key.

### 5. (Optionnel) Activer le tunnel Cloudflare

1. Crée un tunnel sur https://one.dash.cloudflare.com → récupère le token
2. Ajoute-le à `gateway/.env` : `TUNNEL_TOKEN=...`
3. Configure un Public Hostname `llm.tondomaine.com` → `HTTP://litellm:4000`
4. `docker compose --profile tunnel up -d`
5. **Important** : crée une WAF Custom Rule sur Cloudflare qui skip Bot Fight Mode + managed rules pour le hostname, sinon les SDK OpenAI se prennent un 403.

## Opérations courantes

### Inférence CLI (wrapper `llama`)

```bash
llama "explique la récursion en 2 phrases"
echo "résume ce texte" | llama
llama-status                 # état du conteneur
llama-stop                   # libère la VRAM
llama-logs                   # logs serveur temps réel
llama-bench-api              # bench via /completion (serveur chaud)
llama-bench-native           # bench officiel llama-bench
```

### Gestion des clés API (via LiteLLM)

**UI** : http://localhost:4000/ui (login = `.env` → UI_USERNAME / UI_PASSWORD)

**API** :
```bash
MASTER=$(grep LITELLM_MASTER_KEY gateway/.env | cut -d= -f2)

# Créer une clé
curl -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer $MASTER" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"alice","models":["gemma4"],"max_budget":10.0,"rpm_limit":60}'

# Infos et conso d'une clé
curl -s "http://localhost:4000/key/info?key=sk-..." \
  -H "Authorization: Bearer $MASTER" | jq

# Révoquer
curl -X POST http://localhost:4000/key/delete \
  -H "Authorization: Bearer $MASTER" \
  -H "Content-Type: application/json" \
  -d '{"keys":["sk-..."]}'
```

### Gateway

```bash
cd gateway
docker compose ps                        # état
docker compose logs -f litellm           # logs proxy
docker compose restart litellm           # après modif litellm.yaml
docker compose --profile tunnel up -d    # ajouter cloudflared
docker compose down                      # stop (garde Postgres data)
docker compose down -v                   # stop + efface la DB (⚠ perd les clés)
```

## Utiliser l'API

Voir **`EXAMPLE.md`** pour les clients : curl, Node.js, Python, opencode, Continue.dev, Open WebUI, fonction shell.

Export minimal :
```bash
export LLM_API_KEY=sk-...
export LLM_BASE_URL=http://localhost:4000/v1    # ou https://llm.at-tech.cloud/v1
```

## Variables d'environnement (wrapper `llama.sh`)

| Variable | Défaut | Rôle |
|---|---|---|
| `LLAMA_MODEL_PATH` | `~/models/gemma4/gemma-4-31B-it-UD-Q4_K_XL.gguf` | GGUF à charger |
| `LLAMA_PORT` | `8080` | Port hôte |
| `LLAMA_CTX` | `32768` | Taille de contexte |
| `LLAMA_NGL` | `99` | Couches GPU (99 = tout) |
| `LLAMA_MEMORY` | `48g` | Limite RAM du conteneur (protection OOM host) |
| `LLAMA_IMAGE` | `ghcr.io/ggml-org/llama.cpp:server-cuda` | Image Docker |
| `LLAMA_CONTAINER_NAME` | `llama-server` | Nom du conteneur |
| `LLAMA_STARTUP_TIMEOUT` | `300` | Timeout chargement modèle (s) |
| `LLAMA_BENCH_IMAGE` | `ghcr.io/ggml-org/llama.cpp:full-cuda` | Image avec `llama-bench` |

## Perf de référence (RTX 4090 + Gemma 4 31B Q4_K_XL)

| Métrique | Valeur |
|---|---|
| Prompt processing (pp512) | ~2940 tok/s |
| Token generation (tg128) | ~42 tok/s |
| Chargement VRAM | ~3 s |
| VRAM utilisée | ~23.4 / 24 Go |

Anything matérialement en-dessous = régression.

## Dépendances host

Docker 29+, NVIDIA driver (CUDA 12/13), `curl`, `jq`, `openssl`.
