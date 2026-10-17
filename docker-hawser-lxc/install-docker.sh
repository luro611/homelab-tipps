#!/bin/bash
set -euo pipefail

# =====================================================
# Hawser Worker Setup (Debian 13 "Trixie") – clean & idempotent
# =====================================================

#--- Root check ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Bitte als root ausführen (sudo -i)."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ================================
# 🏷️ 0) LXC / App Name
# ================================
read -rp "👉 Name für diesen LXC / Stack (z.B. paperless): " APP_NAME

if [[ -z "$APP_NAME" ]]; then
  echo "❌ Name darf nicht leer sein!"
  exit 1
fi

APP_NAME="$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-_')"

echo "✅ Verwende Namen: $APP_NAME"

# ================================
# 📁 Struktur
# ================================
BASE_ROOT="/opt/containers"
BASE_DIR="$BASE_ROOT/$APP_NAME"
DATA_DIR="$BASE_DIR/data"
VOLUMES_DIR="$BASE_DIR/volumes"
CONFIGS_DIR="$BASE_DIR/configs"

LOG_FILE="/var/log/hawser-${APP_NAME}-setup.log"

CONTAINER_NAME="hawser-agent"
HAWSER_IMAGE="ghcr.io/finsys/hawser:latest"

# FIX: richtiger Hawser Port
HAWSER_PORT="2376"

# Token-Datei (wird bei erneutem Lauf wiederverwendet)
TOKEN_FILE="$BASE_DIR/hawser.token"

# ================================
# 📝 Logging
# ================================
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

timestamp() { date +"%Y-%m-%d %H:%M:%S %z"; }
log() { echo "$(timestamp) | $*"; }

log "🚀 Starte Hawser Setup für: $APP_NAME"

# ================================
# 🔄 1) System Update
# ================================
log "🔄 Systemupdate..."
apt update
apt -y upgrade
apt -y autoremove

# ================================
# 🔧 2) Tools
# ================================
log "🔧 Installiere Tools..."
apt install -y curl ca-certificates gnupg lsb-release apt-transport-https openssl

# ================================
# 🐳 3) Docker installieren
# ================================
if ! command -v docker >/dev/null 2>&1; then
  log "🐳 Installiere Docker..."

  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  CODENAME="$(lsb_release -cs || echo trixie)"
  ARCH="$(dpkg --print-architecture)"

  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${CODENAME} stable
EOF

  if ! apt update; then
    log "⚠️ Fallback auf bookworm..."
    cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable
EOF
    apt update
  fi

  apt install -y --no-install-recommends docker-ce docker-ce-cli containerd.io
  apt install -y --no-install-recommends docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  log "✅ Docker installiert."
else
  log "✅ Docker bereits vorhanden."
  systemctl enable --now docker || true
fi

# ================================
# 📁 4) Verzeichnisse
# ================================
log "📁 Erstelle Verzeichnisstruktur..."
mkdir -p "$DATA_DIR" "$VOLUMES_DIR" "$CONFIGS_DIR"
chmod -R 755 "$BASE_DIR"
chown -R root:root "$BASE_DIR"

# ================================
# 📦 5) Hawser Image
# ================================
log "📦 Lade Hawser Image..."
docker pull "$HAWSER_IMAGE" || log "⚠️ Pull fehlgeschlagen (offline?)"

# ================================
# 🔑 6) Token erzeugen / wiederverwenden
# ================================
if [ -s "$TOKEN_FILE" ]; then
  HAWSER_TOKEN="$(cat "$TOKEN_FILE")"
  log "🔑 Vorhandenes Token wird wiederverwendet."
else
  HAWSER_TOKEN="$(openssl rand -hex 24)"
  ( umask 077; echo "$HAWSER_TOKEN" > "$TOKEN_FILE" )
  log "🔑 Neues Token erzeugt."
fi

# ================================
# 🚀 7) CLEAN DEPLOY (WICHTIG!)
# ================================
log "🚀 Entferne alte Hawser Instanz (falls vorhanden)..."
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

log "🚀 Starte Hawser Agent neu..."

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p ${HAWSER_PORT}:2376 \
  -e TOKEN="$HAWSER_TOKEN" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "$HAWSER_IMAGE"

sleep 3

if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" != "true" ]; then
  log "❌ Hawser Container läuft nicht! Letzte Logs:"
  docker logs "$CONTAINER_NAME" 2>&1 | tail -20
  exit 1
fi

log "✅ Hawser Agent läuft."

# ================================
# 🌐 Endpoint + Token
# ================================
HOST_IP="$(hostname -I | awk '{print $1}')"

log "🌐 Hawser Endpoint: http://${HOST_IP}:${HAWSER_PORT}"

# ================================
# 🏁 Done
# ================================
log "🏁 Setup abgeschlossen für: $APP_NAME"
log "📁 Base: $BASE_DIR"

echo
echo "=================== DOCKHAND-EINTRAG ==================="
echo "Endpoint : http://${HOST_IP}:${HAWSER_PORT}"
echo "Token    : ${HAWSER_TOKEN}"
echo "(Token gespeichert in: ${TOKEN_FILE})"
echo "========================================================"
echo
echo "➡️ Jetzt in Dockhand als Node hinzufügen (Endpoint + Token)"
