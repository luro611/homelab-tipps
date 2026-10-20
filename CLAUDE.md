# Homelab-Tipps

Öffentliche Sammlung von Anleitungen und kleinen Skripten für das Homelab (Proxmox, LXC, Docker), die auch anderen helfen sollen. Jede Anleitung gibt es auf Deutsch und Englisch; vorgestellt werden sie auf lurohome.de unter „Tipps“.

## Aufbau

- Ein Ordner pro Tipp, z. B. `docker-hawser-lxc/`.
- Darin `anleitung.md` (Deutsch), `guide.en.md` (Englisch) und ggf. ein Skript (z. B. `install-docker.sh`).
- `README.md` führt alle Tipps in einer Tabelle (Deutsch, Englisch, Skript) und enthält den Haftungshinweis.

## Projekt-Eckdaten

- **Plattform:** GitHub `luro611/homelab-tipps`, **öffentlich**.
- **Lizenz:** MIT (siehe `LICENSE`).
- **Sprachen:** zweisprachig DE/EN; Meldungen der Skripte sind bisher auf Deutsch, die englische Anleitung erklärt sie.

## Verwandte Projekte

- `Projekte/Webseiten/lurohome`: die Website lurohome.de zeigt die Anleitungen an. `src/build.py` liest die Markdown-Dateien aus diesem Repo (Ordner `homelab-tipps` neben `lurohome` oder eine Ebene höher), wandelt sie mit einem eigenen kleinen Markdown-Umsetzer in HTML um und verlinkt Skripte über GitHub. Neue Tipps müssen dort in der Liste `TIPPS` eingetragen werden. Vor Änderungen an Ordnern, Dateinamen oder Markdown-Aufbau prüfen, was `build.py` erwartet.
- `Projekte/lxc-forge`: baut auf `docker-hawser-lxc/` auf und geht weiter (LXC selbst anlegen, Dockhand-Anbindung).

## Regeln

- Neuer Tipp = neuer Ordner mit beiden Sprachfassungen (`anleitung.md` und `guide.en.md`); Tabelle in `README.md` ergänzen.
- Das Repo ist öffentlich: keine Zugangsdaten, Tokens, echten IP-Adressen, Hostnamen, LXC-Nummern oder sonstigen Systemdaten. In Beispielen nur Platzhalter verwenden.
- Skripte und Anleitungen vor dem Veröffentlichen auf Geheimnisse und private Angaben prüfen.
- Beide Sprachfassungen inhaltlich gleich halten; eine Änderung an der einen auch in der anderen nachziehen.
