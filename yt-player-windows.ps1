#Requires -Version 5.1
<#
.SYNOPSIS
    Reproduce videos de YouTube en MPV con selección de resolución.
.DESCRIPTION
    Detecta la URL del portapapeles o la pide al usuario,
    muestra las resoluciones disponibles y abre MPV para reproducir.
    Requiere: yt-dlp.exe, ffprobe.exe y mpv.exe en el PATH del sistema.
.NOTES
    Para correr el script:
      - Doble clic en lanzar.bat  (recomendado)
      - O desde PowerShell: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass; & ".\ytplayer.ps1"
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ─────────────────────────────────────────────────────────────────
# VERIFICAR DEPENDENCIAS
# ─────────────────────────────────────────────────────────────────
foreach ($tool in @("yt-dlp", "ffprobe", "mpv")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.MessageBox]::Show(
            "No se encontró '$tool' en el PATH del sistema.`n`nDescárgalo y agrégalo al PATH antes de continuar.",
            "Dependencia faltante",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit 1
    }
}


# ═════════════════════════════════════════════════════════════════
# HELPERS — DIÁLOGOS
# ═════════════════════════════════════════════════════════════════

function Show-Info {
    param($Text, $Title = "Info")
    $f = New-Object System.Windows.Forms.Form
    $f.TopMost = $true; $f.ShowInTaskbar = $false
    $f.WindowState = 'Minimized'; $f.Show(); $f.Focus()
    [System.Windows.Forms.MessageBox]::Show($f, $Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    $f.Dispose()
}

function Show-Err {
    param($Text, $Title = "Error")
    $f = New-Object System.Windows.Forms.Form
    $f.TopMost = $true; $f.ShowInTaskbar = $false
    $f.WindowState = 'Minimized'; $f.Show(); $f.Focus()
    [System.Windows.Forms.MessageBox]::Show($f, $Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    $f.Dispose()
}

function Show-InputDialog {
    param($Title, $Prompt)

    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.ClientSize = [System.Drawing.Size]::new(460, 130)
    $f.StartPosition = "CenterScreen"
    $f.FormBorderStyle = "FixedDialog"
    $f.TopMost = $true
    $f.MaximizeBox = $false; $f.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Prompt; $lbl.AutoSize = $false
    $lbl.SetBounds(12, 12, 436, 36)
    $f.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.SetBounds(12, 52, 436, 24)
    $f.Controls.Add($txt)

    $btnOk  = New-Object System.Windows.Forms.Button
    $btnOk.Text = "OK"; $btnOk.DialogResult = "OK"
    $btnOk.SetBounds(370, 88, 78, 28)

    $btnCnl = New-Object System.Windows.Forms.Button
    $btnCnl.Text = "Cancelar"; $btnCnl.DialogResult = "Cancel"
    $btnCnl.SetBounds(278, 88, 84, 28)

    $f.Controls.AddRange(@($btnOk, $btnCnl))
    $f.AcceptButton = $btnOk; $f.CancelButton = $btnCnl

    if ($f.ShowDialog() -eq "OK") { return $txt.Text.Trim() }
    return $null
}

function Show-ListDialog {
    param($Title, $Prompt, [string[]]$Items, $OkLabel = "Seleccionar")

    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.ClientSize = [System.Drawing.Size]::new(540, 430)
    $f.StartPosition = "CenterScreen"
    $f.FormBorderStyle = "FixedDialog"
    $f.TopMost = $true
    $f.MaximizeBox = $false; $f.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Prompt; $lbl.AutoSize = $false
    $lbl.SetBounds(12, 10, 516, 40)
    $f.Controls.Add($lbl)

    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Font = New-Object System.Drawing.Font("Consolas", 9)
    $lb.SetBounds(12, 54, 516, 318)
    $lb.IntegralHeight = $false
    foreach ($item in $Items) { $lb.Items.Add($item) | Out-Null }
    if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }
    $f.Controls.Add($lb)

    $btnOk  = New-Object System.Windows.Forms.Button
    $btnOk.Text = $OkLabel; $btnOk.DialogResult = "OK"
    $btnOk.SetBounds(444, 385, 84, 28)

    $btnCnl = New-Object System.Windows.Forms.Button
    $btnCnl.Text = "Cancelar"; $btnCnl.DialogResult = "Cancel"
    $btnCnl.SetBounds(346, 385, 90, 28)

    $f.Controls.AddRange(@($btnOk, $btnCnl))
    $f.AcceptButton = $btnOk; $f.CancelButton = $btnCnl
    $lb.add_DoubleClick({ $f.DialogResult = "OK"; $f.Close() })

    if ($f.ShowDialog() -eq "OK" -and $null -ne $lb.SelectedItem) {
        return $lb.SelectedItem.ToString()
    }
    return $null
}


# ═════════════════════════════════════════════════════════════════
# HELPERS — PROCESOS
# ═════════════════════════════════════════════════════════════════

function Invoke-Hidden {
    param([string]$Exe, [string]$ArgList, [int]$TimeoutMs = 60000)
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $Exe -ArgumentList $ArgList `
        -RedirectStandardOutput $tmpOut `
        -RedirectStandardError  $tmpErr `
        -NoNewWindow -PassThru
    $finished = $p.WaitForExit($TimeoutMs)
    if (-not $finished) { try { $p.Kill() } catch {} }
    $out = Get-Content $tmpOut -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    if ($out) { return $out } else { return "" }
}


# ═════════════════════════════════════════════════════════════════
# HELPERS — FORMATOS
# ═════════════════════════════════════════════════════════════════

function Get-VideoFormats {
    param($Json)

    $fmts = $Json.formats | Where-Object {
        $_.vcodec -and $_.vcodec -ne 'none' -and $_.height
    }

    $rows = foreach ($f in $fmts) {
        $codec = ($f.vcodec -replace '\..*', '').ToLower()

        $rank = switch -Wildcard ($codec) {
            'av01' { 3 };  'av1'  { 3 }
            'vp09' { 2 };  'vp9'  { 2 }
            'avc1' { 1 };  'h264' { 1 }
            default { 0 }
        }

        $hdr = if ($f.dynamic_range -and $f.dynamic_range -ne 'SDR') { 1 } else { 0 }
        $fps = if ($f.fps) { [int]$f.fps } else { 0 }
        $tbr = if ($f.tbr) { [int]$f.tbr } else { 0 }
        $h   = [int]$f.height

        $desc = "$($h)p"
        if ($fps -gt 0) { $desc += " $($fps)fps" }
        $desc += " $codec"
        if ($tbr -gt 0) { $desc += " ($($tbr)k)" }
        if ($hdr -eq 1) { $desc += " (HDR)" }

        [PSCustomObject]@{
            ID   = $f.format_id
            H    = $h
            FPS  = $fps
            Rank = $rank
            TBR  = $tbr
            HDR  = $hdr
            Desc = $desc
        }
    }

    $sorted = $rows | Sort-Object @{E='H';D=1}, @{E='HDR';D=1}, @{E='FPS';D=1},
                                   @{E='Rank';D=1}, @{E='TBR';D=1}

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $sorted | Where-Object { $seen.Add($_.Desc) }
}


# ═════════════════════════════════════════════════════════════════
# PASO 1 — OBTENER URL
# ═════════════════════════════════════════════════════════════════

$URL = $null
try {
    $clip = Get-Clipboard -Format Text -Raw 2>$null
    if ($clip -match '(https?://[^\s"''<>]+)') { $URL = $Matches[1].Trim() }
} catch {}

if (-not $URL) {
    $URL = Show-InputDialog -Title "Reproducir video" -Prompt "Pega el enlace del video:"
    if (-not $URL) { exit 0 }
}


# ═════════════════════════════════════════════════════════════════
# PASO 2 — OBTENER TÍTULO Y FORMATOS
# ═════════════════════════════════════════════════════════════════

$TITLE = (Invoke-Hidden "yt-dlp" "--get-title `"$URL`"" -TimeoutMs 60000).Trim()
if (-not $TITLE) {
    Show-Err "No se pudo obtener información del video.`n`nVerifica que la URL sea correcta."
    exit 1
}

$jsonRaw = Invoke-Hidden "yt-dlp" "-j `"$URL`"" -TimeoutMs 60000
try   { $jsonData = $jsonRaw | ConvertFrom-Json }
catch { Show-Err "No se pudieron obtener los formatos disponibles."; exit 1 }

$formats  = @(Get-VideoFormats $jsonData)
if ($formats.Count -eq 0) {
    Show-Err "No se encontraron formatos de video disponibles."
    exit 1
}

$fmtItems = @($formats | ForEach-Object { $_.Desc })


# ═════════════════════════════════════════════════════════════════
# PASO 3 — SELECCIONAR RESOLUCIÓN
# ═════════════════════════════════════════════════════════════════

$SELECTED = Show-ListDialog -Title "Seleccionar calidad" `
    -Prompt "Video: $TITLE`n`nSelecciona la resolución para reproducir:" `
    -Items $fmtItems -OkLabel "Reproducir"
if (-not $SELECTED) { exit 0 }

$matchFmt  = $formats | Where-Object { $_.Desc -eq $SELECTED } | Select-Object -First 1
$FORMAT_ID = "$($matchFmt.ID)+bestaudio"


# ═════════════════════════════════════════════════════════════════
# PASO 4 — ABRIR EN MPV
# ═════════════════════════════════════════════════════════════════

# --ytdl-format le dice a MPV exactamente qué stream pedir
# MPV usa yt-dlp internamente para resolver la URL
Start-Process -FilePath "mpv" `
    -ArgumentList "--ytdl-format=`"$FORMAT_ID`" `"$URL`"" `
    -NoNewWindow
