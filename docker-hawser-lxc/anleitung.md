# 🐳 Docker und Hawser in einem Debian-13-LXC für Dockhand installieren

Diese Anleitung beschreibt die Vorbereitung eines **bereits vorhandenen Debian-13-LXC** für die spätere Verwaltung von Docker-Containern mit **Dockhand**.

Das Installationsscript erledigt Folgendes:

- aktualisiert Debian und installiert benötigte Werkzeuge,
- installiert Docker, sofern Docker noch nicht vorhanden ist,
- legt eine Verzeichnisstruktur für die betreffende Anwendung an,
- lädt das Hawser-Image,
- erzeugt oder übernimmt ein Hawser-Token,
- startet den Hawser-Agenten als Docker-Container,
- zeigt Endpoint und Token für den Dockhand-Eintrag an.

> **Wichtig:** Diese Anleitung installiert Docker und Hawser im vorhandenen LXC. Die eigentlichen Docker-Anwendungen werden anschließend separat mit Dockhand eingerichtet.

---

## ✅ Voraussetzungen

Vor dem Start sollten folgende Punkte erfüllt sein:

- Der Debian-13-LXC ist bereits erstellt und gestartet.
- Du kannst dich als `root` im LXC anmelden.
- Der LXC hat Netzwerkzugriff und kann Paketquellen sowie das Container-Image erreichen.
- In der Proxmox-Konfiguration ist der LXC so eingerichtet, dass Docker darin betrieben werden kann.
- Du kennst den Namen, den du für den Anwendungsordner verwenden möchtest, zum Beispiel `paperless`.

> ⚠️ Ob Docker innerhalb eines LXC funktioniert, hängt auch von der LXC-Konfiguration und den Sicherheitsoptionen des Hosts ab. Diese Anleitung ändert die Proxmox-LXC-Konfiguration nicht.

---

## 🧭 Ablauf

1. Im LXC eine Script-Datei anlegen.
2. Das Script einfügen und speichern.
3. Das Script ausführbar machen.
4. Das Script als `root` ausführen.
5. Endpoint und Token notieren.
6. Den Hawser-Agenten in Dockhand als Node hinzufügen.

---

## 1. 📄 Script-Datei erstellen

Melde dich im Debian-LXC als `root` an und erstelle die Datei:

```bash
nano /root/install-docker.sh
```

Füge anschließend das folgende Script vollständig in den Editor ein.

**Alternative ohne Kopieren:** Du kannst das Script auch direkt von GitHub herunterladen und ausführbar machen. Dann entfallen die Schritte 1 bis 4, weiter geht es mit Schritt 5.

```bash
wget -O /root/install-docker.sh https://raw.githubusercontent.com/luro611/homelab-tipps/main/docker-hawser-lxc/install-docker.sh
chmod +x /root/install-docker.sh
```

---

## 2. 📜 Installationsscript

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

## 3. 💾 Datei speichern

In `nano`:

1. `CTRL + O` drücken.
2. Mit `ENTER` den Dateinamen bestätigen.
3. `CTRL + X` drücken, um den Editor zu schließen.

---

## 4. 🔑 Script ausführbar machen

```bash
chmod +x /root/install-docker.sh
```

---

## 5. ▶️ Script ausführen

```bash
/root/install-docker.sh
```

Das Script fragt nach einem Namen für den LXC beziehungsweise Stack, zum Beispiel:

```text
paperless
```

Der eingegebene Name wird in Kleinbuchstaben umgewandelt. Zeichen, die nicht zu `a-z`, `0-9`, `-` oder `_` gehören, werden entfernt.

> **Hinweis:** Wenn die Eingabe ausschließlich aus Zeichen besteht, die entfernt werden, kann der bereinigte Name leer sein. Gib daher einen einfachen Namen wie `paperless`, `immich` oder `nextcloud` ein.

---

# 🔍 Erklärung der Script-Abschnitte

## 🛡️ Start und Root-Prüfung

```bash
#!/bin/bash
set -euo pipefail
```

- `#!/bin/bash` legt Bash als Interpreter fest.
- `set -e` beendet das Script bei einem nicht abgefangenen Fehler.
- `set -u` behandelt nicht gesetzte Variablen als Fehler.
- `set -o pipefail` sorgt dafür, dass auch Fehler innerhalb einer Befehlskette mit `|` erkannt werden.

Anschließend wird geprüft, ob das Script mit Root-Rechten ausgeführt wird. Ist das nicht der Fall, erscheint eine Fehlermeldung und das Script beendet sich.

```bash
export DEBIAN_FRONTEND=noninteractive
```

Diese Einstellung verhindert bei der Paketinstallation interaktive Rückfragen von Debian-Paketinstallern.

---

## 🏷️ Name für LXC beziehungsweise Anwendung

Das Script fragt nach einem Namen:

```bash
read -rp "👉 Name für diesen LXC / Stack (z.B. paperless): " APP_NAME
```

Dieser Name dient unter anderem dazu, die Verzeichnisse und den Logdateinamen zu bestimmen. Er ist **nicht** der Name des Hawser-Containers. Dieser heißt im Script fest:

```bash
CONTAINER_NAME="hawser-agent"
```

---

## 📁 Verzeichnisstruktur

Bei der Eingabe `paperless` werden folgende Variablen gesetzt:

```bash
BASE_ROOT="/opt/containers"
BASE_DIR="$BASE_ROOT/$APP_NAME"
DATA_DIR="$BASE_DIR/data"
VOLUMES_DIR="$BASE_DIR/volumes"
CONFIGS_DIR="$BASE_DIR/configs"
```

Daraus ergibt sich:

```text
/opt/containers/                    Wurzelverzeichnis für Anwendungen
└── paperless/                      BASE_DIR
    ├── data/                       DATA_DIR
    ├── volumes/                    VOLUMES_DIR
    └── configs/                    CONFIGS_DIR
```

### 📂 Wofür sind die Ordner gedacht?

- **`data/`** – vorgesehener Ablageort für persistente Anwendungsdaten.
- **`volumes/`** – vorgesehener Ablageort für Daten, die als Bind-Mounts in Docker-Container eingebunden werden.
- **`configs/`** – vorgesehener Ablageort für Konfigurationsdateien.

> Das Script legt diese Ordner an, bindet sie aber **nicht automatisch** in spätere Anwendungscontainer ein. Die Einbindung erfolgt später in der Dockhand-Konfiguration der jeweiligen Anwendung.

---

## 📝 Protokollierung

```bash
LOG_FILE="/var/log/hawser-${APP_NAME}-setup.log"
```

Das Script legt für jeden eingegebenen Namen eine eigene Logdatei unter `/var/log` an. Bei `paperless` lautet der Pfad beispielsweise:

```text
/var/log/hawser-paperless-setup.log
```

Die Ausgabe des Scripts wird sowohl im Terminal angezeigt als auch an die Logdatei angehängt.

---

## 🔄 Systemupdate und benötigte Werkzeuge

Das Script aktualisiert die Paketlisten, installiert verfügbare Updates und entfernt nicht mehr benötigte Pakete:

```bash
apt update
apt -y upgrade
apt -y autoremove
```

Danach werden Werkzeuge installiert, die das Script für den Docker-Schritt und die Token-Erzeugung benötigt:

```bash
apt install -y curl ca-certificates gnupg lsb-release apt-transport-https openssl
```

---

## 🐳 Docker installieren oder starten

Das Script prüft zunächst, ob der Befehl `docker` vorhanden ist.

- **Docker ist noch nicht installiert:** Das Script richtet den Docker-Paketquelleneintrag ein und installiert Docker sowie die Compose- und Buildx-Plugins.
- **Docker ist bereits installiert:** Das Script versucht, den Docker-Dienst zu aktivieren und zu starten.

Der Dienst wird mit folgendem Befehl aktiviert und gestartet:

```bash
systemctl enable --now docker
```

`enable` sorgt dafür, dass Docker beim Start des LXC automatisch gestartet wird. `--now` startet den Dienst direkt.

> Das Script prüft, ob das Programm `docker` vorhanden ist. Es ist kein vollständiger Versions- oder Funktionsvergleich einer bereits vorhandenen Docker-Installation.

---

## 📁 Ordner anlegen und Berechtigungen setzen

```bash
mkdir -p "$DATA_DIR" "$VOLUMES_DIR" "$CONFIGS_DIR"
chmod -R 755 "$BASE_DIR"
chown -R root:root "$BASE_DIR"
```

### Was bedeuten die Befehle?

- `mkdir -p` erstellt die Verzeichnisse einschließlich der benötigten übergeordneten Ordner. Bereits vorhandene Verzeichnisse führen dabei nicht allein deshalb zu einem Fehler.
- `chmod -R 755` setzt rekursiv die Berechtigungen unterhalb von `BASE_DIR` auf `755`.
- `chown -R root:root` setzt rekursiv Eigentümer und Gruppe auf `root`.

Bei `755` darf der Eigentümer lesen, schreiben und Verzeichnisse betreten; Gruppe und andere Benutzer dürfen lesen und Verzeichnisse betreten.

> ⚠️ **Wichtig bei späteren Anwendungen:** Das Script setzt die Berechtigungen und Eigentümer **bei jedem Lauf erneut** für den gesamten App-Ordner. Es ist daher nicht richtig zu sagen, dass es bestehende Berechtigungen „nicht unnötig überschreibt“. Wenn eine Anwendung Dateien mit einer eigenen UID oder GID benötigt, müssen die passenden Besitzrechte anschließend gezielt eingerichtet werden. Bei einem erneuten Scriptlauf werden die rekursiven Einstellungen erneut angewendet.

Beispiel für eine Anwendung, die mit UID und GID `1000` arbeiten soll:

```bash
chown -R 1000:1000 /opt/containers/paperless
```

Diesen Befehl **nicht blind** verwenden: Die benötigten IDs hängen von der jeweiligen Anwendung ab.

---

## 📦 Hawser-Image herunterladen

```bash
HAWSER_IMAGE="ghcr.io/finsys/hawser:latest"
docker pull "$HAWSER_IMAGE"
```

Das Image wird aus der angegebenen Container-Registry geladen. Falls der Download fehlschlägt, schreibt das Script eine Warnung ins Log und fährt weiter.

> Ein fehlgeschlagener Image-Pull kann den anschließenden Start des Hawser-Containers verhindern, wenn das benötigte Image lokal nicht bereits vorhanden ist. In diesem Fall die Docker- und Hawser-Logs prüfen und den Image-Pull erneut versuchen.

---

## 🔑 Hawser-Token erzeugen oder wiederverwenden

Das Token wird unter folgendem Pfad gespeichert:

```text
/opt/containers/<APP_NAME>/hawser.token
```

Beispiel:

```text
/opt/containers/paperless/hawser.token
```

- Ist die Datei bereits vorhanden und nicht leer, wird ihr Inhalt wiederverwendet.
- Andernfalls wird ein neues Token erzeugt und in der Datei gespeichert.

Das Token ist ein Zugangsschlüssel für die Verbindung mit Hawser. **Behandle es vertraulich** und teile es nicht öffentlich.

---

## 🚀 Hawser-Container starten

Vor dem Start entfernt das Script einen eventuell bereits vorhandenen Container namens `hawser-agent`:

```bash
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
```

Anschließend wird Hawser gestartet:

```bash
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p ${HAWSER_PORT}:2376 \
  -e TOKEN="$HAWSER_TOKEN" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "$HAWSER_IMAGE"
```

### Bedeutung der wichtigsten Optionen

- `-d` – startet den Container im Hintergrund.
- `--name hawser-agent` – vergibt den Containernamen.
- `--restart unless-stopped` – Docker startet den Container nach einem Neustart erneut, sofern er nicht ausdrücklich gestoppt wurde.
- `-p 2376:2376` – veröffentlicht Port `2376` des Containers auf Port `2376` des LXC.
- `-e TOKEN=...` – übergibt das Token als Umgebungsvariable.
- `-v /var/run/docker.sock:/var/run/docker.sock` – stellt dem Hawser-Container den Docker-Socket des LXC bereit.

> ⚠️ Der Docker-Socket ermöglicht weitreichende Kontrolle über Docker im LXC. Schütze den Zugang zum Hawser-Agenten und gib Endpoint und Token nur an vertrauenswürdige Personen beziehungsweise Systeme weiter. Prüfe außerdem, ob die Netzwerkverbindung zum veröffentlichten Port in deiner Umgebung ausreichend geschützt ist.

Nach dem Start wartet das Script drei Sekunden und prüft, ob der Hawser-Container läuft. Falls nicht, gibt es die letzten Container-Logs aus und beendet sich mit einem Fehler.

---

## 🌐 Endpoint ermitteln

Das Script nimmt die erste von `hostname -I` ausgegebene IP-Adresse:

```bash
HOST_IP="$(hostname -I | awk '{print $1}')"
```

Anschließend wird der Endpoint nach diesem Schema ausgegeben:

```text
http://<IP-Adresse-des-LXC>:2376
```

> Wenn der LXC mehrere Netzwerkinterfaces oder IP-Adressen besitzt, ist die automatisch ausgewählte erste Adresse möglicherweise nicht die Adresse, unter der Dockhand den LXC erreichen kann. Prüfe in diesem Fall die angezeigte IP-Adresse und verwende für Dockhand die passende, vom Dockhand-Server aus erreichbare Adresse.

---

# 🔗 Hawser in Dockhand hinzufügen

Nach erfolgreichem Abschluss zeigt das Script einen Abschnitt ähnlich diesem an:

```text
=================== DOCKHAND-EINTRAG ===================
Endpoint : http://192.168.1.50:2376
Token    : <dein-token>
(Token gespeichert in: /opt/containers/paperless/hawser.token)
========================================================
```

Trage in Dockhand die angezeigten Werte als Hawser-Node ein:

- **Endpoint:** die angezeigte Adresse, zum Beispiel `http://192.168.1.50:2376`
- **Token:** das vom Script angezeigte Token

Der Endpoint muss vom System, auf dem Dockhand läuft, erreichbar sein. Wenn keine Verbindung zustande kommt, prüfe insbesondere:

1. Läuft der Hawser-Container?
2. Ist die verwendete IP-Adresse die richtige?
3. Ist Port `2376` vom Dockhand-System aus erreichbar?
4. Stimmen Endpoint und Token exakt?
5. Gibt es eine Firewall- oder LXC-Netzwerkeinstellung, die die Verbindung blockiert?

---

## 🔎 Status und Fehlersuche

### Docker-Status prüfen

```bash
systemctl status docker
```

### Hawser-Container anzeigen

```bash
docker ps -a --filter name=hawser-agent
```

### Hawser-Logs anzeigen

```bash
docker logs hawser-agent
```

### Setup-Log anzeigen

Ersetze `paperless` durch den beim Start eingegebenen Namen:

```bash
cat /var/log/hawser-paperless-setup.log
```

Das Log wird bei einem weiteren Lauf ergänzt.

---

# 🗂️ NFS-Shares verwenden

Wenn eine Docker-Anwendung später auf ein NFS-Share zugreifen soll, muss im LXC ein NFS-Client installiert sein:

```bash
apt-get update
apt-get install -y nfs-common
```

Damit ist der NFS-Client im LXC installiert. Das **Einbinden des NFS-Shares** und dessen Verwendung als Docker-Bind-Mount sind separate Schritte und werden von diesem Hawser-Installationsscript nicht automatisch eingerichtet.

---

# 🧩 Ergänzende Hinweise zur Verzeichnisstruktur

## Beispiel mit `paperless`

Wenn beim Scriptstart `paperless` eingegeben wird, entsteht folgende Struktur:

```text
/opt/containers/paperless/
├── data/
├── volumes/
├── configs/
└── hawser.token
```

Die Ordner können später beispielsweise in einer Docker-Konfiguration als Bind-Mounts verwendet werden. Ein allgemeines Beispiel:

```text
/opt/containers/paperless/data:/Pfad/im/Anwendungscontainer
```

Der Zielpfad innerhalb des Containers muss zur jeweiligen Anwendung passen. Er ist nicht für alle Anwendungen gleich.

> Die im Script angelegten Verzeichnisse sind eine vorbereitete Struktur. Das Script erstellt weder eine Docker-Compose-Datei für Paperless noch startet es Paperless selbst.

---

## 🔁 Erneuter Scriptlauf

Das Script kann erneut ausgeführt werden. Dabei gilt:

- Ein vorhandenes Hawser-Token wird wiederverwendet, sofern die Token-Datei vorhanden und nicht leer ist.
- Ein bereits vorhandener Container mit dem Namen `hawser-agent` wird entfernt und anschließend neu erstellt.
- Die Ordner werden erneut angelegt, falls sie fehlen.
- Die Berechtigungen und Eigentümer unter `BASE_DIR` werden erneut rekursiv auf `755` beziehungsweise `root:root` gesetzt.
- Die Systempakete werden erneut aktualisiert.

> **Achtung:** Weil der Hawser-Container bei jedem Lauf entfernt und neu erstellt wird, kann ein erneuter Lauf den Hawser-Agenten kurzzeitig unterbrechen.

---

## 🏁 Abschluss

Nach erfolgreichem Abschluss sind Docker und der Hawser-Agent im Debian-13-LXC vorbereitet. Notiere Endpoint und Token sicher und füge den Agenten in Dockhand als Node hinzu.

Die eigentlichen Anwendungen sowie ihre Volumes, Netzwerke und Konfigurationen werden danach in Dockhand eingerichtet.