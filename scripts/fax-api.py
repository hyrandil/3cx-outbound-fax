#!/usr/bin/env python3
"""
Fax-API: Nimmt PDF entgegen und sendet es per Asterisk (res_fax_spandsp / T.38).

Ablauf:  PDF --ghostscript--> TIFF(G4)  -->  Call-File in Asterisk-Spool
         Asterisk wählt über 3CX(/SBC) und führt SendFAX aus; das Dialplan
         schreibt das Ergebnis in eine Datei, auf die wir kurz warten.

Endpoints:
  POST /fax     - multipart: file=PDF, number=Faxnummer
  GET  /health  - Asterisk läuft? registriert?
  GET  /queue   - offene Call-Files / Registrierungsstatus
"""

import calendar
import cgi
import html
import http.server
import json
import logging
import os
import re
import subprocess
import tempfile
import threading
import time
import uuid
from datetime import datetime

logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s [%(levelname)s] %(message)s',
                    datefmt='%Y-%m-%d %H:%M:%S')
logger = logging.getLogger('fax-api')

OUTGOING_DIR = '/var/spool/asterisk/outgoing'
FAX_DIR = '/var/spool/asterisk/fax'
CLIENTS_DIR = '/usr/local/share/fax-clients'   # ausgelieferte Client-Scripts
DEFAULT_CALLERID = os.environ.get('FAX_NUMBER', '')
RESULT_WAIT_S = 120     # HTTP-Wartezeit aufs Ergebnis (Client wartet 150 s)
LATE_WAIT_S = 300       # danach: Hintergrund-Korrektur (langsame Faxe kommen spät)

# Sendeprotokoll (JSONL, liegt im persistenten Log-Volume) – GET / zeigt es an
JOURNAL = '/var/log/asterisk/fax-journal.jsonl'
_journal_lock = threading.Lock()


def journal_append(entry: dict):
    # Zeitstempel als UTC-Epoch (eindeutig) + UTC-Klartext als Fallback.
    # Der Browser rechnet in die lokale Zeit des Betrachters um (inkl. DST).
    entry['epoch'] = int(time.time())
    entry['ts'] = datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')
    try:
        with _journal_lock, open(JOURNAL, 'a', encoding='utf-8') as f:
            f.write(json.dumps(entry, ensure_ascii=False) + '\n')
    except OSError as e:
        logger.warning(f'Journal nicht schreibbar: {e}')


def short_reason(status: str, detail: str) -> str:
    """Rohen spandsp/Dialplan-Status auf einen knappen Klartext-Grund mappen."""
    s = status.upper()
    d = (detail or '').strip()
    if s in ('SUCCESS', 'OK'):
        return ''
    if 'call-setup' in d or s in ('NOANSWER', 'BUSY', 'CONGESTION'):
        return 'nicht erreichbar / besetzt'
    if not d:
        # Abnahme, aber keine T.38-/Fax-Aushandlung → Ziel ist kein Faxgerät
        return 'Ziel antwortet nicht als Fax (kein T.38)'
    low = d.lower()
    if 'negotiat' in low or 't.38' in low or 'audio fax' in low:
        return 'Ziel antwortet nicht als Fax (kein T.38)'
    if 'remote' in low and 'disconnect' in low:
        return 'Gegenstelle hat aufgelegt'
    return d


def journal_update(job: str, fields: dict):
    """Bestehenden Journal-Eintrag (per job) aktualisieren – z.B. wenn ein
    langsames Fax nach dem HTTP-Timeout doch noch fertig wird."""
    try:
        with _journal_lock:
            lines = open(JOURNAL, encoding='utf-8').read().splitlines()
            out = []
            for ln in lines:
                try:
                    e = json.loads(ln)
                except ValueError:
                    out.append(ln); continue
                if e.get('job') == job:
                    e.update(fields)
                    out.append(json.dumps(e, ensure_ascii=False))
                else:
                    out.append(ln)
            open(JOURNAL, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
    except OSError as ex:
        logger.warning(f'Journal-Update fehlgeschlagen: {ex}')


def journal_read(limit: int = 200) -> list:
    try:
        with open(JOURNAL, encoding='utf-8') as f:
            lines = f.readlines()[-limit:]
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out

# GET /client/<name> → Client-Script, fertig konfiguriert auf diesen Server
CLIENT_FILES = {
    'macos':           ('Fax senden',        'Fax senden'),
    'windows':         ('Fax senden.ps1',    'Fax senden.ps1'),
    'windows-install': ('install-remote.ps1', 'install-fax-senden.ps1'),
}


def asterisk_cli(cmd: str, timeout: int = 8) -> str:
    try:
        r = subprocess.run(['asterisk', '-rx', cmd],
                           capture_output=True, text=True, timeout=timeout)
        return r.stdout
    except Exception as e:
        return f'(asterisk cli error: {e})'


FAX_A4 = (595.0, 842.0)   # A4 in PostScript-Punkten
FAX_MARGIN = 18.0         # ~6 mm Sicherheitsrand (Fax hat nicht-druckbare Ränder)


def _pdf_ink_bbox(pdf_path: str):
    """Gesamt-Bounding-Box der tatsächlichen Tinte über alle Seiten (Punkte)."""
    try:
        r = subprocess.run(['gs', '-q', '-dNOPAUSE', '-dBATCH', '-dSAFER',
                            '-sDEVICE=bbox', pdf_path],
                           capture_output=True, text=True, timeout=120)
    except Exception:
        return None
    x0 = y0 = 1e12
    x1 = y1 = -1e12
    for ln in r.stderr.splitlines():
        if ln.startswith('%%HiResBoundingBox:'):
            try:
                a, b, c, d = map(float, ln.split()[1:5])
            except ValueError:
                continue
            x0 = min(x0, a); y0 = min(y0, b); x1 = max(x1, c); y1 = max(y1, d)
    return (x0, y0, x1, y1) if x1 > x0 and y1 > y0 else None


def pdf_to_tiff(pdf_path: str, tiff_path: str) -> tuple[bool, str]:
    """PDF -> TIFF Group 4, Fax-Auflösung 204x196 dpi, fax-konform A4-Hochformat.

    Wir bestimmen die echte Inhalts-Bounding-Box, drehen Querformat auf
    Hochformat und passen alles mit Sicherheitsrand MITTIG ein. Damit wird
    nichts am Rand abgeschnitten – Fax hat eine nicht-druckbare Randzone, und
    randlose Tabellen (Querformat) verlieren sonst genau dort Inhalt.
    (Reines -dPDFFitPage passt die Seiten-, nicht die Tinten-Box ein → kein
    garantierter Rand. Hinweis: Die Drehung gilt einheitlich fürs Dokument –
    passend für gleichförmige Vorlagen; gemischt quer/hoch ist selten.)
    Fallback bei Bbox-Problemen: schlichtes Fit-to-Page."""
    bb = _pdf_ink_bbox(pdf_path)
    if bb:
        x0, y0, x1, y1 = bb
        cw, ch = x1 - x0, y1 - y0
        if cw > 1 and ch > 1:
            pw, ph = FAX_A4
            m = FAX_MARGIN
            rot = cw > ch                       # Querformat -> um 90° drehen
            rw, rh = (ch, cw) if rot else (cw, ch)
            s = min((pw - 2 * m) / rw, (ph - 2 * m) / rh)
            cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
            ang = 90 if rot else 0
            # BeginPage transformiert jede Seite: Ursprung -> Blattmitte,
            # skalieren, drehen, Inhaltsmitte auf den Ursprung schieben.
            ps = ('<< /BeginPage { pop %g %g translate %.6f %.6f scale '
                  '%d rotate %.4f %.4f translate } >> setpagedevice'
                  % (pw / 2, ph / 2, s, s, ang, -cx, -cy))
            cmd = ['gs', '-q', '-dNOPAUSE', '-dBATCH', '-dSAFER',
                   '-sDEVICE=tiffg4', '-r204x196',
                   '-dFIXEDMEDIA', '-sPAPERSIZE=a4',
                   f'-sOutputFile={tiff_path}', '-c', ps, '-f', pdf_path]
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
                if r.returncode == 0 and os.path.exists(tiff_path):
                    return True, 'ok'
            except Exception:
                pass  # -> Fallback

    cmd = ['gs', '-q', '-dNOPAUSE', '-dBATCH', '-dSAFER',
           '-sDEVICE=tiffg4', '-r204x196',
           '-dFIXEDMEDIA', '-sPAPERSIZE=a4', '-dPDFFitPage',
           f'-sOutputFile={tiff_path}', pdf_path]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if r.returncode == 0 and os.path.exists(tiff_path):
            return True, 'ok'
        return False, (r.stderr.strip() or r.stdout.strip() or 'gs failed')
    except Exception as e:
        return False, str(e)


def submit_fax(number: str, tiff_path: str, filename: str = '') -> tuple[bool, str]:
    """Call-File schreiben und auf das Ergebnis warten."""
    job = uuid.uuid4().hex[:10]
    result_path = os.path.join(FAX_DIR, f'{job}.result')
    # Saubere Eingaben (auch kurze interne wie "888") direkt nehmen; nur bei
    # echtem Freitext (Signaturen o.ä.) die längste Ziffernfolge herausfischen.
    compact = re.sub(r'[\s()\/.\-]', '', number.strip())
    if re.fullmatch(r'\+?[0-9]{2,}', compact):
        number = compact
    else:
        candidates = re.findall(r'\+?[0-9][0-9 ()\/\.-]{3,}[0-9]', number)
        if not candidates:
            return False, f'keine Rufnummer erkennbar in: {number[:60]!r}'
        number = max(candidates, key=lambda s: len(re.sub(r'[^0-9]', '', s)))

    # Für den PJSIP-Dial-String normalisieren. 3CX-Outbound-Regeln erwarten
    # Wählformat (0… national / 00… international) – ein nacktes "49…" aus
    # stumpf entferntem "+" matcht keine Regel und schlägt fehl.
    cc = re.sub(r'[^0-9]', '', os.environ.get('FAX_COUNTRY_CODE', '49'))
    if number.startswith('+' + cc):
        dn = '0' + re.sub(r'[^0-9]', '', number[len(cc) + 1:])   # +49… → 0…
    elif number.startswith('+'):
        dn = '00' + re.sub(r'[^0-9]', '', number[1:])            # +xx… → 00xx…
    else:
        dn = re.sub(r'[^0-9]', '', number)
    if len(dn) < 3:
        return False, 'ungültige Nummer'

    callfile = (
        f"Channel: PJSIP/{dn}@3cx\n"
        f"CallerID: {DEFAULT_CALLERID}\n"
        f"MaxRetries: 1\n"
        f"RetryTime: 60\n"
        f"WaitTime: 60\n"
        f"Context: fax-send\n"
        f"Extension: send\n"
        f"Priority: 1\n"
        f"Setvar: FAXFILE={tiff_path}\n"
        f"Setvar: RESULTFILE={result_path}\n"
        # Fax-Header: Absenderkennung (T.30 Local Station ID) + Kopfzeilen-Name
        f"Setvar: LOCALID={re.sub(r'[^0-9+ ]', '', DEFAULT_CALLERID)}\n"
        f"Setvar: FAXHEADER={os.environ.get('FAX_OWNER', '')}\n"
    )
    # Atomar in den Spool legen (erst woanders schreiben, dann mv)
    tmp = os.path.join(FAX_DIR, f'{job}.call.tmp')
    with open(tmp, 'w') as f:
        f.write(callfile)
    os.replace(tmp, os.path.join(OUTGOING_DIR, f'{job}.call'))
    logger.info(f"→ Fax-Job {job} an {dn} eingereicht (Call-File)")

    # Auf Ergebnis warten (bis RESULT_WAIT_S – so lange blockiert die HTTP-Antwort)
    res = wait_for_result(result_path, RESULT_WAIT_S)
    if res:
        status, detail, pages = res
        ok = status.upper() in ('SUCCESS', 'OK')
        reason = short_reason(status, detail)
        logger.info(f"Job {job}: {status} {detail} pages={pages}")
        journal_append({'job': job, 'number': number, 'file': filename,
                        'status': status, 'detail': reason, 'pages': pages})
        return ok, f'{status} ({reason or detail}, {pages} Seiten)'

    # Timeout: vorläufig als "unbestätigt" protokollieren und im Hintergrund
    # weiter aufs Ergebnis warten – langsame Faxe kommen oft kurz danach an.
    journal_append({'job': job, 'number': number, 'file': filename,
                    'status': 'SUBMITTED', 'detail': 'noch keine Bestätigung',
                    'pages': '?'})
    threading.Thread(target=_reconcile_late, daemon=True,
                     args=(job, result_path)).start()
    return True, 'submitted (läuft, kein Ergebnis innerhalb Zeitfenster)'


def wait_for_result(result_path: str, timeout: int):
    """Bis zu timeout Sek. auf die Ergebnisdatei warten; (status,detail,pages) oder None."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(result_path):
            try:
                content = open(result_path).read().strip()
                os.unlink(result_path)
            except OSError:
                return None
            parts = content.split('|')
            return (parts[0] if parts else 'UNKNOWN',
                    parts[1] if len(parts) > 1 else '',
                    parts[2] if len(parts) > 2 else '?')
        time.sleep(1)
    return None


def _reconcile_late(job: str, result_path: str):
    """Nach dem HTTP-Timeout weiter warten und den Journal-Eintrag korrigieren."""
    res = wait_for_result(result_path, LATE_WAIT_S)
    if not res:
        return
    status, detail, pages = res
    logger.info(f"Job {job} (spät): {status} {detail} pages={pages}")
    journal_update(job, {'status': status, 'pages': pages,
                         'detail': short_reason(status, detail)})


class FaxHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        logger.info(f"{self.address_string()} {fmt % args}")

    def send_json(self, status: int, data: dict):
        body = json.dumps(data, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_health(self):
        ast = subprocess.run(['pgrep', 'asterisk'], capture_output=True).returncode == 0
        reg = 'Registered' in asterisk_cli('pjsip show registrations')
        self.send_json(200, {'status': 'ok', 'asterisk': ast,
                             'registered': reg, 'time': datetime.now().isoformat()})

    def handle_queue(self):
        try:
            pending = [f for f in os.listdir(OUTGOING_DIR) if f.endswith('.call')]
        except OSError:
            pending = []
        self.send_json(200, {'pending_calls': pending,
                             'registrations': asterisk_cli('pjsip show registrations')})

    def handle_root(self):
        """Sendeprotokoll als schlichte HTML-Seite (bewusst old-school)."""
        reg = 'Registered' in asterisk_cli('pjsip show registrations')
        rows = []
        for e in reversed(journal_read()):
            status = str(e.get('status', '?')).upper()
            if status == 'SUCCESS':
                badge = '&#10003; gesendet'
            elif status == 'SUBMITTED':
                badge = '&#8987; unbest&auml;tigt'
            else:
                badge = '&#10007; FEHLER'
            # Zeitpunkt eindeutig als UTC-Epoch – der Browser rechnet lokal um.
            ep = e.get('epoch')
            if ep is None:  # Alt-Einträge: 'ts' ist UTC-Klartext
                try:
                    ep = calendar.timegm(time.strptime(e.get('ts', ''),
                                                        '%Y-%m-%d %H:%M:%S'))
                except (ValueError, TypeError):
                    ep = 0
            rows.append(
                '<tr><td><span class="ts" data-ep="{ep}">{ts} UTC</span></td>'
                '<td>{nr}</td><td>{fn}</td>'
                '<td align="center">{pg}</td><td><b>{badge}</b>{detail}</td></tr>'.format(
                    ep=ep,
                    ts=html.escape(e.get('ts', '')),
                    nr=html.escape(str(e.get('number', ''))),
                    fn=html.escape(e.get('file', '') or '&ndash;'),
                    pg=html.escape(str(e.get('pages', '?'))),
                    badge=badge,
                    detail=(' <small>(%s)</small>' % html.escape(e['detail']))
                           if e.get('detail') else ''))
        page = f"""<html>
<head>
<title>Faxserver &ndash; Sendeprotokoll</title>
<meta charset="utf-8">
<meta http-equiv="refresh" content="30">
</head>
<body bgcolor="#ffffff" text="#000000" link="#0000ee">
<font face="Courier New, monospace">
<h2>&#128224; Faxserver &ndash; Sendeprotokoll</h2>
<p>Anlage: <b>{'&#10003; verbunden' if reg else '&#10007; NICHT registriert'}</b>
&nbsp;|&nbsp; Stand: <span class="ts" data-ep="{int(time.time())}">{datetime.utcnow().strftime('%d.%m.%Y %H:%M:%S')} UTC</span>
&nbsp;|&nbsp; <a href="/health">health</a> &middot; <a href="/queue">queue</a></p>
<hr>
<table border="1" cellpadding="4" cellspacing="0" width="100%">
<tr bgcolor="#dddddd">
<th align="left">Zeitpunkt</th><th align="left">An</th>
<th align="left">Datei</th><th>Seiten</th><th align="left">Status</th>
</tr>
{''.join(rows) if rows else '<tr><td colspan="5"><i>Noch keine Faxe gesendet.</i></td></tr>'}
</table>
<hr>
<p><small>Seite aktualisiert sich alle 30&nbsp;s &middot; Zeiten in lokaler Zeit.
Clients: <a href="/client/macos">macOS</a> &middot;
<a href="/client/windows-install">Windows-Installer</a></small></p>
</font>
<script>
// UTC-Epoch → lokale Zeit des Betrachters (inkl. Sommer-/Winterzeit)
for (var el of document.querySelectorAll('.ts')) {{
  var ep = parseInt(el.getAttribute('data-ep'), 10);
  if (ep > 0) el.textContent = new Date(ep * 1000).toLocaleString('de-DE',
    {{ dateStyle: 'medium', timeStyle: 'medium' }});
}}
</script>
</body>
</html>"""
        data = page.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_client(self, which: str):
        """Client-Script ausliefern – Server-Adresse/Port des Requests eingesetzt.
        So braucht ein Client-Rechner nur einen Download, kein Repo."""
        if which not in CLIENT_FILES:
            return self.send_json(404, {'error': f'Unbekannter Client: {which}',
                                        'available': sorted(CLIENT_FILES)})
        src_name, download_name = CLIENT_FILES[which]
        try:
            with open(os.path.join(CLIENTS_DIR, src_name), encoding='utf-8') as f:
                body = f.read()
        except OSError:
            return self.send_json(500, {'error': 'Client-Script fehlt im Image'})
        # Host, unter dem der Client UNS gerade erreicht hat = richtige Adresse
        host = (self.headers.get('Host') or 'localhost').rsplit(':', 1)[0]
        port = str(os.environ.get('API_PORT', 8080))
        body = body.replace('DEIN_SERVER_IP', host).replace('18080', port)
        data = body.encode('utf-8')

        # Windows PowerShell 5.1 benötigt für UTF-8-Scripts ein BOM.
        if which == 'windows':
            data = b'\xef\xbb\xbf' + data

        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Content-Disposition',
                         f'attachment; filename="{download_name}"')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_fax_post(self):
        env = {'REQUEST_METHOD': 'POST',
               'CONTENT_TYPE': self.headers.get('Content-Type', '')}
        form = cgi.FieldStorage(fp=self.rfile, headers=self.headers, environ=env)
        number = form.getvalue('number', '').strip().replace(' ', '')
        if not number:
            return self.send_json(400, {'error': 'Pflichtfeld fehlt: number'})
        if 'file' not in form:
            return self.send_json(400, {'error': 'Pflichtfeld fehlt: file (PDF)'})
        pdf_data = form['file'].file.read()
        orig_name = os.path.basename(getattr(form['file'], 'filename', '') or '')
        if not pdf_data:
            return self.send_json(400, {'error': 'Leere Datei'})

        with tempfile.NamedTemporaryFile(suffix='.pdf', delete=False,
                                         dir='/tmp', prefix='fax_') as tmp:
            tmp.write(pdf_data)
            pdf_path = tmp.name
        tiff_path = os.path.join(FAX_DIR, uuid.uuid4().hex[:10] + '.tif')

        try:
            ok, msg = pdf_to_tiff(pdf_path, tiff_path)
            if not ok:
                return self.send_json(500, {'status': 'error',
                                            'error': f'PDF→TIFF: {msg}'})
            ok, msg = submit_fax(number, tiff_path, orig_name)
            self.send_json(200 if ok else 500,
                          {'status': 'sent' if ok else 'error',
                           'number': number, 'result': msg})
        finally:
            try:
                os.unlink(pdf_path)
            except OSError:
                pass

    def do_GET(self):
        if self.path in ('/', '/index.html'):
            self.handle_root()
        elif self.path == '/health':
            self.handle_health()
        elif self.path == '/queue':
            self.handle_queue()
        elif self.path.startswith('/client/'):
            self.handle_client(self.path[len('/client/'):])
        else:
            self.send_json(404, {'error': 'Not found'})

    def do_POST(self):
        if self.path == '/fax':
            try:
                self.handle_fax_post()
            except Exception as e:
                logger.exception("Fehler in /fax")
                self.send_json(500, {'error': str(e)})
        else:
            self.send_json(404, {'error': 'Not found'})


if __name__ == '__main__':
    os.makedirs(OUTGOING_DIR, exist_ok=True)
    os.makedirs(FAX_DIR, exist_ok=True)
    port = int(os.environ.get('API_PORT', 8080))
    server = http.server.ThreadingHTTPServer(('0.0.0.0', port), FaxHandler)
    logger.info(f"Fax-API bereit auf Port {port}")
    server.serve_forever()
