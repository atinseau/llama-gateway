#!/usr/bin/env bash
# Installe Docker Engine + NVIDIA Container Toolkit sur Ubuntu
# Usage: sudo bash ~/Documents/llama/install-docker.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "✗ à lancer avec sudo: sudo bash $0" >&2
    exit 1
fi

TARGET_USER="${SUDO_USER:-$USER}"
echo "▸ installation pour l'utilisateur: $TARGET_USER"

# --- 1. Docker Engine (repo officiel) ---
echo "▸ [1/4] ajout du repo Docker officiel"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Ubuntu 25.10 n'a pas encore de repo Docker dédié : fallback sur noble (24.04)
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
case "$CODENAME" in
    # Known LTS codenames published by Docker
    jammy|noble) DOCKER_CODENAME="$CODENAME" ;;
    # Anything else (interim releases, future names) → fall back to latest LTS
    *)
        echo "  ⚠ codename '$CODENAME' not a known Docker LTS — falling back to noble"
        DOCKER_CODENAME=noble
        ;;
esac
echo "  codename hôte: $CODENAME → repo docker: $DOCKER_CODENAME"

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $DOCKER_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list

echo "▸ [2/4] installation de Docker Engine"
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# --- 2. Ajout de l'utilisateur au groupe docker ---
if [[ "$TARGET_USER" == "root" ]]; then
    echo "▸ [3/4] utilisateur = root, skip du groupe docker"
else
    echo "▸ [3/4] ajout de $TARGET_USER au groupe docker"
    usermod -aG docker "$TARGET_USER"
fi

# --- 3. NVIDIA Container Toolkit ---
echo "▸ [4/4] installation NVIDIA Container Toolkit"
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Safety: abort if the sed didn't inject signed-by (NVIDIA list format changed)
if ! grep -q 'signed-by=' /etc/apt/sources.list.d/nvidia-container-toolkit.list; then
    echo "✗ signed-by injection failed — NVIDIA list format changed, aborting" >&2
    rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
    exit 1
fi

apt-get update -qq
apt-get install -y -qq nvidia-container-toolkit

nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

echo ""
echo "✓ installation terminée"
echo ""
echo "⚠  déconnecte-toi/reconnecte-toi (ou redémarre) pour que le groupe docker"
echo "   soit pris en compte sans sudo. Ensuite teste :"
echo ""
echo "     docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi"
echo ""
