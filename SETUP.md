# Einrichtungsanleitung – 3CX Outbound Fax

Schritt-für-Schritt von Null zum ersten gesendeten Fax. Für Architektur & Troubleshooting siehe [README.md](README.md).

**Was du brauchst:**

- Einen Server/Rechner mit **Docker** (Linux, macOS oder Windows; amd64 oder arm64)
- **Admin-Zugang zur 3CX-Anlage** (Cloud `*.on3cx.de` oder On-Premise)
- ~10 Minuten

---

## Teil 1: 3CX vorbereiten

### 1.1 Fax-Nebenstelle anlegen (Pflicht)

Das ist der SIP-Account, mit dem sich der Faxserver bei 3CX anmeldet und **sendet**.

1. 3CX Admin → **FAX-Geräte** (bzw. *Fax-Nebenstellen*) → **Hinzufügen**
2. Nummer vergeben, z. B. `880`
3. Nach dem Speichern notieren:
   - **Fax-Nebenstellen Authentifizierungs-ID** → wird `SIP_AUTH_ID`
   - **Fax-Nebenstellen Authentifizierungspasswort** → wird `SIP_PASSWORD`

> ⚠️ **Auth-ID-Falle:** Die Authentifizierungs-ID ist ein Zufallsstring (z. B. `k7Pn2xQ8rT`) und **nicht** die Nebenstellennummer. Wer die Nummer einträgt, bekommt nie eine Registrierung.

> **Warum eine Fax-Nebenstelle und kein normaler Benutzer?** 3CX behandelt Fax-Nebenstellen fax-optimiert (T.38-Passthrough statt Voice-Media-Server). Mit einer normalen Telefon-Nebenstelle registriert sich der Server zwar, aber die Fax-Übertragung schlägt fehl.

### 1.2 Nur Cloud-3CX: SBC-Objekt anlegen

Cloud-3CX (`*.on3cx.de`) lehnt die direkte Registrierung fremder SIP-Geräte ab (403 Forbidden). Der mitgelieferte Docker-SBC baut stattdessen einen Tunnel auf.

1. 3CX Admin → **SBCs** (bzw. *3CX SBC*) → **Hinzufügen**
2. Namen vergeben, speichern
3. Notieren:
   - **Provisioning-URL** (z. B. `https://deine-anlage.on3cx.de`) → wird `PBX_URL`
   - **Authentifizierungsschlüssel** → wird `PBX_KEY`

On-Premise-3CX im selben Netz braucht **keinen** SBC — Teil 1.2 überspringen und später `SIP_OUTBOUND_PROXY` leer lassen.

### 1.3 Nur für externe Ziele: Trunk mit T.38

Zum Faxen an **externe** Nummern (nicht 3CX-intern) muss der SIP-Trunk des Providers **T.38** unterstützen und eine **Outbound-Regel** für die Fax-Nebenstelle existieren (3CX Admin → *Outbound-Regeln*). Siehe auch [3CX-Doku: Faxen über SIP-Trunk](https://www.3cx.com/docs/sip-trunk-faxing/).

### 1.4 Anti-Hacking beachten

3CX sperrt IPs nach mehreren fehlgeschlagenen Registrierungen (Admin → *Sicherheit* → *Anti-Hacking* → *IP-Sperrliste*). Wenn während der Einrichtung plötzlich gar nichts mehr ankommt: dort nachsehen und die eigene IP entsperren.

---

## Teil 2: Faxserver installieren

```bash
git clone https://github.com/amfeld/3cx-outbound-fax.git
cd 3cx-outbound-fax
cp .env.example .env
nano .env
```

`.env` mit den Werten aus Teil 1 füllen:

```dotenv
SIP_EXTENSION=880                  # Nummer der Fax-Nebenstelle (1.1)
SIP_AUTH_ID=k7Pn2xQ8rT             # Auth-ID (1.1) – Beispiel, eigenen Wert eintragen
SIP_PASSWORD=…                     # Auth-Passwort (1.1)
SIP_PROXY=deine-anlage.on3cx.de    # 3CX-Adresse
SIP_PORT=5060
SIP_BIND_PORT=5062                 # lokaler Asterisk-Port (5060 gehört dem SBC)
SIP_OUTBOUND_PROXY=127.0.0.1       # Cloud: SBC läuft mit; On-Premise: leer lassen
FAX_NUMBER=+49…                    # Absenderkennung (Fax-ID), E.164
FAX_OWNER=Meine Firma e.K.         # Name in der Fax-Kopfzeile (optional)
FAX_API_PORT=18080                 # HTTP-API-Port am Host
PBX_URL=https://deine-anlage.on3cx.de   # nur Cloud (1.2)
PBX_KEY=…                          # nur Cloud (1.2)
SBC_VERSION=latest                 # an 3CX-Hauptversion anpassen, z. B. 20.0
```

Starten:

```bash
# Cloud-3CX (SBC läuft mit):
docker compose -f docker-compose.yml -f docker-compose.sbc.yml up -d

# On-Premise-3CX (ohne SBC):
docker compose up -d
```

> Der Container nutzt das **Host-Netz** (SIP/RTP/T.38 vertragen kein Docker-NAT). Belegte Host-Ports: `FAX_API_PORT` (TCP), `SIP_BIND_PORT` (UDP), beim SBC zusätzlich UDP 5060 + 20000–20063.

---

## Teil 3: Prüfen

```bash
curl http://localhost:18080/health
# → {"status":"ok","asterisk":true,"registered":true,…}
```

`"registered": true` = die Fax-Nebenstelle ist an 3CX angemeldet (dauert nach dem Start bis ~30 s). In der 3CX-Admin-Oberfläche erscheint die Nebenstelle als verbunden.

Erstes Testfax — an den **3CX-internen Faxserver** (Standard-Nebenstelle `888`; empfangene Faxe kommen als PDF-Mail an die dort hinterlegte Adresse):

```bash
curl -X POST http://localhost:18080/fax \
  -F "file=@test.pdf" -F "number=888"
# → {"status":"sent","number":"888","result":"SUCCESS (, 1 Seiten)"}
```

Kommt die PDF-Mail an → **alles funktioniert**. Danach externe Ziele testen (setzt Teil 1.3 voraus).

---

## Teil 4: Clients einrichten

**Das Repo wird auf Client-Rechnern nicht gebraucht.** Der Faxserver liefert die Client-Scripts selbst aus — bereits fertig konfiguriert mit seiner Adresse. Auf jedem Client genügt **ein Befehl** (im Beispiel ist `FAXSERVER` die IP/der Hostname des Docker-Hosts, z. B. `192.168.1.10` — oder `localhost`, wenn der Client auf demselben Rechner läuft):

### macOS (Druckdialog)

Terminal:

```bash
mkdir -p ~/Library/PDF\ Services && curl -fsS "http://FAXSERVER:18080/client/macos" \
  -o ~/Library/PDF\ Services/"Fax senden" && chmod +x ~/Library/PDF\ Services/"Fax senden"
```

Danach in jeder App: **⌘P → unten links PDF ▼ → „Fax senden"** → Nummer eingeben.

### Windows (Senden an)

PowerShell (kein Admin nötig):

```powershell
irm http://FAXSERVER:18080/client/windows-install | iex
```

Lädt das Client-Script und legt den Eintrag im „Senden an"-Menü an. Danach: **Rechtsklick auf PDF → Senden an → „Fax senden"**.

> Aus jeder App faxen: erst über **„Microsoft Print to PDF"** (Strg+P) eine PDF erzeugen, dann per Rechtsklick faxen.

### Alternative: aus dem Repo installieren

Wer das Repo ohnehin ausgecheckt hat (z. B. auf dem Server selbst), kann stattdessen die interaktiven Installer nutzen — sie fragen nach der Server-Adresse:

```bash
cd macos && ./install.sh                                        # macOS
powershell -ExecutionPolicy Bypass -File windows\install.ps1    # Windows
```

> Nicht-Standard-Port? Die ausgelieferten Scripts übernehmen automatisch den Port, unter dem der Server angesprochen wurde (`FAX_API_PORT`).

---

## Kurz-Troubleshooting

| Symptom | Ursache / Lösung |
|---|---|
| `registered: false`, Log: 403 | Cloud-3CX ohne SBC → Teil 1.2; oder IP gesperrt → Teil 1.4 |
| `registered: false`, Log: 401/Rejected | `SIP_AUTH_ID` falsch (Nummer statt Auth-ID?) |
| Registrierung ok, Fax bricht nach ~10 s ab | NAT im Medienpfad → Host-Netz nutzen (Standard); Cloud: `SIP_OUTBOUND_PROXY=127.0.0.1` |
| Intern (888) ok, extern schlägt fehl | Trunk ohne T.38 oder fehlende Outbound-Regel → Teil 1.3 |
| Client: „Server nicht erreichbar" | `FAX_API_PORT` prüfen, Firewall, richtige Server-IP im Client |

Mehr Details: [README.md → Troubleshooting](README.md#troubleshooting).
