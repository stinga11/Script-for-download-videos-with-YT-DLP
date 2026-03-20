#Requires -Version 5.1
<#
.SYNOPSIS
    Descargador de videos de YouTube con interfaz gráfica nativa de Windows.
.DESCRIPTION
    Descarga videos individuales o playlists con selección de formato y barra de progreso.
    Requiere: yt-dlp.exe y ffmpeg.exe (con ffprobe.exe) en el PATH del sistema.
.NOTES
    Cómo correr el script:
      - Clic derecho sobre el archivo > "Ejecutar con PowerShell"
      - O desde consola PowerShell: .\ytdownloader.ps1
    Si aparece error de ejecución de scripts, correr primero:
      Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ─────────────────────────────────────────────────────────────────
# VERIFICAR DEPENDENCIAS
# ─────────────────────────────────────────────────────────────────
foreach ($tool in @("yt-dlp", "ffmpeg", "ffprobe")) {
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

$DownloadDir = "$env:USERPROFILE\Videos"
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null


# ═════════════════════════════════════════════════════════════════
# HELPERS - DIÁLOGOS
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

function Show-Question {
    param($Text, $Title = "Pregunta")
    $f = New-Object System.Windows.Forms.Form
    $f.TopMost = $true; $f.ShowInTaskbar = $false
    $f.WindowState = 'Minimized'; $f.Show(); $f.Focus()
    $r = [System.Windows.Forms.MessageBox]::Show($f, $Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    $f.Dispose()
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
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
# HELPERS - VENTANA DE PROGRESO (no bloqueante con DoEvents)
# ═════════════════════════════════════════════════════════════════

$script:PF        = $null
$script:ProgressCancelled = $false

function Open-Progress {
    param($Title, $Text, [switch]$Marquee)
    $script:ProgressCancelled = $false

    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.ClientSize = [System.Drawing.Size]::new(580, 110)
    $f.StartPosition = "CenterScreen"
    $f.FormBorderStyle = "FixedDialog"
    $f.TopMost = $true
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ControlBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text; $lbl.AutoSize = $false
    $lbl.SetBounds(12, 10, 556, 36)
    $f.Controls.Add($lbl)

    $pb = New-Object System.Windows.Forms.ProgressBar
    $pb.SetBounds(12, 50, 556, 22)
    $pb.Minimum = 0; $pb.Maximum = 100; $pb.Value = 0
    if ($Marquee) { $pb.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee }
    $f.Controls.Add($pb)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Cancelar"; $btn.SetBounds(484, 78, 84, 24)
    $btn.Add_Click({ $script:ProgressCancelled = $true })
    $f.Controls.Add($btn)

    $f.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $script:PF = @{ Form = $f; Label = $lbl; Bar = $pb }
}

function Set-Progress {
    param([int]$Pct, $Text)
    if (-not $script:PF) { return }
    if ($Text) { $script:PF.Label.Text = $Text }
    try { $script:PF.Bar.Value = [Math]::Max(0, [Math]::Min($Pct, 100)) } catch {}
    [System.Windows.Forms.Application]::DoEvents()
}

function Close-Progress {
    if ($script:PF) { $script:PF.Form.Close(); $script:PF = $null }
    [System.Windows.Forms.Application]::DoEvents()
}


# ═════════════════════════════════════════════════════════════════
# HELPERS - PROCESOS
# ═════════════════════════════════════════════════════════════════

# Ejecutar proceso oculto y devolver su stdout completo (bloqueante)
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

# Lanzar yt-dlp escribiendo a archivo temporal y leyendo con polling.
# Evita el problema de herencia de handles en Windows donde ffmpeg hijo
# hereda los streams redirigidos de yt-dlp y crashea al fusionar.
function Invoke-YtDlpWithProgress {
    param(
        [string]$Arguments,
        [string]$Title,
        [string]$InitText,
        [switch]$IsPlaylist
    )

    $tmpLog = [System.IO.Path]::GetTempFileName()

    # Lanzar yt-dlp redirigiendo stdout+stderr a archivo temporal
    # Usar cmd /c para que la redirección sea a nivel de shell y ffmpeg
    # hijo NO herede handles de PowerShell
    $cmdArgs = "/c yt-dlp $Arguments > `"$tmpLog`" 2>&1"
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs `
        -NoNewWindow -PassThru

    Open-Progress -Title $Title -Text $InitText
    $cancelled = $false
    $lastSize  = 0

    while (-not $proc.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()

        if ($script:ProgressCancelled) {
            # Matar cmd.exe y TODOS sus hijos (yt-dlp, ffmpeg) de golpe
            try { Start-Process "taskkill" -ArgumentList "/F /T /PID $($proc.Id)" -NoNewWindow -Wait } catch {}
            $cancelled = $true
            break
        }

        # Leer líneas nuevas del log
        try {
            $fs     = [System.IO.File]::Open($tmpLog,
                        [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read,
                        [System.IO.FileShare]::ReadWrite)
            $reader = New-Object System.IO.StreamReader($fs)
            $reader.BaseStream.Seek($lastSize, [System.IO.SeekOrigin]::Begin) | Out-Null
            while (-not $reader.EndOfStream) {
                $line  = $reader.ReadLine()
                $lastSize = $reader.BaseStream.Position
                $clean = $line.Trim()

                if ($IsPlaylist) {
                    if ($clean -match '^([\d.]+)%\|(\d+)\|(\d+)\|(.*)$') {
                        $perc  = [int][Math]::Min([double]$Matches[1], 99)
                        $idx   = [int]$Matches[2]
                        $ntot  = [int]$Matches[3]
                        $vtit  = $Matches[4]
                        if ($ntot -gt 0) {
                            $overall = [int][Math]::Min((($idx - 1) * 100 + $perc) / $ntot, 99)
                            Set-Progress -Pct $overall -Text "[Video $idx/$ntot]  $vtit  -  $perc%   |   Playlist: $overall%"
                        }
                    }
                } else {
                    if ($clean -match '^([\d.]+)%$') {
                        $perc = [int][Math]::Min([double]$Matches[1], 99)
                        Set-Progress -Pct $perc -Text "Descargando: $perc %"
                    }
                    # Durante la fusion con ffmpeg mostrar mensaje fijo
                    if ($clean -match '\[Merger\]|\[ffmpeg\]') {
                        Set-Progress -Pct 99 -Text "Fusionando audio y video..."
                    }
                }
            }
            $reader.Close()
            $fs.Close()
        } catch {}

        Start-Sleep -Milliseconds 200
    }

    Close-Progress
    try { $proc.WaitForExit() } catch {}
    Remove-Item $tmpLog -Force -ErrorAction SilentlyContinue

    return @{ Cancelled = $cancelled; ExitCode = $proc.ExitCode }
}


# ═════════════════════════════════════════════════════════════════
# HELPERS - FORMATOS Y MEDIA
# ═════════════════════════════════════════════════════════════════

# Parsear formatos de video desde el JSON de "yt-dlp -j"
function Get-VideoFormats {
    param($Json)

    $fmts = $Json.formats | Where-Object {
        $_.vcodec -and $_.vcodec -ne 'none' -and $_.height
    }

    $rows = foreach ($f in $fmts) {
        # Normalizar nombre de codec (quitar perfil tras el punto)
        $codec = ($f.vcodec -replace '\..*', '').ToLower()

        # Rango de calidad del codec (mayor = mejor)
        $rank = switch -Wildcard ($codec) {
            'av01' { 3 };  'av1'  { 3 }
            'vp09' { 2 };  'vp9'  { 2 }
            'avc1' { 1 };  'h264' { 1 }
            default { 0 }
        }

        $hdr = if ($f.dynamic_range -and $f.dynamic_range -ne 'SDR') { 1 } else { 0 }
        $fps = if ($f.fps)  { [int]$f.fps  } else { 0 }
        $tbr = if ($f.tbr)  { [int]$f.tbr  } else { 0 }
        $h   = [int]$f.height

        $desc = "$($h)p"
        if ($fps -gt 0) { $desc += " $($fps)fps" }
        $desc += " $codec"
        if ($tbr -gt 0) { $desc += " ($($tbr)k)" }
        if ($hdr -eq 1) { $desc += " (HDR)" }

        [PSCustomObject]@{ ID   = $f.format_id; H  = $h
                           FPS  = $fps;          Rank = $rank
                           TBR  = $tbr;          HDR = $hdr
                           Desc = $desc }
    }

    # Ordenar: altura↓, HDR↓, fps↓, calidad de codec↓, bitrate↓
    $sorted = $rows | Sort-Object @{E='H';D=1}, @{E='HDR';D=1}, @{E='FPS';D=1},
                                   @{E='Rank';D=1}, @{E='TBR';D=1}

    # Deduplicar por descripción (evitar duplicados de distintos IDs)
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $sorted | Where-Object { $seen.Add($_.Desc) }
}

# Limpiar nombre para usarlo como carpeta/archivo en Windows
function Get-SafeName {
    param($Name)
    $safe = $Name -replace '[\\/:*?"<>|]', '_'
    $safe = $safe.Trim()
    if (-not $safe) { $safe = "Descarga" }
    return $safe
}

# Información de codec/resolución de un archivo usando ffprobe
function Get-MediaInfo {
    param($Path)
    $v = (Invoke-Hidden "ffprobe" "-v error -select_streams v:0 -show_entries stream=height,codec_name -of csv=p=0 `"$Path`"").Trim()
    if ($v) {
        $parts = $v.Split(',')
        return @{ Res = "$($parts[1])p"; Codec = $parts[0] }
    }
    $a = (Invoke-Hidden "ffprobe" "-v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 `"$Path`"").Trim()
    return @{ Res = "Solo audio"; Codec = $a }
}

# Convertir audio con ffmpeg mostrando barra pulsante
function Convert-Audio {
    param($InputFile, $Format)

    $output = [System.IO.Path]::ChangeExtension($InputFile, $Format)

    if ($Format -eq "mp3") {
        $ffArgs = "-y -i `"$InputFile`" -vn -codec:a libmp3lame -qscale:a 2 `"$output`""
    } else {
        $ffArgs = "-y -i `"$InputFile`" -vn -codec:a libopus -b:a 128k `"$output`""
    }

    # Lanzar via cmd.exe para que ffmpeg no herede handles de PowerShell
    $proc = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c ffmpeg $ffArgs > nul 2>&1" `
        -NoNewWindow -PassThru

    Open-Progress -Title "Convirtiendo audio" -Text "Convirtiendo a $Format..." -Marquee

    while (-not $proc.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 200
    }

    Close-Progress
    return $output
}


# ═════════════════════════════════════════════════════════════════
# PASO 1 - OBTENER URL (portapapeles o diálogo de entrada)
# ═════════════════════════════════════════════════════════════════

$URL = $null
try {
    $clip = Get-Clipboard -Format Text -Raw 2>$null
    if ($clip -match '(https?://[^\s"''<>]+)') { $URL = $Matches[1].Trim() }
} catch {}

if (-not $URL) {
    $URL = Show-InputDialog -Title "Descargar video" -Prompt "Pega el enlace del video o playlist:"
    if (-not $URL) { exit 0 }
}


# ═════════════════════════════════════════════════════════════════
# PASO 2 - DETECTAR SI ES PLAYLIST
# ═════════════════════════════════════════════════════════════════

$IS_PLAYLIST = $URL -match '(list=|/playlist\?|/sets/)'

# URL mixta: tiene un video específico Y una playlist
if (($URL -match 'list=') -and ($URL -match '[?&]v=')) {
    $choice = Show-ListDialog -Title "Video o Playlist" `
        -Prompt "La URL contiene un video dentro de una playlist.`n¿Qué deseas descargar?" `
        -Items @("Solo este video", "Toda la playlist") `
        -OkLabel "Continuar"
    if (-not $choice) { exit 0 }

    if ($choice -eq "Toda la playlist") {
        $IS_PLAYLIST = $true
        if ($URL -match '(list=[A-Za-z0-9_-]+)') {
            $URL = "https://www.youtube.com/playlist?$($Matches[1])"
        }
    } else {
        $IS_PLAYLIST = $false
        $URL = $URL -replace '&list=[^&]*', '' -replace '\?list=[^&]*&', '?'
    }
}


# ═════════════════════════════════════════════════════════════════
# RAMA A - PLAYLIST
# ═════════════════════════════════════════════════════════════════

if ($IS_PLAYLIST) {

    # Obtener título y cantidad de videos
    $playlistTitle = (Invoke-Hidden "yt-dlp" `
        "--flat-playlist --print %(playlist_title)s --playlist-items 1 `"$URL`"" -TimeoutMs 60000 `
    ).Trim().Split("`n")[0]
    if (-not $playlistTitle) { $playlistTitle = "Playlist" }

    $playlistCount = ((Invoke-Hidden "yt-dlp" `
        "--flat-playlist --print %(playlist_index)s `"$URL`"" -TimeoutMs 120000 `
    ).Trim() -split "`n" | Where-Object { $_.Trim() }).Count

    $destName    = Get-SafeName $playlistTitle
    $PLAYLIST_DEST = Join-Path $DownloadDir $destName

    $confirm = Show-Question -Title "Descargar Playlist" `
        -Text "Playlist detectada:`n`n$playlistTitle`n`n$playlistCount videos`n`nSe guardará en:`n$PLAYLIST_DEST`n`n¿Continuar?"
    if (-not $confirm) { exit 0 }

    # ── Formatos disponibles (primer video de la playlist) ──
    $jsonRaw = Invoke-Hidden "yt-dlp" "-j --playlist-items 1 `"$URL`"" -TimeoutMs 60000
    try   { $jsonData = $jsonRaw | ConvertFrom-Json }
    catch { Show-Err "No se pudieron obtener los formatos disponibles."; exit 1 }

    $formats  = @(Get-VideoFormats $jsonData)
    $fmtItems = @($formats | ForEach-Object { $_.Desc }) + @("Solo audio (OPUS)")

    $SELECTED = Show-ListDialog -Title "Formato - Playlist" `
        -Prompt "Selecciona la resolución para toda la playlist:" `
        -Items $fmtItems -OkLabel "Descargar"
    if (-not $SELECTED) { exit 0 }

    # ── Selección de formato ──
    if ($SELECTED -eq "Solo audio (OPUS)") {
        $QUALITY = "AUDIO"; $FORMAT = "bestaudio"

        $AUDIO_FMT_RAW = Show-ListDialog -Title "Formato de audio" `
            -Prompt "Selecciona el formato final del audio:" `
            -Items @("mp3  -  Alta compatibilidad", "opus  -  Mejor calidad/tamaño") `
            -OkLabel "Continuar"
        if (-not $AUDIO_FMT_RAW) { exit 0 }
        $AUDIO_FORMAT = $AUDIO_FMT_RAW.Split("-")[0].Trim()
    } else {
        $QUALITY  = "VIDEO"
        $matchFmt = $formats | Where-Object { $_.Desc -eq $SELECTED } | Select-Object -First 1
        $FORMAT   = "$($matchFmt.ID)+bestaudio"
    }

    New-Item -ItemType Directory -Force -Path $PLAYLIST_DEST | Out-Null

    # ── Contar archivos existentes del mismo tipo ──
    $EXISTING_COUNT = 0
    foreach ($ef in (Get-ChildItem -Path $PLAYLIST_DEST -File -ErrorAction SilentlyContinue)) {
        $hasV = (Invoke-Hidden "ffprobe" `
            "-v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 `"$($ef.FullName)`"" `
        ).Trim()
        if ($QUALITY -eq "VIDEO" -and $hasV -match "video") {
            $EXISTING_COUNT++
        }
        if ($QUALITY -eq "AUDIO" -and $hasV -notmatch "video") {
            # Verificar que la extension coincida con el formato de audio pedido
            # para no confundir mp3 existente con opus pedido o viceversa
            if ($ef.Extension -eq ".$AUDIO_FORMAT") {
                $EXISTING_COUNT++
            }
        }
    }

    $OVERWRITE = ""
    if ($EXISTING_COUNT -gt 0) {
        $ow = Show-Question -Title "Carpeta existente" `
            -Text "La carpeta ya contiene $EXISTING_COUNT archivo(s) del mismo tipo:`n`n$PLAYLIST_DEST`n`n¿Deseas reemplazarlos?"
        if (-not $ow) { Show-Info "Descarga cancelada."; exit 0 }
        $OVERWRITE = "--force-overwrites"
    }

    # ── Construir argumentos de yt-dlp ──
    if ($QUALITY -eq "AUDIO") {
        $postArgs = "--extract-audio --audio-format $AUDIO_FORMAT --audio-quality 0"
    } else {
        $postArgs = "--merge-output-format mkv"
    }

    # Importante: las comillas internas usan `" para que PowerShell las incluya literalmente
    $outTpl  = "`"$PLAYLIST_DEST\%(playlist_index)s - %(title)s.%(ext)s`""
    $progTpl = "`"%(progress._percent_str)s|%(info.playlist_index)s|%(info.n_entries)s|%(info.title)s`""
    $ytArgs  = "-f `"$FORMAT`" -o $outTpl --restrict-filenames --concurrent-fragments 4 " +
               "--retries 10 --fragment-retries 10 " +
               "--postprocessor-args `"ffmpeg:-loglevel quiet`" " +
               "--newline --progress-template $progTpl " +
               "$postArgs $OVERWRITE `"$URL`""

    # ── Descarga con progreso ──
    $result = Invoke-YtDlpWithProgress -Arguments $ytArgs `
        -Title "Descargando: $playlistTitle" -InitText "Iniciando..." -IsPlaylist

    if ($result.Cancelled) {
        Start-Sleep -Milliseconds 800
        # Borrar temporales obvios y también archivos de video/audio incompletos
        # usando ffprobe para verificar — igual que en la rama de video individual
        Get-ChildItem -Path $PLAYLIST_DEST -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                $ext = $_.Extension.ToLower()
                if ($ext -match '\.(part|ytdl|temp)$' -or $_.Name -match '\.(part|ytdl|temp)(-\d+)?$') {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                    return
                }
                # Verificar si el archivo es válido con ffprobe
                $probe = (Invoke-Hidden "ffprobe" `
                    "-v error -show_entries format=duration -of csv=p=0 `"$($_.FullName)`"" `
                ).Trim()
                $duration = [double]0
                $parsed = [double]::TryParse(
                    $probe,
                    [System.Globalization.NumberStyles]::Any,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [ref]$duration)
                if (-not $parsed -or $duration -lt 1) {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        Show-Info "Descarga cancelada."
        exit 0
    }

    # ── Resumen final ──
    $sample    = Get-ChildItem -Path $PLAYLIST_DEST -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $fileCount = @(Get-ChildItem -Path $PLAYLIST_DEST -File -ErrorAction SilentlyContinue).Count
    $minfo     = if ($sample) { Get-MediaInfo $sample.FullName } else { @{ Res = "?"; Codec = "?" } }

    Show-Info ("Descarga completada:`n`n$playlistTitle`n`n" +
               "Carpeta:`n$PLAYLIST_DEST`n`n" +
               "$fileCount archivos descargados`n`n" +
               "Resolución: $($minfo.Res)`nCódec: $($minfo.Codec)") "Playlist descargada"
    exit 0
}


# ═════════════════════════════════════════════════════════════════
# RAMA B - VIDEO INDIVIDUAL
# ═════════════════════════════════════════════════════════════════

$TITLE = (Invoke-Hidden "yt-dlp" "--get-title `"$URL`"" -TimeoutMs 60000).Trim()
if (-not $TITLE) { Show-Err "No se pudo obtener información del video.`n`nVerifica que la URL sea correcta y que no sea un stream en vivo."; exit 1 }

$jsonRaw = Invoke-Hidden "yt-dlp" "-j `"$URL`"" -TimeoutMs 60000
try   { $jsonData = $jsonRaw | ConvertFrom-Json }
catch { Show-Err "No se pudieron obtener los formatos disponibles."; exit 1 }

$formats  = @(Get-VideoFormats $jsonData)
$fmtItems = @($formats | ForEach-Object { $_.Desc }) + @("Solo audio (OPUS)")

$SELECTED = Show-ListDialog -Title "Seleccionar formato" `
    -Prompt "Video: $TITLE`n`nSelecciona la resolución o solo audio:" `
    -Items $fmtItems -OkLabel "Descargar"
if (-not $SELECTED) { exit 0 }

# ── Formato elegido ──
if ($SELECTED -eq "Solo audio (OPUS)") {
    $QUALITY = "AUDIO"; $FORMAT = "bestaudio"

    $AUDIO_FMT_RAW = Show-ListDialog -Title "Formato de audio" `
        -Prompt "Selecciona el formato final del audio:" `
        -Items @("mp3  -  Alta compatibilidad", "opus  -  Mejor calidad/tamaño") `
        -OkLabel "Continuar"
    if (-not $AUDIO_FMT_RAW) { exit 0 }
    $AUDIO_FORMAT = $AUDIO_FMT_RAW.Split("-")[0].Trim()
} else {
    $QUALITY  = "VIDEO"
    $matchFmt = $formats | Where-Object { $_.Desc -eq $SELECTED } | Select-Object -First 1
    $FORMAT   = "$($matchFmt.ID)+bestaudio"
}

# ── Detectar archivo ya existente ──
$expectedFile = (Invoke-Hidden "yt-dlp" `
    "-f `"$FORMAT`" -o `"$DownloadDir\%(title)s.%(ext)s`" --restrict-filenames --merge-output-format mkv --get-filename `"$URL`"" `
).Trim()

$FOUND_FILE     = $null
$CLEAN_BASENAME = $null

if ($expectedFile) {
    $CLEAN_BASENAME = [System.IO.Path]::GetFileNameWithoutExtension($expectedFile)

    if ($QUALITY -eq "AUDIO") {
        $cand = Join-Path $DownloadDir "$CLEAN_BASENAME.$AUDIO_FORMAT"
        if (Test-Path $cand) {
            $hasV = (Invoke-Hidden "ffprobe" `
                "-v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 `"$cand`"" `
            ).Trim()
            if ($hasV -notmatch "video") { $FOUND_FILE = $cand }
        }
    } else {
        if (Test-Path $expectedFile) {
            $hasV = (Invoke-Hidden "ffprobe" `
                "-v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 `"$expectedFile`"" `
            ).Trim()
            if ($hasV -match "video") { $FOUND_FILE = $expectedFile }
        }
    }
}

$OVERWRITE = ""
if ($FOUND_FILE) {
    $ow = Show-Question -Title "Archivo existente" `
        -Text "Ya existe un archivo con este nombre:`n`n$(Split-Path $FOUND_FILE -Leaf)`n`n¿Deseas reemplazarlo?"
    if (-not $ow) { Show-Info "Descarga cancelada."; exit 0 }
    $OVERWRITE = "--force-overwrites"
}

# ── Descargar ──
$outTpl  = "`"$DownloadDir\%(title)s.%(ext)s`""
$progTpl = "`"%(progress._percent_str)s`""
$ytArgs  = "-f `"$FORMAT`" -o $outTpl --restrict-filenames --concurrent-fragments 4 " +
           "--retries 10 --fragment-retries 10 --merge-output-format mkv " +
           "--postprocessor-args `"ffmpeg:-loglevel quiet`" " +
           "--newline --progress-template $progTpl $OVERWRITE `"$URL`""

$result = Invoke-YtDlpWithProgress -Arguments $ytArgs -Title $TITLE -InitText "Descargando..."

if ($result.Cancelled) {
    Start-Sleep -Milliseconds 800

    # Borrar SOLO los archivos relacionados con esta descarga usando el nombre base conocido.
    # Nunca se toca ningún otro archivo de la carpeta.
    if ($CLEAN_BASENAME) {
        Get-ChildItem -Path $DownloadDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -like "$CLEAN_BASENAME*" } |
            ForEach-Object {
                $ext = $_.Extension.ToLower()
                # Borrar siempre los temporales
                if ($ext -match '\.(part|ytdl|temp)$' -or $_.Name -match '\.(part|ytdl|temp)(-\d+)?$') {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                    return
                }
                # Para archivos "completos" verificar con ffprobe si son válidos
                # Un archivo incompleto no tendrá streams válidos
                $probe = (Invoke-Hidden "ffprobe" `
                    "-v error -show_entries format=duration -of csv=p=0 `"$($_.FullName)`"" `
                ).Trim()
                $duration = [double]0
                $parsed = [double]::TryParse(
                    $probe,
                    [System.Globalization.NumberStyles]::Any,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [ref]$duration)
                if (-not $parsed -or $duration -lt 1) {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
    }

    Show-Info "Descarga cancelada."
    exit 0
}

# ── Encontrar el archivo final usando el nombre base conocido ──
$NEWFILE = $null
if ($CLEAN_BASENAME) {
    $found = Get-ChildItem -Path $DownloadDir -File -ErrorAction SilentlyContinue |
             Where-Object {
                 $_.BaseName -eq $CLEAN_BASENAME -and
                 $_.Extension -notmatch '\.(part|ytdl|temp)$'
             } | Select-Object -First 1
    if ($found) { $NEWFILE = $found.Name }
}

if (-not $NEWFILE -and $FOUND_FILE) { $NEWFILE = Split-Path $FOUND_FILE -Leaf }
if (-not $NEWFILE) { Show-Err "No se encontró el archivo final."; exit 1 }

$FULLPATH = Join-Path $DownloadDir $NEWFILE

# ── Conversión de audio si corresponde ──
if ($QUALITY -eq "AUDIO") {
    $converted = Convert-Audio -InputFile $FULLPATH -Format $AUDIO_FORMAT
    if (Test-Path $converted) {
        Remove-Item -Path $FULLPATH -Force -ErrorAction SilentlyContinue
        $FULLPATH = $converted
    }
}

# ── Información final ──
$minfo = Get-MediaInfo $FULLPATH
Show-Info ("Descarga completada:`n`n$TITLE`n`n" +
           "Archivo:`n$FULLPATH`n`n" +
           "Resolución: $($minfo.Res)`nCódec: $($minfo.Codec)") "Descarga completada"
