# Claude Code Cockpit

Browserbasierte Remote-Bedienung einer Claude-Code-Session auf einem Home-Assistant-OS-Pi — erreichbar von Smartphone oder Laptop über ein VPN-Mesh (Netbird, Tailscale o. ä.).

Damit lassen sich Home-Assistant-Konfigurationen unterwegs analysieren, planen und (in Phase 2) auch ändern, ohne SSH-Client oder lokale IDE.

## Architektur

```
[Smartphone/Laptop]  ──VPN-Mesh──>  [Pi: <vpn-ip>:7681]
                                          │
                                  ┌───────▼────────────────────────┐
                                  │ Docker Container               │
                                  │  claude-cockpit (Host-Network) │
                                  │                                │
                                  │  ttyd ── tmux ── claude        │
                                  │                                │
                                  │  Volumes:                      │
                                  │   /workspace        ←─ Repo    │
                                  │   /home/cockpit/.claude ←─ Auth│
                                  │   /secrets             ←─ creds│
                                  └────────────────────────────────┘
```

| Komponente | Rolle |
|---|---|
| **ttyd** | Web-Terminal, bindet ausschließlich auf das VPN-Interface |
| **tmux** | Persistente Session, geteilt zwischen Smartphone und Laptop |
| **Claude Code CLI** | KI-gestützte Analyse / Planung im gemounteten Workspace |
| **Docker Container** | Standalone-Stack auf dem Pi, unabhängig vom HA-Lifecycle |

## Voraussetzungen

- **Home Assistant OS** auf Raspberry Pi 5 (oder vergleichbar ARM64) mit Advanced-SSH-Add-on
- `sudo` ohne Passwort (NOPASSWD) für den SSH-User — Standard auf HA OS
- **VPN-Mesh aktiv** auf dem Pi und allen Zugriffsgeräten (entwickelt mit Netbird, Tailscale sollte analog funktionieren)
- **Anthropic-Subscription** (Pro/Max/Team) **oder** API-Key (`sk-ant-...`)
- Auf dem Build-Host: Git-Bash oder WSL (Windows), bash + ssh + openssl

> Hinweis: HA OS bringt weder `docker compose` (V2-Plugin) noch `docker-compose` (V1-Binary) mit. `deploy.sh` nutzt deshalb direkt `sudo docker build` + `sudo docker run`. Die `docker-compose.yml` dient nur als Konfigurations-Referenz.

## Schnellstart

### 1. Repo klonen und Konfiguration anlegen

```bash
git clone https://github.com/<dein-user>/claude-cockpit.git
cd claude-cockpit
cp deploy.config.example deploy.config
# deploy.config in einem Editor anpassen (PI_HOST, PI_USER, NETBIRD_IFACE etc.)
```

### 2. Verzeichnisstruktur und Auth-Files auf Pi anlegen

Verzeichnisse werden von `deploy.sh` automatisch erstellt. Manuell vorab nur, wenn Auth-Files zuerst abgelegt werden sollen:

```bash
ssh -p <PI_PORT> <PI_USER>@<PI_HOST> \
  "sudo mkdir -p /homeassistant/claude-cockpit/{claude-config,secrets} && \
   sudo chmod 700 /homeassistant/claude-cockpit/secrets && \
   sudo chown -R <PI_USER>:<PI_USER> /homeassistant/claude-cockpit"
```

### 3. Subscription-Login

Variante A — Token vom lokalen Laptop kopieren:
```bash
cat ~/.claude/.credentials.json | ssh -p <PI_PORT> <PI_USER>@<PI_HOST> \
  "cat > /homeassistant/claude-cockpit/claude-config/.credentials.json && \
   chmod 600 /homeassistant/claude-cockpit/claude-config/.credentials.json"
```

Variante B — Interaktiver Login: Container starten, dann beim ersten Browser-Zugriff den OAuth-Flow durchlaufen (Login-Methode `1. Claude account with subscription`).

### 4. ttyd-Auth-Token bereitstellen

Variante A — Aus einem Secret-Vault ziehen (siehe `VAULT_GET_CMD` in `deploy.config.example`). `deploy.sh` schreibt den Token dann automatisch auf den Pi.

Variante B — Direkt erzeugen:
```bash
openssl rand -hex 24 | ssh -p <PI_PORT> <PI_USER>@<PI_HOST> \
  "cat > /homeassistant/claude-cockpit/secrets/ttyd.cred && \
   chmod 600 /homeassistant/claude-cockpit/secrets/ttyd.cred"
```

### 5. Deployen

```bash
./deploy.sh
```

Das Script überträgt den Code-Stack, baut das Image (~3–4 Min beim ersten Mal) und startet den Container.

### 6. Zugriff

| Parameter | Wert |
|---|---|
| URL | `http://<pi-vpn-ip>:7681` |
| Benutzer | `cockpit` (konfigurierbar) |
| Passwort | Inhalt von `/homeassistant/claude-cockpit/secrets/ttyd.cred` |

VPN-IP des Pi:
```bash
ssh -p <PI_PORT> <PI_USER>@<PI_HOST> "ip -4 addr show wt0"
```

Beim ersten Browser-Zugriff zeigt Claude Code einen Theme-Wizard und Security-Notes — beide mit Enter durchklicken.

## Sicherheits-Konzept

### Default: Full-Power-Modus

Claude Code startet im Cockpit-Container mit `--dangerously-skip-permissions`. Damit sind **alle** Tool-Restriktionen aufgehoben — keine Permission-Prompts, kein Filter über `settings.json`. Claude darf im Container schreiben, editieren, beliebige Bash-Befehle ausführen und HTTP-Aufrufe machen.

Begründung: Cockpit wird produktiv für Analyse **und** Code-Änderungen genutzt; die Read-only-Phase aus dem ursprünglichen Plan hat sich in der Praxis als reibend erwiesen. Stattdessen kommt die Sicherheitsschicht vom **Container-Sandboxing**:

| Was bleibt geschützt | Warum |
|---|---|
| Live-HA-Configs (`/homeassistant/automations/`, Templates) | nicht ins Volume gemountet |
| SSH zum Pi-Host | kein SSH-Key im Container |
| `sudo` auf dem Pi | `sudo` ist nicht im Image installiert |
| Docker-Daemon-Operationen | Socket nicht im Container gemountet |
| `/secrets/*` | read-only Mount, kann nicht überschrieben werden |

Schreibzugriff von Claude betrifft praktisch nur das gemountete `/workspace` (= Repo-Mirror auf dem Pi). Git-History trackt alles, Rollback ist immer möglich.

### `settings.json` als Fallback

`claude-config/settings.json` enthält weiterhin die ursprünglichen Read-only-Permissions. Solange `--dangerously-skip-permissions` aktiv ist, hat das keine Wirkung. Wer den Container ohne das Flag starten möchte (z. B. um auf eine reine Analyse-Stufe zurückzufallen), entfernt das Flag in `entrypoint.sh` — die Restriktionen greifen dann sofort wieder.

### Auth-Layer

1. **VPN-Mesh** (Netbird/Tailscale) als primäre Authentifizierungsschicht — kein öffentlicher Endpoint.
2. **ttyd-HTTP-Basic-Auth** als zweite Schicht — User + Token aus der `secrets/ttyd.cred`-Datei.
3. **Anthropic-Auth** über persistente `.credentials.json` (Subscription) oder `anthropic.key` (API-Key) im gemounteten Volume.

### Optional: Home-Assistant-Token

Wenn `/secrets/ha.token` existiert, exportiert `entrypoint.sh` den Inhalt als Umgebungsvariable `HA_TOKEN` in die tmux-Session. Claude kann damit ohne weitere Konfiguration gegen die HA REST API gehen (`curl -H "Authorization: Bearer $HA_TOKEN" http://localhost:8123/api/...`).

Empfehlung: Long-Lived Access Token in HA generieren (Profil → Sicherheit), in den Vault legen, beim Deploy ins secrets-Volume schreiben:

```bash
vault get HA_TOKEN | ssh ... "cat > /homeassistant/claude-cockpit/secrets/ha.token && chmod 600 ..."
```

Damit hat Claude im Cockpit Vollzugriff auf HA-Entitäten — bewusste Entscheidung, weil der Container-Stack ohnehin produktiv genutzt wird.

### Secrets-Management

Geheime Daten (ttyd-Token, API-Keys, HA-Token) dürfen **niemals** ins Repo committed werden. `.gitignore` schließt das `secrets/`-Verzeichnis und alle `*.cred`/`*.key`-Dateien aus.

Für die Token-Verwaltung empfiehlt sich ein verschlüsselter Secret-Vault (z. B. `cryptography.fernet`-basiert). Die Vault-Integration in `deploy.sh` ist über `VAULT_GET_CMD` aktivierbar.

## Auth-Modus umschalten

Im laufenden Container:

```bash
sudo docker exec -it claude-cockpit claude-mode api
sudo docker exec -it claude-cockpit claude-mode subscription
```

`claude-mode` ohne Argument zeigt den aktuellen Modus.

## Troubleshooting

**Logs ansehen:**
```bash
ssh -p <PI_PORT> <PI_USER>@<PI_HOST> "sudo docker logs -f claude-cockpit"
```

**Container neu starten (ohne Rebuild):**
```bash
ssh -p <PI_PORT> <PI_USER>@<PI_HOST> "sudo docker restart claude-cockpit"
```

**ttyd nicht erreichbar:**
1. VPN auf Zugriffsgerät aktiv?
2. Container läuft? `sudo docker ps --filter name=claude-cockpit`
3. Port 7681 gebunden? `sudo ss -tlnp | grep 7681` auf dem Pi
4. VPN-IP des Pi korrekt? `ip -4 addr show <NETBIRD_IFACE>`

**Versehentliche tmux-Splits oder Pane-Wechsel:**

Tmux-Prefix ist `Strg+B`. Versehentliches Drücken kann Pane-Layout ändern. Schnelle Wiederherstellung: Container restart (`sudo docker restart claude-cockpit`) — startet frische Session, persistente Daten (`.credentials.json`, `settings.json`) bleiben erhalten.

**Maus-Selektion funktioniert nicht:**

Tmux fängt Mausereignisse ab. Lösungen:
- **`Shift` halten beim Markieren** → Browser-Native-Selektion (überall verfügbar)
- Tmux-`set-clipboard on` ist aktiv → Selektion landet via OSC52 im System-Clipboard

## Roadmap

### Umgesetzt
- Browser-Terminal über VPN-Mesh (Netbird/Tailscale)
- Persistente tmux-Session, geteilt zwischen mehreren Geräten
- Subscription- + API-Auth-Modus, umschaltbar zur Laufzeit (`claude-mode`)
- Full-Power-Modus über `--dangerously-skip-permissions` (Default)
- Optionale Home-Assistant-Token-Injektion (`/secrets/ha.token`)
- Vault-Integration im `deploy.sh` (`VAULT_GET_CMD`)

### Mögliche Erweiterungen
- Confirm-UI für gefährliche Aktionen (Diff-Viewer, Apply-Button) — falls man eine Stufe zwischen "alles erlauben" und "gar nichts erlauben" möchte
- Eigene Web-UI als Aufsatz auf ttyd, falls Mobile-Bedienkomfort wichtig wird
- Audit-Log für ausgeführte Bash-Befehle

### Out of Scope
- Datenpipeline für historische HA-Daten (InfluxDB/Parquet) — gehört in ein separates Projekt
- Multi-Tenant-Setup
- Eigene Anthropic-Modell-Hosting-Schicht

## Lizenz

MIT — siehe [LICENSE](LICENSE).

## Verwandte Doku

Die Plattform-Eigenheiten von HA OS (Pfad-Dualismus, fehlendes `docker compose`, UID-Konflikte mit `node:20-bookworm-slim`) sind im README oben kurz angerissen. Eine ausführliche Aufstellung steht in einem Begleit-Dokument im Repo des Anwenders (`home-assistant-v2`), das diese Cockpit-Variante produktiv betreibt.
