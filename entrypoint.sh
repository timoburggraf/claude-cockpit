#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Auth-Modus
# ---------------------------------------------------------------------------
CLAUDE_AUTH_MODE="${CLAUDE_AUTH_MODE:-subscription}"
echo "[cockpit] Auth-Modus: ${CLAUDE_AUTH_MODE}"

if [[ "${CLAUDE_AUTH_MODE}" == "api" ]]; then
    if [[ ! -f /secrets/anthropic.key ]]; then
        echo "[cockpit] FEHLER: /secrets/anthropic.key nicht gefunden (Auth-Modus: api)" >&2
        exit 1
    fi
    export ANTHROPIC_API_KEY
    ANTHROPIC_API_KEY=$(cat /secrets/anthropic.key)
    echo "[cockpit] ANTHROPIC_API_KEY aus /secrets/anthropic.key geladen"
elif [[ "${CLAUDE_AUTH_MODE}" == "subscription" ]]; then
    echo "[cockpit] Subscription-Modus: nutze ~/.claude/.credentials.json"
else
    echo "[cockpit] FEHLER: Unbekannter CLAUDE_AUTH_MODE='${CLAUDE_AUTH_MODE}' (erlaubt: subscription|api)" >&2
    exit 1
fi

# Persistierten Modus aktualisieren (fuer claude-mode-Script)
mkdir -p /home/cockpit/.claude
echo "${CLAUDE_AUTH_MODE}" > /home/cockpit/.claude/cockpit-mode

# ---------------------------------------------------------------------------
# ttyd-Token
# ---------------------------------------------------------------------------
if [[ -z "${TTYD_TOKEN:-}" ]]; then
    if [[ -f /secrets/ttyd.cred ]]; then
        TTYD_TOKEN=$(cat /secrets/ttyd.cred)
        echo "[cockpit] TTYD_TOKEN aus /secrets/ttyd.cred geladen"
    else
        echo "[cockpit] FEHLER: TTYD_TOKEN weder als Env-Variable noch in /secrets/ttyd.cred vorhanden" >&2
        exit 1
    fi
fi

TTYD_PORT="${TTYD_PORT:-7681}"
TTYD_USER="${TTYD_USER:-cockpit}"

# ---------------------------------------------------------------------------
# Netbird-Interface-IP ermitteln
# ---------------------------------------------------------------------------
NETBIRD_IFACE="${NETBIRD_IFACE:-wt0}"
NETBIRD_IP=""

if ip -4 addr show "${NETBIRD_IFACE}" > /dev/null 2>&1; then
    NETBIRD_IP=$(ip -4 addr show "${NETBIRD_IFACE}" \
        | grep -oP '(?<=inet\s)\d+(\.\d+){3}' \
        | head -n1)
fi

if [[ -z "${NETBIRD_IP}" ]]; then
    echo "[cockpit] WARNUNG: Netbird-Interface '${NETBIRD_IFACE}' nicht gefunden oder keine IPv4-Adresse. Fallback auf 0.0.0.0" >&2
    NETBIRD_IP="0.0.0.0"
else
    echo "[cockpit] Netbird-IP: ${NETBIRD_IP} (Interface: ${NETBIRD_IFACE})"
fi

# ---------------------------------------------------------------------------
# tmux-Session starten
# ---------------------------------------------------------------------------
export CLAUDE_AUTH_MODE

if tmux has-session -t cockpit 2>/dev/null; then
    echo "[cockpit] tmux-Session 'cockpit' existiert bereits"
else
    echo "[cockpit] Starte tmux-Session 'cockpit' mit claude"
    tmux new-session -d -s cockpit -c /workspace \
        -e CLAUDE_AUTH_MODE="${CLAUDE_AUTH_MODE}" \
        "claude; bash"
fi

# ---------------------------------------------------------------------------
# ttyd starten
# ---------------------------------------------------------------------------
echo "[cockpit] Starte ttyd auf ${NETBIRD_IP}:${TTYD_PORT}"

exec ttyd \
    --interface "${NETBIRD_IP}" \
    --port "${TTYD_PORT}" \
    --credential "${TTYD_USER}:${TTYD_TOKEN}" \
    --writable \
    tmux attach -t cockpit
