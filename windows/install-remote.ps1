# install-remote.ps1 – Fax-Client-Installation direkt vom Fax-Server
#
# Wird vom Faxserver unter /client/windows-install ausgeliefert; die
# Server-Adresse ist dann bereits eingesetzt. Einzeiler auf dem Client-PC:
#
#   irm http://DEIN_SERVER_IP:18080/client/windows-install | iex
#
# Lädt das Client-Script vom Server und legt den "Senden an"-Eintrag an.
# Kein Admin nötig (Installation pro Benutzer), PowerShell 5.1 genügt.

$ErrorActionPreference = 'Stop'
$BaseUrl = 'http://DEIN_SERVER_IP:18080'

Write-Host '╔══════════════════════════════════════╗'
Write-Host '║   Fax-Client Installation (Windows)  ║'
Write-Host '╚══════════════════════════════════════╝'
Write-Host "Server: $BaseUrl"
Write-Host ''

# ── Client-Script vom Server laden (kommt fertig konfiguriert) ──
$InstallDir = Join-Path $env:LOCALAPPDATA 'FaxSenden'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$TargetScript = Join-Path $InstallDir 'Fax senden.ps1'

Invoke-RestMethod -Uri "$BaseUrl/client/windows" -TimeoutSec 10 -OutFile $TargetScript
Write-Host "✓ Client-Script geladen: $TargetScript"

# ── "Senden an"-Verknüpfung anlegen ─────────────────────────
$SendToDir = [Environment]::GetFolderPath('SendTo')
$LnkPath   = Join-Path $SendToDir 'Fax senden.lnk'

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($LnkPath)
$shortcut.TargetPath = (Join-Path $PSHOME 'powershell.exe')
# Windows hängt beim "Senden an" den PDF-Pfad automatisch als Argument an.
$shortcut.Arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TargetScript`""
$shortcut.IconLocation = 'imageres.dll,68'   # Drucker-/Fax-Symbol
$shortcut.Description = 'PDF als Fax über den Fax-Server senden'
$shortcut.WorkingDirectory = $InstallDir
$shortcut.Save()
Write-Host "✓ 'Senden an'-Eintrag angelegt: $LnkPath"

# ── Verbindungstest ─────────────────────────────────────────
try {
    $h = Invoke-RestMethod -Uri "$BaseUrl/health" -TimeoutSec 5
    if ($h.registered) { Write-Host '✓ Fax-Server erreichbar und an 3CX registriert.' -ForegroundColor Green }
    else               { Write-Host '⚠ Fax-Server erreichbar, aber NICHT an 3CX registriert.' -ForegroundColor Yellow }
} catch {
    Write-Host '⚠ Fax-Server aktuell nicht erreichbar.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '── So verwenden ──────────────────────────────────────'
Write-Host '  Explorer: Rechtsklick auf eine PDF → Senden an → "Fax senden"'
Write-Host '  Aus jeder App: erst "Microsoft Print to PDF" (Strg+P), dann faxen.'
