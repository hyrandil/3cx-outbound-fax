# ══════════════════════════════════════════════════════════
#  Fax senden – Windows Client
#
#  Pendant zum macOS-PDF-Service. Windows hat keinen "PDF ▼"
#  im Druckdialog, daher der idiomatische Weg:
#    Rechtsklick auf eine PDF → "Senden an" → "Fax senden"
#
#  Aufruf:  powershell -File "Fax senden.ps1" <pfad-zur.pdf>
#  install.ps1 ersetzt DEIN_SERVER_IP und legt die Verknüpfung
#  im "Senden an"-Menü an.
#
#  Kompatibel mit Windows PowerShell 5.1 (Standard, keine
#  Zusatzinstallation nötig).
# ══════════════════════════════════════════════════════════

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FaxArgs
)

# ── Konfiguration (install.ps1 ersetzt DEIN_SERVER_IP) ──────
$FaxServer = if ($env:FAX_SERVER) { $env:FAX_SERVER } else { 'DEIN_SERVER_IP' }
$FaxPort   = if ($env:FAX_PORT)   { $env:FAX_PORT }   else { '18080' }
# ────────────────────────────────────────────────────────────

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-Error([string]$Message) {
    [System.Windows.Forms.MessageBox]::Show(
        $Message, 'Fax senden',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Show-Info([string]$Message) {
    [System.Windows.Forms.MessageBox]::Show(
        $Message, 'Fax senden',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

# ── PDF unter den Argumenten finden ─────────────────────────
$PdfFile = $null
foreach ($arg in $FaxArgs) {
    if ($arg -and (Test-Path -LiteralPath $arg -PathType Leaf)) {
        if ($arg -match '\.pdf$') { $PdfFile = $arg; break }
        if (-not $PdfFile) { $PdfFile = $arg }
    }
}

if (-not $PdfFile -or -not (Test-Path -LiteralPath $PdfFile -PathType Leaf)) {
    Show-Error "Es wurde keine PDF-Datei übergeben.`n`nSo verwenden: im Explorer Rechtsklick auf eine PDF → Senden an → „Fax senden“.`n`nTipp: Aus jeder App zuerst über „Microsoft Print to PDF“ (Strg+P) eine PDF erzeugen."
    exit 1
}

$BaseUrl = "http://${FaxServer}:${FaxPort}"

# ── Server erreichbar & registriert? ────────────────────────
try {
    $health = Invoke-RestMethod -Uri "$BaseUrl/health" -TimeoutSec 3 -ErrorAction Stop
} catch {
    Show-Error "Der Fax-Server antwortet nicht:`n$BaseUrl`n`nBitte prüfen:`n• Läuft der Docker-Container?  (docker compose ps)`n• Stimmen Adresse und Port? (install.ps1 erneut ausführen)`n• Zum Testen im Browser öffnen:`n   $BaseUrl/health"
    exit 1
}
if (-not $health.registered) {
    Show-Error "Der Fax-Server läuft, ist aber nicht an der 3CX-Anlage angemeldet – das Fax würde fehlschlagen.`n`nBitte prüfen:`n• 3CX erreichbar? SBC verbunden?`n• Zugangsdaten in der .env korrekt?`n• Details:  docker logs faxserver"
    exit 1
}

# ── Faxnummer abfragen (kleine WinForms-Eingabemaske) ───────
function Read-FaxNumber {
    $form = New-Object System.Windows.Forms.Form
    $form.Text          = 'Fax senden'
    $form.Size          = New-Object System.Drawing.Size(360, 175)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox   = $false
    $form.MinimizeBox   = $false
    $form.TopMost       = $true

    $label = New-Object System.Windows.Forms.Label
    $label.Text     = "Faxnummer eingeben:`n(z.B. 068112345 oder +4968112345)"
    $label.Location = New-Object System.Drawing.Point(12, 12)
    $label.Size     = New-Object System.Drawing.Size(330, 40)
    $form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(12, 58)
    $textBox.Size     = New-Object System.Drawing.Size(322, 24)
    $form.Controls.Add($textBox)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text         = 'Senden'
    $ok.Location     = New-Object System.Drawing.Point(178, 95)
    $ok.Size         = New-Object System.Drawing.Size(75, 28)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)
    $form.AcceptButton = $ok

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text         = 'Abbrechen'
    $cancel.Location     = New-Object System.Drawing.Point(259, 95)
    $cancel.Size         = New-Object System.Drawing.Size(75, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)
    $form.CancelButton = $cancel

    $form.Add_Shown({ $textBox.Focus() }) | Out-Null
    $result = $form.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $textBox.Text
    }
    return $null
}

$RawNumber = Read-FaxNumber
if ($null -eq $RawNumber) { exit 0 }   # abgebrochen

$FaxNum = ($RawNumber -replace '\s', '')
if (-not $FaxNum) {
    Show-Error "Keine Faxnummer eingegeben."
    exit 1
}

# ── Multipart/form-data bauen (PS 5.1-kompatibel) ───────────
function Send-Fax([string]$Url, [string]$Path, [string]$Number) {
    $boundary = [System.Guid]::NewGuid().ToString()
    $LF = "`r`n"
    $fileName = [System.IO.Path]::GetFileName($Path)
    $fileBytes = [System.IO.File]::ReadAllBytes($Path)
    $enc = [System.Text.Encoding]::GetEncoding('iso-8859-1')

    $head = New-Object System.Text.StringBuilder
    [void]$head.Append("--$boundary$LF")
    [void]$head.Append("Content-Disposition: form-data; name=`"number`"$LF$LF")
    [void]$head.Append("$Number$LF")
    [void]$head.Append("--$boundary$LF")
    [void]$head.Append("Content-Disposition: form-data; name=`"file`"; filename=`"$fileName`"$LF")
    [void]$head.Append("Content-Type: application/pdf$LF$LF")

    $tail = "$LF--$boundary--$LF"

    $body = New-Object System.IO.MemoryStream
    $headBytes = $enc.GetBytes($head.ToString())
    $tailBytes = $enc.GetBytes($tail)
    $body.Write($headBytes, 0, $headBytes.Length)
    $body.Write($fileBytes, 0, $fileBytes.Length)
    $body.Write($tailBytes, 0, $tailBytes.Length)
    $bodyBytes = $body.ToArray()
    $body.Dispose()

    # Die API blockiert, bis das Fax übertragen ist (bis ~90 s) → großzügiges
    # Timeout, sonst Abbruch, obwohl das Fax noch läuft.
    return Invoke-RestMethod -Uri $Url -Method Post -TimeoutSec 150 `
        -ContentType "multipart/form-data; boundary=$boundary" `
        -Body $bodyBytes
}

# ── Senden ──────────────────────────────────────────────────
try {
    # API-Antwort: {"status":"sent","number":"…","result":"SUCCESS (…, N Seiten)"}
    $response = Send-Fax -Url "$BaseUrl/fax" -Path $PdfFile -Number $FaxNum
    if ($response.result) {
        Show-Info "Fax an ${FaxNum}: $($response.result)"
    } else {
        Show-Info "Fax an $FaxNum eingereicht."
    }
} catch {
    $errMsg = $_.Exception.Message

    if ($_.Exception.Response) {
        # API-Fehler: "error" (z.B. PDF-Konvertierung) oder "result"
        # (z.B. FAILED = Gegenstelle nicht erreicht / kein Fax)
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $json = $reader.ReadToEnd() | ConvertFrom-Json
            if     ($json.error)  { $errMsg = $json.error }
            elseif ($json.result) { $errMsg = $json.result }
        } catch { }

        if ($errMsg -match '^FAILED.*call-setup') {
            $errMsg = "Die Gegenstelle wurde nicht erreicht (besetzt, falsche Nummer oder Ziel nimmt nicht ab)."
        } elseif ($errMsg -match '^FAILED') {
            $errMsg = "Übertragung fehlgeschlagen: $errMsg`n`nIst die Gegenstelle wirklich ein Faxgerät? Bei externen Zielen: unterstützt der 3CX-Trunk T.38?"
        }
        Show-Error "Fax an $FaxNum fehlgeschlagen.`n`n$errMsg"
    } elseif ($errMsg -match 'Zeitüberschreitung|timed out|timeout') {
        # Timeout: das Fax kann auf dem Server trotzdem noch durchlaufen
        Show-Info "Nach 150 s keine Antwort – das Fax an $FaxNum läuft möglicherweise noch.`n`nSendeprotokoll: $BaseUrl/"
    } else {
        Show-Error "Fax an $FaxNum fehlgeschlagen.`n`n$errMsg`n`nDetails:  docker logs faxserver"
    }
    exit 1
}

exit 0
