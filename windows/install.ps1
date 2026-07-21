# install.ps1 – Installiert den Fax-Client unter Windows
# Einmalig pro PC ausführen (kein Admin nötig, installiert pro Benutzer).
#
# Ausführen:  Rechtsklick → "Mit PowerShell ausführen"
#  oder:      powershell -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceScript = Join-Path $ScriptDir 'Fax senden.ps1'

Write-Host '╔══════════════════════════════════════╗'
Write-Host '║   Fax-Client Installation (Windows)  ║'
Write-Host '╚══════════════════════════════════════╝'
Write-Host ''

if (-not (Test-Path -LiteralPath $SourceScript)) {
    Write-Host "✗ 'Fax senden.ps1' nicht gefunden neben install.ps1." -ForegroundColor Red
    exit 1
}

# ── Server-IP abfragen ──────────────────────────────────────
$ServerIp = Read-Host 'IP/Hostname des Fax-Servers [localhost]'
if ([string]::IsNullOrWhiteSpace($ServerIp)) { $ServerIp = 'localhost' }

# ── Skript konfigurieren & an stabilen Ort kopieren ─────────
$InstallDir = Join-Path $env:LOCALAPPDATA 'FaxSenden'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$TargetScript = Join-Path $InstallDir 'Fax senden.ps1'

(Get-Content -LiteralPath $SourceScript -Raw) `
    -replace 'DEIN_SERVER_IP', $ServerIp |
    Set-Content -LiteralPath $TargetScript -Encoding UTF8

Write-Host ''
Write-Host "✓ Skript installiert: $TargetScript"

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
Write-Host ''
Write-Host '── So verwenden ──────────────────────────────────────'
Write-Host '  1. Im Explorer Rechtsklick auf eine PDF-Datei'
Write-Host "  2. Senden an  →  'Fax senden'"
Write-Host '  3. Faxnummer eingeben → Senden'
Write-Host ''
Write-Host '  Tipp: Aus jeder App via "Microsoft Print to PDF" eine'
Write-Host '        PDF erzeugen, dann per Rechtsklick faxen.'
Write-Host ''
Write-Host '── Server-Status prüfen ──────────────────────────────'
Write-Host "  http://${ServerIp}:18080/health"
Write-Host ''

# ── Sofort testen ───────────────────────────────────────────
$test = Read-Host 'Verbindung zum Fax-Server jetzt testen? (j/N)'
if ($test -match '^[jJ]$') {
    Write-Host ''
    try {
        Invoke-RestMethod -Uri "http://${ServerIp}:18080/health" -TimeoutSec 5 | Out-Null
        Write-Host '✓ Fax-Server erreichbar!' -ForegroundColor Green
    } catch {
        Write-Host '✗ Fax-Server nicht erreichbar. Docker gestartet?' -ForegroundColor Red
    }
}
