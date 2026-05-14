#!/usr/bin/env bash
# deploy.sh — Claude Code Cockpit Deployment
#
# Überträgt den Code-Stack auf das Zielsystem (Pi mit HA OS), baut das Image
# und startet den Container.
#
# Konfiguration über Environment-Variablen oder eine lokale `deploy.config`
# (gitignoriert). Siehe deploy.config.example als Vorlage.
#
# Optional: ttyd-Token aus einem Fernet-Vault ziehen (Variable VAULT_GET_CMD).
#
# Kompatibel mit Git-Bash und WSL auf Windows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Konfiguration laden (deploy.config überschreibt Defaults)
# ---------------------------------------------------------------------------
if [[ -f "${SCRIPT_DIR}/deploy.config" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/deploy.config"
fi

# ---------------------------------------------------------------------------
# Variablen mit Defaults
# ---------------------------------------------------------------------------
PI_HOST="${PI_HOST:-homeassistant.local}"
PI_PORT="${PI_PORT:-22}"
PI_USER="${PI_USER:-root}"

REMOTE_BASE="${REMOTE_BASE:-/homeassistant/claude-cockpit}"
HOST_BASE="${HOST_BASE:-/mnt/data/supervisor/homeassistant/claude-cockpit}"
HOST_WORKSPACE="${HOST_WORKSPACE:-/mnt/data/supervisor/homeassistant}"

NETBIRD_IFACE="${NETBIRD_IFACE:-wt0}"
TTYD_PORT="${TTYD_PORT:-7681}"
TTYD_USER="${TTYD_USER:-cockpit}"
CONTAINER_NAME="${CONTAINER_NAME:-claude-cockpit}"
IMAGE_TAG="${IMAGE_TAG:-claude-cockpit:local}"
CLAUDE_AUTH_MODE="${CLAUDE_AUTH_MODE:-subscription}"

# Optional: Kommando zum Holen des ttyd-Tokens aus einem Vault.
# Beispiel für den Projekt-eigenen Fernet-Vault:
#   VAULT_GET_CMD='C:/Projekte/tools/vault/venv/Scripts/python C:/Projekte/tools/vault/vault.py get CLAUDE_COCKPIT_TTYD_TOKEN'
VAULT_GET_CMD="${VAULT_GET_CMD:-}"

REMOTE_BUILD="${REMOTE_BASE}/build"
SSH_OPTS="-p ${PI_PORT} -o StrictHostKeyChecking=accept-new"
SSH_TARGET="${PI_USER}@${PI_HOST}"

# ---------------------------------------------------------------------------
# Hilfsfunktion: Datei via cat | ssh cat > übertragen
# ---------------------------------------------------------------------------
deploy_file() {
    local local_path="$1"
    local remote_path="$2"
    echo "  -> ${remote_path}"
    cat "${local_path}" | ssh ${SSH_OPTS} "${SSH_TARGET}" "cat > '${remote_path}'"
}

echo "Deploy-Ziel: ${SSH_TARGET}:${PI_PORT}"
echo "Remote-Base: ${REMOTE_BASE}"
echo ""

# ---------------------------------------------------------------------------
# 1. Zielverzeichnisse anlegen
# ---------------------------------------------------------------------------
echo "[1/7] Zielverzeichnisse anlegen..."
ssh ${SSH_OPTS} "${SSH_TARGET}" \
    "sudo mkdir -p '${REMOTE_BUILD}/bin' '${REMOTE_BASE}/claude-config' '${REMOTE_BASE}/secrets' \
        && sudo chmod 700 '${REMOTE_BASE}/secrets' \
        && sudo chown -R ${PI_USER}:${PI_USER} '${REMOTE_BASE}'"

# ---------------------------------------------------------------------------
# 2. Code-Stack übertragen
# ---------------------------------------------------------------------------
echo "[2/7] Dateien übertragen..."
deploy_file "${SCRIPT_DIR}/Dockerfile"          "${REMOTE_BUILD}/Dockerfile"
deploy_file "${SCRIPT_DIR}/docker-compose.yml"  "${REMOTE_BUILD}/docker-compose.yml"
deploy_file "${SCRIPT_DIR}/entrypoint.sh"       "${REMOTE_BUILD}/entrypoint.sh"
deploy_file "${SCRIPT_DIR}/tmux.conf"           "${REMOTE_BUILD}/tmux.conf"
deploy_file "${SCRIPT_DIR}/bin/claude-mode"     "${REMOTE_BUILD}/bin/claude-mode"

# settings.json gehört in das persistente claude-config-Volume, nicht in build/
deploy_file "${SCRIPT_DIR}/claude-config/settings.json" \
            "${REMOTE_BASE}/claude-config/settings.json"

# ---------------------------------------------------------------------------
# 3. Ausführbarkeit sicherstellen
# ---------------------------------------------------------------------------
echo "[3/7] chmod +x für Skripte..."
ssh ${SSH_OPTS} "${SSH_TARGET}" \
    "chmod +x '${REMOTE_BUILD}/entrypoint.sh' '${REMOTE_BUILD}/bin/claude-mode'"

# ---------------------------------------------------------------------------
# 4. ttyd-Token bereitstellen (Vault oder Bestand)
# ---------------------------------------------------------------------------
echo "[4/7] ttyd-Token prüfen..."
if [[ -n "${VAULT_GET_CMD}" ]]; then
    echo "  -> Hole Token aus Vault..."
    TOKEN_VALUE=$(eval "${VAULT_GET_CMD}" 2>/dev/null || true)
    if [[ -n "${TOKEN_VALUE}" ]]; then
        echo "${TOKEN_VALUE}" | ssh ${SSH_OPTS} "${SSH_TARGET}" \
            "cat > '${REMOTE_BASE}/secrets/ttyd.cred' && chmod 600 '${REMOTE_BASE}/secrets/ttyd.cred'"
        echo "  -> Token aus Vault auf Pi geschrieben"
    else
        echo "  WARNUNG: Vault-Befehl lieferte leeren Token. Existierende ttyd.cred auf Pi bleibt unverändert (falls vorhanden)."
    fi
fi

# Prüfung danach: liegt ttyd.cred auf dem Pi?
if ! ssh ${SSH_OPTS} "${SSH_TARGET}" "test -s '${REMOTE_BASE}/secrets/ttyd.cred'"; then
    echo "  WARNUNG: ttyd.cred fehlt oder ist leer. Container wird nicht starten."
    echo "  Manuell setzen:"
    echo "    openssl rand -hex 24 | ssh ${SSH_OPTS} ${SSH_TARGET} \\"
    echo "      \"cat > ${REMOTE_BASE}/secrets/ttyd.cred && chmod 600 ${REMOTE_BASE}/secrets/ttyd.cred\""
fi

# ---------------------------------------------------------------------------
# 5. Subscription-Credentials prüfen (nur Info)
# ---------------------------------------------------------------------------
echo "[5/7] Auth-Files prüfen..."
ssh ${SSH_OPTS} "${SSH_TARGET}" "bash -s" <<EOF
if [[ -f '${REMOTE_BASE}/claude-config/.credentials.json' ]]; then
  echo "  .credentials.json: vorhanden (Subscription-Login)"
elif [[ -f '${REMOTE_BASE}/secrets/anthropic.key' ]]; then
  echo "  anthropic.key: vorhanden (API-Key)"
else
  echo "  Hinweis: weder .credentials.json noch anthropic.key vorhanden — interaktiver Login beim ersten Browser-Zugriff erforderlich."
fi
EOF

# ---------------------------------------------------------------------------
# 6. Image bauen
# ---------------------------------------------------------------------------
echo "[6/7] Image bauen (kann beim ersten Mal mehrere Minuten dauern)..."
ssh ${SSH_OPTS} "${SSH_TARGET}" \
    "sudo docker build -t ${IMAGE_TAG} '${REMOTE_BUILD}'"

# ---------------------------------------------------------------------------
# 7. Container neu starten
# ---------------------------------------------------------------------------
echo "[7/7] Container neu starten..."
ssh ${SSH_OPTS} "${SSH_TARGET}" "bash -s" <<EOF
sudo docker rm -f ${CONTAINER_NAME} 2>/dev/null || true
sudo docker run -d \\
  --name ${CONTAINER_NAME} \\
  --restart unless-stopped \\
  --network host \\
  -e CLAUDE_AUTH_MODE=${CLAUDE_AUTH_MODE} \\
  -e TTYD_PORT=${TTYD_PORT} \\
  -e TTYD_USER=${TTYD_USER} \\
  -e NETBIRD_IFACE=${NETBIRD_IFACE} \\
  -v ${HOST_WORKSPACE}:/workspace:rw \\
  -v ${HOST_BASE}/claude-config:/home/cockpit/.claude:rw \\
  -v ${HOST_BASE}/secrets:/secrets:ro \\
  ${IMAGE_TAG}
sleep 2
echo ""
echo "--- Container-Status ---"
sudo docker ps --filter name=${CONTAINER_NAME} --format "table {{.Names}}\\t{{.Status}}"
echo ""
echo "--- Letzte Log-Zeilen ---"
sudo docker logs --tail 12 ${CONTAINER_NAME} 2>&1
EOF

echo ""
echo "Deploy abgeschlossen."
echo ""
echo "Zugriff über Netbird:"
echo "  Pi-Netbird-IP ermitteln:  ssh ${SSH_OPTS} ${SSH_TARGET} \"ip -4 addr show ${NETBIRD_IFACE}\""
echo "  URL:                      http://<netbird-ip>:${TTYD_PORT}"
echo "  Benutzername:             ${TTYD_USER}"
echo "  Token:                    aus ${REMOTE_BASE}/secrets/ttyd.cred oder dem Vault"
