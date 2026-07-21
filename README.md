# 3CX Outbound Fax – auf Mac & Mini-Server

> In Deutschland ist das Fax kein Relikt, sondern eine **rechtsverbindliche Lebensform**: Während das Silicon Valley zum Mars fliegt, gilt hierzulande erst als zugestellt, was einmal durch eine kreischende Telefonleitung gepresst wurde. 📠
>
> Dieses Projekt ist der Kompromiss aus beiden Welten – wir digitalisieren das Faxen so weit, dass man es aus der macOS-Druckvorschau heraus per Klick verschickt, und tun trotzdem brav so, als hätten wir 1987 nie verlassen.
>
> Kurz: ein Stück Software, das nur existiert, weil das deutsche Amt eine PDF erst dann glaubt, wenn sie vorher kurz weinen musste.

---

PDF → Fax, direkt aus **macOS Vorschau** (oder per HTTP-API), über eine **3CX-Anlage** als Fax-Nebenstelle. **Outbound-only** (nur senden – empfangen kann 3CX selbst schon: Fax→PDF→E-Mail). Läuft als schlanker Docker-Container (~250 MB, Alpine) auf einem beliebigen Mini-Server.

```
macOS Vorschau (PDF-Menü "Fax senden")     Windows (Senden an → "Fax senden")
    │ HTTP POST /fax
    ▼
Fax-API             (Container, Port FAX_API_PORT)
    │ PDF → TIFF (ghostscript) → Call-File
    ▼
Asterisk 20         (res_fax_spandsp, SendFAX, T.38)
    │ SIP-Registrierung als Fax-Nebenstelle
    ▼
[3CX SBC]           (nur bei Cloud-3CX nötig, läuft mit im Compose)
    │ TLS-Tunnel
    ▼
3CX-Anlage  ──►  intern (3CX-Faxserver 888) oder Trunk ──► PSTN / Empfänger
```

---

## Warum Asterisk + spandsp?

Fax über VoIP heißt **T.38**. Die klassischen Open-Source-Bausteine dafür (t38modem/HylaFAX auf Basis von PTLib/OPAL) sind aus allen modernen Distributionen geflogen und praktisch unwartbar. **Asterisk** bringt mit `res_fax_spandsp` eine gepflegte, paketierte Fax-Engine mit – Alpine liefert sie fertig als Paket (`asterisk-fax`), es muss **nichts kompiliert** werden.

**GitHub Actions** baut das Image als **Multi-Arch (amd64 + arm64)** und pusht es nach **GHCR**. Endnutzer ziehen nur das fertige Image.

---

## Schnellstart (fertiges Image aus GHCR)

```bash
git clone https://github.com/amfeld/3cx-outbound-fax.git
cd 3cx-outbound-fax
cp .env.example .env && nano .env      # 3CX-Zugangsdaten eintragen

# On-Premise-3CX (direkte Registrierung erlaubt):
docker compose up -d

# Cloud-3CX (*.on3cx.de) – SBC läuft mit:
docker compose -f docker-compose.yml -f docker-compose.sbc.yml up -d
```

Der Container läuft im **Host-Netz** (SIP/RTP/T.38 brauchen NAT-freie Pfade). Belegte Host-Ports: `FAX_API_PORT` (Default 18080, TCP), `SIP_BIND_PORT` (Default 5062, UDP) – plus beim SBC: UDP 5060 und UDP 20000–20063.

### `.env` ausfüllen

| Variable             | Bedeutung                                                              |
|----------------------|------------------------------------------------------------------------|
| `SIP_EXTENSION`      | Nummer der in 3CX angelegten **Fax-Nebenstelle** (z.B. `880`)          |
| `SIP_AUTH_ID`        | **Auth-ID aus 3CX** – ⚠️ weicht von der Extension-Nr. ab!              |
| `SIP_PASSWORD`       | Auth-Passwort aus 3CX                                                  |
| `SIP_PROXY`          | 3CX Registrar (Cloud-Domain oder IP)                                   |
| `SIP_PORT`           | SIP-Port der Anlage/des SBC (Standard `5060`)                          |
| `SIP_BIND_PORT`      | Lokaler SIP-Port von Asterisk (Default `5062`, lässt dem SBC die 5060) |
| `SIP_OUTBOUND_PROXY` | SBC-Adresse bei Cloud-3CX (`127.0.0.1` = SBC aus dem Compose); leer = direkt |
| `FAX_NUMBER`         | Fax-Absendernummer / Caller-ID, E.164 (`+4968…`)                       |
| `FAX_API_PORT`       | Port der HTTP-API am Host (Default `18080`)                            |
| `PBX_URL`/`PBX_KEY`  | Nur SBC: Provisioning-URL + Key aus 3CX Admin → SBCs                   |

> **Auth-ID-Falle:** 3CX vergibt eine eigene `Authentifizierungs-ID`, die **nicht** mit der Extension-Nummer identisch ist. Zu finden in den Einstellungen der Fax-Nebenstelle.

### 3CX-Voraussetzungen

- Eine **Fax-Nebenstelle** anlegen (3CX Admin → *FAX-Geräte/Fax-Nebenstellen*). Liefert Auth-ID + Passwort. Eine normale Telefon-Nebenstelle funktioniert für die Registrierung auch, bekommt aber ggf. keine Fax-Behandlung (T.38) durch die Anlage.
- **Cloud-3CX** (`*.on3cx.de`): direkte Registrierung fremder Geräte wird abgelehnt (403) → den mitgelieferten **SBC** nutzen (`docker-compose.sbc.yml`). In 3CX Admin → SBCs einen SBC anlegen, `PBX_URL`/`PBX_KEY` in die `.env`.
- Für externe Ziele: eine **Outbound-Regel** über einen Trunk mit **T.38-Unterstützung**.

---

## Status prüfen

```bash
docker compose logs -f
curl http://localhost:18080/health      # {"status":"ok","asterisk":true,"registered":true,...}
curl http://localhost:18080/queue       # offene Fax-Jobs + Registrierungsstatus
```

## Fax senden (manuell, ohne Mac)

```bash
curl -X POST http://localhost:18080/fax \
  -F "file=@/pfad/zur/datei.pdf" \
  -F "number=+4968112345"
# → {"status":"sent","number":"+4968112345","result":"SUCCESS (, 1 Seiten)"}
```

---

## macOS-Client einrichten (PDF-Service)

Auf modernem macOS gibt es **keine native Fax-Unterstützung** mehr (Apple hat das Fax-Subsystem entfernt). Der idiomatische Weg ist ein **PDF-Service**, der im Druckdialog erscheint und nach der Faxnummer fragt.

Ein Befehl pro Client-Mac — der Server liefert das Script fertig konfiguriert aus (`FAXSERVER` = Adresse des Docker-Hosts):

```bash
mkdir -p ~/Library/PDF\ Services && curl -fsS "http://FAXSERVER:18080/client/macos" \
  -o ~/Library/PDF\ Services/"Fax senden" && chmod +x ~/Library/PDF\ Services/"Fax senden"
```

(Alternativ aus dem Repo: `cd macos && ./install.sh`.)

Danach in jeder App: **Ablage → Drucken (⌘P) → PDF ▼ → „Fax senden"** → Nummer eingeben.

---

## Windows-Client einrichten (Rechtsklick → Senden an)

Windows hat **kein** „PDF ▼" im Druckdialog wie macOS. Der idiomatische, rein native Weg (keine Drittsoftware, kein Admin) ist ein Eintrag im **„Senden an"-Menü**.

Ein Befehl pro Client-PC (PowerShell; `FAXSERVER` = Adresse des Docker-Hosts):

```powershell
irm http://FAXSERVER:18080/client/windows-install | iex
```

(Alternativ aus dem Repo: `powershell -ExecutionPolicy Bypass -File windows\install.ps1`.)

Danach im Explorer: **Rechtsklick auf eine PDF → Senden an → „Fax senden"** → Nummer eingeben.

> Aus einer beliebigen App faxen: erst über **„Microsoft Print to PDF"** (Strg+P) eine PDF erzeugen, dann per Rechtsklick faxen. Kompatibel mit dem vorinstallierten **Windows PowerShell 5.1**.

---

## Entwicklung

```bash
docker compose build       # baut lokal (schnell – Alpine-Pakete, kein Compile)
docker compose up -d
```

---

## Troubleshooting

**Registrierung schlägt fehl / „Rejected"**
```bash
docker exec -it faxserver asterisk -rx "pjsip show registrations"
docker exec -it faxserver asterisk -rx "pjsip set logger on" && docker logs -f faxserver
```
Häufige Ursachen: falsche `SIP_AUTH_ID` (Extension-Nr. statt Auth-ID!), Cloud-3CX ohne SBC (→ 403), UDP blockiert. Hinweis: 3CX beantwortet REGISTER von Fax-Nebenstellen nur dann korrekt, wenn der Contact-User der Extension entspricht – das setzt das Image automatisch (`contact_user`).

**Registrierung ok, aber Fax bricht ab (BYE nach ~10 s)**
Die Gegenstelle bekommt kein Audio/T.38. Fast immer ein NAT-Problem → der Container **muss** im Host-Netz laufen (Standard in `docker-compose.yml`); bei Cloud-3CX SBC und Faxserver auf demselben Host mit `SIP_OUTBOUND_PROXY=127.0.0.1`.

**T.38 wird nicht ausgehandelt (kein Re-INVITE mit `m=image`)**
Das T.38-Re-INVITE initiiert die 3CX-Seite. Interne Ziele (z.B. 3CX-Faxserver `888`) tun das zuverlässig; bei externen Zielen muss der **Trunk T.38 unterstützen**.

**SBC-Diagnose**
```bash
docker exec -it 3cx-sbc cat /var/log/3cxsbc/3cxsbc.log   # "Secure tunnel is established"?
```

---

## Dateien

```
.
├── Dockerfile               Alpine + asterisk + asterisk-fax (spandsp) + ghostscript
├── docker-compose.yml       Faxserver (GHCR-Image, Host-Netz)
├── docker-compose.sbc.yml   Optionaler 3CX-SBC (nur Cloud-3CX)
├── .env.example             Vorlage für Zugangsdaten
├── .github/workflows/       CI: Multi-Arch-Build → GHCR
├── configs/
│   ├── pjsip.conf           SIP/Registrierung/T.38 (Template, aus .env befüllt)
│   ├── extensions.conf      Dialplan (SendFAX + Ergebnis-Report)
│   ├── res_fax.conf         Fax-Engine (ECM, Raten)
│   ├── udptl.conf           T.38-Transport
│   └── …                    asterisk/modules/logger
├── scripts/
│   ├── start.sh             Container-Start (Template füllen, API + Asterisk)
│   └── fax-api.py           HTTP-API (POST /fax, /health, /queue)
├── macos/
│   ├── Fax senden           PDF-Service-Script
│   └── install.sh           Installations-Helfer
└── windows/
    ├── Fax senden.ps1       Client-Skript (Senden an / Rechtsklick)
    └── install.ps1          Installations-Helfer
```
