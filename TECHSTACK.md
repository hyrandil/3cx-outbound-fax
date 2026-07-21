# Techstack und High-Level-Funktionen

## Überblick

Dieses Projekt ist ein Docker-basierter Fax-Server für Outbound-Faxe über eine 3CX-Anlage. Der Kern besteht aus:

- Asterisk als SIP-/Fax-Engine
- `res_fax_spandsp` für Fax-Handling über T.38
- einer kleinen Python-HTTP-API als Eingangsinterface
- Ghostscript zur Umwandlung von PDF in faxkonformes TIFF
- optionalem 3CX-SBC für Cloud-3CX-Setups

## Techstack

### 1. Core Platform
- Docker / Docker Compose
- Alpine Linux 3.21
- Asterisk 20
- Python 3

### 2. Fax- und Media-Stack
- `asterisk-fax` / `res_fax_spandsp`
- `SendFAX` als Fax-Sendebefehl in Asterisk
- T.38 über SIP für Fax-Transport
- PJSIP als SIP-Stack
- Ghostscript für PDF → TIFF

### 3. Integration / Infrastruktur
- 3CX PBX als Ziel-/Registeranlage
- optionaler 3CX SBC für Cloud-3CX
- Host-Netzwerk-Mode für NAT-freie SIP/RTP/T.38-Kommunikation

### 4. Client-Seite
- macOS PDF-Service
- Windows „Senden an“-Integration
- HTTP-API für direkte Nutzung aus Skripten oder anderen Anwendungen

## Komponenten im Projekt

### Asterisk-Konfiguration
- `configs/pjsip.conf` – SIP-Registrierung und Fax-Handling-Konfiguration
- `configs/extensions.conf` – Dialplan für den Versand-Lauf
- `configs/res_fax.conf` – Fax-Parameter wie ECM und Übertragungsraten
- `configs/udptl.conf` – T.38-Transportkonfiguration

### Container-Startup
- `Dockerfile` – baut das schlanke Alpine-Image mit Asterisk, Fax-Modulen, Ghostscript und Python
- `scripts/start.sh` – startet Asterisk und die API im Container
- `scripts/fax-api.py` – zentrale HTTP-API für Faxeinreichung und Statusabfragen

### Client-Skripte
- `macos/Fax senden` – PDF-Service für macOS
- `windows/Fax senden.ps1` – Windows-Integration über „Senden an“
- `windows/install.ps1` / `install-remote.ps1` – Installation der Client-Links

## High-Level-Funktionen

### 1. PDF per HTTP annehmen
Die API nimmt eine PDF-Datei und eine Faxnummer entgegen, z. B. über `POST /fax`.

### 2. PDF in faxfähiges Format umwandeln
Die Datei wird mit Ghostscript in ein TIFF im G4-Format umgewandelt, damit sie von Asterisk / `SendFAX` verarbeitet werden kann.

### 3. Fax-Job an Asterisk übergeben
Die API schreibt einen Call-File in den Asterisk-Spool. Asterisk übernimmt dann die Wahl über PJSIP und startet den Faxversand.

### 4. Fax über 3CX und T.38 senden
Asterisk registriert sich an der 3CX-Anlage oder über einen SBC und versendet den gebundenen Fax-Stream mit T.38.

### 5. Status und Health prüfen
Die API bietet Endpunkte für:
- `GET /health` – Verfügbarkeit und Registrierungsstatus
- `GET /queue` – offene Jobs und aktuelle Zustände
- Ergebnis-/Journal-Logs für abgeschlossene Fax-Vorgänge

### 6. Client-Integration für Endnutzer bereitstellen
Der Server liefert die macOS- und Windows-Client-Skripte über HTTP aus, sodass Nutzer die Funktion direkt aus der Druck- oder Kontextmenü-Umgebung aufrufen können.

## Typischer Ablauf

1. Nutzer startet aus macOS- oder Windows-Client einen Fax-Vorgang.
2. Die API erhält die PDF-Datei und die Zielnummer.
3. Ghostscript erzeugt ein TIFF.
4. Asterisk erhält einen Call-File mit den Fax-Parametern.
5. Asterisk setzt den SIP/T.38-Faxversand über 3CX auf.
6. Die API wartet auf das Ergebnis und gibt Status/Fehler zurück.

## Kurzfazit

Das System ist ein schlanker, containerisierter Fax-Workflow mit:

- SIP-Registrierung an 3CX
- T.38-basierter Faxübertragung
- einfacher HTTP-API für Clients
- automatisierter PDF → TIFF-Konvertierung
- klarer Trennung zwischen „Frontend-Integration“ und „Fax-Transport-Engine“
