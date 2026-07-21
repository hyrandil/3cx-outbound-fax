# ─────────────────────────────────────────────────────────────────────────────
#  3CX Outbound Fax – Asterisk + spandsp (res_fax_spandsp), T.38 über SIP
#
#  Schlankes Single-Stage-Image auf Alpine: Alpine paketiert res_fax_spandsp
#  fertig (Paket asterisk-fax) → KEIN Source-Compile, kein Fremd-Image.
#  Asterisk registriert sich (via lokalem 3CX-SBC) bei der 3CX-Anlage und
#  sendet Faxe per SendFAX/T.38. Eine kleine HTTP-API nimmt PDFs entgegen,
#  wandelt sie nach TIFF (ghostscript) und stößt den Versand an (Call-File).
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:3.21

# asterisk            PBX-Kern (chan_pjsip, res_fax, pbx_spool, app_originate …)
# asterisk-fax        res_fax_spandsp (G.711/T.38 Fax-Engine)
# ghostscript         PDF → TIFF (Fax-Format G4)
# python3             HTTP-API (stdlib, kein pip)
# tini                sauberes Signal-/Zombie-Handling als PID 1
RUN apk add --no-cache \
        asterisk \
        asterisk-fax \
        ghostscript \
        python3 \
        tini \
        gettext

# Asterisk-Konfiguration (pjsip.conf wird beim Start mit den .env-Werten befüllt)
COPY configs/asterisk.conf    /etc/asterisk/asterisk.conf
COPY configs/modules.conf     /etc/asterisk/modules.conf
COPY configs/logger.conf      /etc/asterisk/logger.conf
COPY configs/res_fax.conf     /etc/asterisk/res_fax.conf
COPY configs/udptl.conf       /etc/asterisk/udptl.conf
COPY configs/pjsip.conf       /etc/asterisk/pjsip.conf.tmpl
COPY configs/extensions.conf  /etc/asterisk/extensions.conf

COPY scripts/start.sh         /start.sh
COPY scripts/fax-api.py       /usr/local/bin/fax-api.py

# Client-Scripts: die API liefert sie unter GET /client/{macos,windows,
# windows-install} fertig konfiguriert aus (kein Repo auf Client-Rechnern nötig)
COPY ["macos/Fax senden",          "/usr/local/share/fax-clients/Fax senden"]
COPY ["windows/Fax senden.ps1",    "/usr/local/share/fax-clients/Fax senden.ps1"]
COPY ["windows/install-remote.ps1","/usr/local/share/fax-clients/install-remote.ps1"]

RUN chmod +x /start.sh /usr/local/bin/fax-api.py \
 && mkdir -p /var/spool/asterisk/outgoing /var/spool/asterisk/fax /var/log/asterisk

EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/start.sh"]
