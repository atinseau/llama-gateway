# Utiliser l'API

Exemples pour consommer l'API LLM privée. L'API parle le protocole **OpenAI**, donc n'importe quel SDK ou outil compatible OpenAI fonctionne.

## Prérequis

**Une clé API.** Elles sont émises par l'administrateur du service — il n'y a pas d'auto-provisioning. Contacte-le pour en obtenir une.

Une fois la clé reçue, mets-la dans ton environnement (ajoute la ligne dans `~/.zshrc` pour la rendre permanente) :

```bash
export LLM_API_KEY=sk-...
```

## Endpoint

```
https://llm.at-tech.cloud/v1
```

## Modèle disponible

- `gemma4` — Gemma 4 31B (Q4_K_XL), contexte 32k, ~42 tok/s.

---

## curl

```bash
curl -N https://llm.at-tech.cloud/v1/chat/completions \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4",
    "stream": true,
    "messages": [{"role":"user","content":"Bonjour"}]
  }'
```

---

## Node.js

```bash
npm i openai
node script.mjs "explique la récursion en 2 phrases"
```

`script.mjs` :

```javascript
import OpenAI from "openai";

if (!process.env.LLM_API_KEY) {
  console.error("error: set LLM_API_KEY in your environment");
  process.exit(1);
}

const client = new OpenAI({
  baseURL: "https://llm.at-tech.cloud/v1",
  apiKey: process.env.LLM_API_KEY,
});

const stream = await client.chat.completions.create({
  model: "gemma4",
  messages: [{ role: "user", content: process.argv.slice(2).join(" ") || "Bonjour" }],
  stream: true,
});

for await (const chunk of stream) {
  process.stdout.write(chunk.choices[0]?.delta?.content || "");
}
process.stdout.write("\n");
```

---

## Python

```bash
pip install openai
python script.py "résume ce texte en 3 points"
```

`script.py` :

```python
import os, sys
from openai import OpenAI

api_key = os.environ.get("LLM_API_KEY")
if not api_key:
    sys.exit("error: set LLM_API_KEY in your environment")

client = OpenAI(
    base_url="https://llm.at-tech.cloud/v1",
    api_key=api_key,
)

prompt = " ".join(sys.argv[1:]) or "Bonjour"

stream = client.chat.completions.create(
    model="gemma4",
    messages=[{"role": "user", "content": prompt}],
    stream=True,
)

for chunk in stream:
    delta = chunk.choices[0].delta.content
    if delta:
        print(delta, end="", flush=True)
print()
```

---

## opencode — agent coding CLI

Dans `~/.config/opencode/opencode.json` :

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Gemma 4",
      "options": {
        "baseURL": "https://llm.at-tech.cloud/v1",
        "apiKey": "{env:LLM_API_KEY}"
      },
      "models": {
        "gemma4": { "name": "Gemma 4 31B" }
      }
    }
  }
}
```

**⚠ Évite le provider name `llama`** — il entre en collision avec un provider déjà présent dans le registre opencode, ton modèle sera masqué du TUI.

Puis dans opencode : **`Ctrl+X M`** → sélectionne `local/gemma4` (ou `F2` pour cycle rapide).

---

## Continue.dev — extension VS Code

Dans `~/.continue/config.json` :

```json
{
  "models": [{
    "title": "Gemma 4",
    "provider": "openai",
    "model": "gemma4",
    "apiBase": "https://llm.at-tech.cloud/v1",
    "apiKey": "sk-votre-clé"
  }]
}
```

---

## Open WebUI — chat UI self-hosted

```bash
docker run -d --name open-webui -p 3000:3000 \
  -v open-webui:/app/backend/data \
  -e OPENAI_API_BASE_URL=https://llm.at-tech.cloud/v1 \
  -e OPENAI_API_KEY=$LLM_API_KEY \
  -e WEBUI_AUTH=False \
  --restart unless-stopped \
  ghcr.io/open-webui/open-webui:main
```

→ http://localhost:3000

---

## Fonction shell `ask`

À coller dans `~/.zshrc` (nécessite `jq`) :

```bash
ask() {
  curl -sN https://llm.at-tech.cloud/v1/chat/completions \
    -H "Authorization: Bearer $LLM_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg p "$*" '{model:"gemma4",stream:true,messages:[{role:"user",content:$p}]}')" \
  | sed -un 's/^data: //p' \
  | jq --unbuffered -rj 'select(. != "[DONE]") | .choices[0].delta.content // empty'
  echo
}
```

Usage : `ask "explique le big O en 2 phrases"`
