#!/bin/bash
# install.sh – Installiert das Fax-PDF-Service auf dem Mac
# Einmalig pro Mac ausführen

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAX_SCRIPT="$SCRIPT_DIR/Fax senden"
PDF_SERVICES_DIR="$HOME/Library/PDF Services"

echo "╔══════════════════════════════════════╗"
echo "║   Fax-PDF-Service Installation       ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ── Server-IP abfragen ─────────────────────────────────────
read -p "IP/Hostname des Fax-Servers [localhost]: " SERVER_IP
SERVER_IP="${SERVER_IP:-localhost}"

# IP ins Script eintragen
sed "s/DEIN_SERVER_IP/${SERVER_IP}/g" "$FAX_SCRIPT" > /tmp/fax-senden-configured

# ── Installieren ───────────────────────────────────────────
mkdir -p "$PDF_SERVICES_DIR"
cp /tmp/fax-senden-configured "$PDF_SERVICES_DIR/Fax senden"
chmod +x "$PDF_SERVICES_DIR/Fax senden"
rm /tmp/fax-senden-configured

echo ""
echo "✓ Installiert: $PDF_SERVICES_DIR/Fax senden"
echo ""
echo "── So verwenden ──────────────────────────────────────"
echo "  1. Dokument in Preview öffnen"
echo "  2. Ablage → Drucken (⌘P)"
echo "  3. Unten links: PDF ▼ → 'Fax senden'"
echo "  4. Faxnummer eingeben → Senden"
echo ""
echo "── Server-Status prüfen ──────────────────────────────"
echo "  curl http://${SERVER_IP}:18080/health"
echo ""

# Sofort testen
read -p "Verbindung zum Fax-Server jetzt testen? (j/N): " TEST
if [[ "$TEST" =~ ^[jJ]$ ]]; then
    echo ""
    if curl -sf --max-time 5 "http://${SERVER_IP}:18080/health"; then
        echo ""
        echo "✓ Fax-Server erreichbar!"
    else
        echo ""
        echo "✗ Fax-Server nicht erreichbar. Docker gestartet?"
    fi
fi
