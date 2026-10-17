# 🐳 Installing Docker and Hawser in a Debian 13 LXC for Dockhand

This guide describes how to prepare an **existing Debian 13 LXC** so that its Docker containers can later be managed with **Dockhand**.

The install script does the following:

- updates Debian and installs the required tools,
- installs Docker if it is not already present,
- creates a directory structure for the application in question,
- pulls the Hawser image,
- creates a Hawser token or reuses an existing one,
- starts the Hawser agent as a Docker container,
- shows the endpoint and token for the Dockhand entry.

> **Important:** This guide installs Docker and Hawser in the existing LXC. The actual Docker applications are set up separately with Dockhand afterwards.

> **Note:** The messages the script prints are in German. The English explanations below describe what each of them means.

---

## ✅ Prerequisites

Before you start, the following should be true:

- The Debian 13 LXC has already been created and started.
- You can log in to the LXC as `root`.
- The LXC has network access and can reach the package sources and the container image.
- The LXC is configured in Proxmox so that Docker can run inside it.
- You know which name you want to use for the application folder, for example `paperless`.

> ⚠️ Whether Docker works inside an LXC also depends on the LXC configuration and the security options of the host. This guide does not change the Proxmox LXC configuration.

---

## 🧭 Overview

1. Create a script file in the LXC.
2. Paste the script and save it.
3. Make the script executable.
4. Run the script as `root`.
5. Note down the endpoint and token.
6. Add the Hawser agent to Dockhand as a node.

---

## 1. 📄 Create the script file

Log in to the Debian LXC as `root` and create the file:

```bash
nano /root/install-docker.sh
```

Then paste the complete script below into the editor.

**Alternative without copying:** You can also download the script straight from GitHub and make it executable. Steps 1 to 4 are then not needed; continue with step 5.

```bash
wget -O /root/install-docker.sh https://raw.githubusercontent.com/luro611/homelab-tipps/main/docker-hawser-lxc/install-docker.sh
chmod +x /root/install-docker.sh
```

---

## 2. 📜 Install script

The script is the same as in the German guide; its comments and messages are in German. You can also open it as a separate file: [install-docker.sh](install-docker.sh).

```bash
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
```

---

## 3. 💾 Save the file

In `nano`:

1. Press `CTRL + O`.
2. Press `ENTER` to confirm the file name.
3. Press `CTRL + X` to close the editor.

---

## 4. 🔑 Make the script executable

```bash
chmod +x /root/install-docker.sh
```

---

## 5. ▶️ Run the script

```bash
/root/install-docker.sh
```

The script asks for a name for the LXC or stack, for example:

```text
paperless
```

The name is converted to lower case. Characters other than `a-z`, `0-9`, `-` or `_` are removed.

> **Note:** If the input consists only of characters that get removed, the cleaned-up name can end up empty. So enter a simple name such as `paperless`, `immich` or `nextcloud`.

---

# 🔍 What each part of the script does

## 🛡️ Start and root check

```bash
#!/bin/bash
set -euo pipefail
```

- `#!/bin/bash` sets Bash as the interpreter.
- `set -e` stops the script on any error that is not handled.
- `set -u` treats unset variables as an error.
- `set -o pipefail` makes sure errors inside a pipeline with `|` are detected as well.

Next, the script checks whether it is running with root privileges. If not, it prints an error message and exits.

```bash
export DEBIAN_FRONTEND=noninteractive
```

This setting prevents Debian package installers from asking interactive questions during installation.

---

## 🏷️ Name for the LXC or application

The script asks for a name:

```bash
read -rp "👉 Name für diesen LXC / Stack (z.B. paperless): " APP_NAME
```

Among other things, this name determines the directories and the name of the log file. It is **not** the name of the Hawser container, which is fixed in the script:

```bash
CONTAINER_NAME="hawser-agent"
```

---

## 📁 Directory structure

If you enter `paperless`, the following variables are set:

```bash
BASE_ROOT="/opt/containers"
BASE_DIR="$BASE_ROOT/$APP_NAME"
DATA_DIR="$BASE_DIR/data"
VOLUMES_DIR="$BASE_DIR/volumes"
CONFIGS_DIR="$BASE_DIR/configs"
```

This results in:

```text
/opt/containers/                    root directory for applications
└── paperless/                      BASE_DIR
    ├── data/                       DATA_DIR
    ├── volumes/                    VOLUMES_DIR
    └── configs/                    CONFIGS_DIR
```

### 📂 What are the folders for?

- **`data/`** – intended for persistent application data.
- **`volumes/`** – intended for data that is mounted into Docker containers as bind mounts.
- **`configs/`** – intended for configuration files.

> The script creates these folders but does **not** mount them into later application containers automatically. That is done later in the Dockhand configuration of each application.

---

## 📝 Logging

```bash
LOG_FILE="/var/log/hawser-${APP_NAME}-setup.log"
```

The script creates a separate log file under `/var/log` for each name you enter. For `paperless`, the path is:

```text
/var/log/hawser-paperless-setup.log
```

The script's output is shown in the terminal and appended to the log file at the same time.

---

## 🔄 System update and required tools

The script updates the package lists, installs available updates and removes packages that are no longer needed:

```bash
apt update
apt -y upgrade
apt -y autoremove
```

It then installs the tools the script needs for the Docker step and for creating the token:

```bash
apt install -y curl ca-certificates gnupg lsb-release apt-transport-https openssl
```

---

## 🐳 Install or start Docker

The script first checks whether the `docker` command exists.

- **Docker is not installed yet:** The script adds the Docker package source and installs Docker together with the Compose and Buildx plugins.
- **Docker is already installed:** The script tries to enable and start the Docker service.

The service is enabled and started with:

```bash
systemctl enable --now docker
```

`enable` makes Docker start automatically whenever the LXC starts. `--now` starts the service right away.

> The script only checks whether the `docker` program exists. It does not fully compare the version or functionality of an existing Docker installation.

---

## 📁 Create folders and set permissions

```bash
mkdir -p "$DATA_DIR" "$VOLUMES_DIR" "$CONFIGS_DIR"
chmod -R 755 "$BASE_DIR"
chown -R root:root "$BASE_DIR"
```

### What do these commands do?

- `mkdir -p` creates the directories including any parent folders they need. Directories that already exist do not cause an error just because they exist.
- `chmod -R 755` recursively sets the permissions below `BASE_DIR` to `755`.
- `chown -R root:root` recursively sets owner and group to `root`.

With `755`, the owner may read, write and enter directories; the group and other users may read and enter directories.

> ⚠️ **Important for later applications:** The script sets permissions and ownership for the whole app folder again **on every run**. So it does not leave existing permissions alone. If an application needs files with its own UID or GID, set the matching ownership specifically afterwards. Running the script again re-applies the recursive settings.

Example for an application that is meant to run with UID and GID `1000`:

```bash
chown -R 1000:1000 /opt/containers/paperless
```

Do **not** use this command blindly: the IDs you need depend on the application.

---

## 📦 Pull the Hawser image

```bash
HAWSER_IMAGE="ghcr.io/finsys/hawser:latest"
docker pull "$HAWSER_IMAGE"
```

The image is pulled from the container registry given here. If the download fails, the script writes a warning to the log and carries on.

> A failed image pull can prevent the Hawser container from starting afterwards if the image is not already available locally. In that case, check the Docker and Hawser logs and try pulling the image again.

---

## 🔑 Create or reuse the Hawser token

The token is stored at:

```text
/opt/containers/<APP_NAME>/hawser.token
```

Example:

```text
/opt/containers/paperless/hawser.token
```

- If the file already exists and is not empty, its content is reused.
- Otherwise a new token is created and saved to the file.

The token is an access key for the connection to Hawser. **Keep it confidential** and do not share it publicly.

---

## 🚀 Start the Hawser container

Before starting, the script removes any existing container named `hawser-agent`:

```bash
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
```

Hawser is then started:

```bash
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p ${HAWSER_PORT}:2376 \
  -e TOKEN="$HAWSER_TOKEN" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "$HAWSER_IMAGE"
```

### What the main options mean

- `-d` – runs the container in the background.
- `--name hawser-agent` – sets the container name.
- `--restart unless-stopped` – Docker starts the container again after a restart unless it was stopped explicitly.
- `-p 2376:2376` – publishes port `2376` of the container on port `2376` of the LXC.
- `-e TOKEN=...` – passes the token as an environment variable.
- `-v /var/run/docker.sock:/var/run/docker.sock` – gives the Hawser container access to the LXC's Docker socket.

> ⚠️ The Docker socket gives far-reaching control over Docker in the LXC. Protect access to the Hawser agent and only give the endpoint and token to people or systems you trust. Also check whether network access to the published port is protected well enough in your environment.

After starting it, the script waits three seconds and checks whether the Hawser container is running. If it is not, it prints the last container logs and exits with an error.

---

## 🌐 Determine the endpoint

The script takes the first IP address printed by `hostname -I`:

```bash
HOST_IP="$(hostname -I | awk '{print $1}')"
```

It then prints the endpoint in this form:

```text
http://<IP-address-of-the-LXC>:2376
```

> If the LXC has several network interfaces or IP addresses, the first address picked automatically may not be the one Dockhand can reach. In that case, check the address shown and use the one that is reachable from the Dockhand server.

---

# 🔗 Add Hawser to Dockhand

When the script finishes successfully, it shows a block similar to this one (`DOCKHAND-EINTRAG` means “Dockhand entry”):

```text
=================== DOCKHAND-EINTRAG ===================
Endpoint : http://192.168.1.50:2376
Token    : <your-token>
(Token gespeichert in: /opt/containers/paperless/hawser.token)
========================================================
```

Enter the values shown in Dockhand as a Hawser node:

- **Endpoint:** the address shown, for example `http://192.168.1.50:2376`
- **Token:** the token shown by the script

The endpoint must be reachable from the system Dockhand runs on. If no connection can be made, check in particular:

1. Is the Hawser container running?
2. Is the IP address the right one?
3. Can port `2376` be reached from the Dockhand system?
4. Do the endpoint and token match exactly?
5. Is a firewall or an LXC network setting blocking the connection?

---

## 🔎 Status and troubleshooting

### Check Docker status

```bash
systemctl status docker
```

### Show the Hawser container

```bash
docker ps -a --filter name=hawser-agent
```

### Show the Hawser logs

```bash
docker logs hawser-agent
```

### Show the setup log

Replace `paperless` with the name you entered at the start:

```bash
cat /var/log/hawser-paperless-setup.log
```

Each further run appends to the log.

---

# 🗂️ Using NFS shares

If a Docker application later needs to access an NFS share, an NFS client must be installed in the LXC:

```bash
apt-get update
apt-get install -y nfs-common
```

This installs the NFS client in the LXC. **Mounting the NFS share** and using it as a Docker bind mount are separate steps that this Hawser install script does not set up.

---

# 🧩 More on the directory structure

## Example with `paperless`

If you enter `paperless` when the script starts, this structure is created:

```text
/opt/containers/paperless/
├── data/
├── volumes/
├── configs/
└── hawser.token
```

The folders can later be used as bind mounts in a Docker configuration, for example. A general example:

```text
/opt/containers/paperless/data:/path/inside/the/application/container
```

The target path inside the container has to match the application. It is not the same for every application.

> The directories created by the script are a prepared structure. The script neither creates a Docker Compose file for Paperless nor starts Paperless itself.

---

## 🔁 Running the script again

You can run the script again. In that case:

- An existing Hawser token is reused, as long as the token file exists and is not empty.
- An existing container named `hawser-agent` is removed and then created again.
- The folders are created again if they are missing.
- Permissions and ownership below `BASE_DIR` are again set recursively to `755` and `root:root`.
- The system packages are updated again.

> **Caution:** Because the Hawser container is removed and recreated on every run, running the script again can briefly interrupt the Hawser agent.

---

## 🏁 Done

When the script has finished successfully, Docker and the Hawser agent are ready in the Debian 13 LXC. Store the endpoint and token safely and add the agent to Dockhand as a node.

The actual applications and their volumes, networks and configurations are then set up in Dockhand.
