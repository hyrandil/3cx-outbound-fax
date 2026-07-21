#!/bin/sh
# start.sh – Asterisk-basierter 3CX Outbound Fax (outbound-only)
set -e

echo "╔══════════════════════════════════════╗"
echo "║   3CX Outbound Fax  (Asterisk/T.38)  ║"
echo "╚══════════════════════════════════════╝"

# --- Pflicht-Variablen ---
: "${SIP_PASSWORD:?SIP_PASSWORD ist nicht gesetzt}"
: "${SIP_PROXY:?SIP_PROXY ist nicht gesetzt}"
: "${FAX_NUMBER:?FAX_NUMBER ist nicht gesetzt}"
SIP_PORT="${SIP_PORT:-5060}"
# Lokaler SIP-Bind-Port von Asterisk. Default 5060; muss abweichen, wenn ein
# SBC im selben Netz-Namespace bereits 5060 belegt (z.B. beide im Host-Netz).
SIP_BIND_PORT="${SIP_BIND_PORT:-5060}"
SIP_EXTENSION="${SIP_EXTENSION:-890}"
SIP_AUTH_ID="${SIP_AUTH_ID:-$SIP_EXTENSION}"
# Outbound-Proxy: bei Cloud-3CX der lokale SBC, sonst = Registrar
SIP_OUTBOUND_PROXY="${SIP_OUTBOUND_PROXY:-$SIP_PROXY}"

echo "→ Registrar (3CX):  ${SIP_PROXY}:${SIP_PORT}"
echo "→ Outbound-Proxy:   ${SIP_OUTBOUND_PROXY}"
echo "→ Extension/AuthID: ${SIP_EXTENSION} / ${SIP_AUTH_ID}"
echo "→ Caller-ID:        ${FAX_NUMBER}"

# --- pjsip.conf aus Template befüllen ---
sed -e "s|__SIP_PROXY__|${SIP_PROXY}|g" \
    -e "s|__SIP_PORT__|${SIP_PORT}|g" \
    -e "s|__SIP_BIND_PORT__|${SIP_BIND_PORT}|g" \
    -e "s|__SIP_EXTENSION__|${SIP_EXTENSION}|g" \
    -e "s|__SIP_AUTH_ID__|${SIP_AUTH_ID}|g" \
    -e "s|__SIP_PASSWORD__|${SIP_PASSWORD}|g" \
    -e "s|__SIP_OUTBOUND_PROXY__|${SIP_OUTBOUND_PROXY}|g" \
    /etc/asterisk/pjsip.conf.tmpl > /etc/asterisk/pjsip.conf

# Manche containerinterne DNS-Resolver (Docker-Bridge, musl) liefern AAAA/IPv6
# zuerst; Asterisk hat aber nur einen IPv4-Transport → "No DNS results". Daher
# die A-Record-IPv4 des Registrars fix in /etc/hosts pinnen (best effort).
PROXY_IP4="$(getent ahosts "${SIP_PROXY}" 2>/dev/null | awk '/STREAM/ && $1 ~ /\./ {print $1; exit}')"
if [ -n "$PROXY_IP4" ] && ! grep -q " ${SIP_PROXY}$" /etc/hosts 2>/dev/null; then
    echo "${PROXY_IP4} ${SIP_PROXY}" >> /etc/hosts
    echo "→ DNS-Pin: ${SIP_PROXY} → ${PROXY_IP4}"
fi

# --- Verzeichnisse ---
mkdir -p /var/spool/asterisk/outgoing /var/spool/asterisk/fax \
         /run/asterisk /var/log/asterisk /var/lib/asterisk
# Caller-ID für die API exportieren (Default-Absendernummer)
export FAX_NUMBER

# --- Fax-API (Hintergrund) ---
echo "→ Fax-API auf Port ${API_PORT:-8080} (POST /fax, GET /health, /queue)"
python3 /usr/local/bin/fax-api.py &
API_PID=$!

cleanup() { kill "$API_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# --- Asterisk im Vordergrund (PID-Hauptprozess, Logs → docker logs) ---
echo "→ Starte Asterisk..."
exec asterisk -f -vvv
