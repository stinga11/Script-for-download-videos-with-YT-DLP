#!/bin/bash

# Detectar qdbus correcto
if command -v qdbus6 >/dev/null; then
    QDBUS=qdbus6
elif command -v qdbus-qt6 >/dev/null; then
    QDBUS=qdbus-qt6
elif command -v qdbus5 >/dev/null; then
    QDBUS=qdbus5
elif command -v qdbus >/dev/null; then
    QDBUS=qdbus
else
    kdialog --error "No se encontró qdbus. Instala qt6-tools o qt5-tools."
    exit 1
fi

DOWNLOAD_DIR="$HOME/Videos"
mkdir -p "$DOWNLOAD_DIR"

# ---------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------

is_audio_only() {
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_type \
        -of csv=p=0 "$1" 2>/dev/null | grep -q "video" && return 1
    return 0
}

convert_audio() {
    local INPUT="$1"
    local TARGET="$2"
    local OUTPUT="${INPUT%.*}.$TARGET"

    if [ "$TARGET" = "mp3" ]; then
        ffmpeg -y -i "$INPUT" -vn -codec:a libmp3lame -qscale:a 2 "$OUTPUT"
    else
        ffmpeg -y -i "$INPUT" -vn -codec:a libopus -b:a 128k "$OUTPUT"
    fi

    echo "$OUTPUT"
}

# ---------------------------------------------------------
# Obtener URL
# ---------------------------------------------------------

if command -v wl-paste >/dev/null; then
    CLIP=$(wl-paste --no-newline --type text 2>/dev/null)
    URL=$(echo "$CLIP" | grep -Eo 'https?://[^"'"'"'<> ]+' | head -n1)
fi

if [ -z "$URL" ] && command -v xclip >/dev/null; then
    CLIP=$(xclip -o -selection clipboard 2>/dev/null)
    URL=$(echo "$CLIP" | grep -Eo 'https?://[^"'"'"'<> ]+' | head -n1)
fi

if [ -z "$URL" ]; then
    URL=$(kdialog --title "Descargar video" --inputbox "Pega el link del video:")
fi

[ -z "$URL" ] && exit 1

# ---------------------------------------------------------
# Metadata
# ---------------------------------------------------------

TITLE=$(yt-dlp --get-title "$URL" 2>/dev/null)
[ -z "$TITLE" ] && kdialog --error "No se pudo obtener información del video." && exit 1

FORMAT_LIST=$(yt-dlp -F "$URL" 2>/dev/null)
[ -z "$FORMAT_LIST" ] && kdialog --error "No se pudieron obtener los formatos disponibles." && exit 1

# ---------------------------------------------------------
# Parseo formatos
# ---------------------------------------------------------

VIDEO_OPTIONS=$(echo "$FORMAT_LIST" | awk '
/^[0-9]/ {
    id=$1
    res=""
    fps=0
    codec=""
    hdr=""

    for(i=1;i<=NF;i++){
        if($i ~ /^[0-9]+x[0-9]+$/){
            split($i, r, "x")
            res = r[2] "p"
        }
        if($i ~ /^[0-9]+p/){
            res = $i
        }
        if ($i ~ /^[0-9]+fps$/) {
            fps = substr($i, 1, length($i)-3)
        }
        else if ($i ~ /^[0-9]+$/ && $i >= 10 && $i <= 240) {
            fps = $i
        }
        if($i ~ /(vp9|avc|h264|av01|av1|hev1|hvc1)/){
            codec=$i
            split(codec, c, ".")
            codec=c[1]
            if($i ~ /vp9\.2/ || $i ~ /av01.*M/ || $i ~ /hvc1/ || $i ~ /hev1/){
                hdr="HDR"
            }
        }
    }

    if(res != "" && codec != ""){
        split(res, rr, "p")
        height = rr[1]
        hdrflag = (hdr == "HDR") ? 1 : 0
        if (fps > 0) {
            desc = res " " fps "fps " codec
        } else {
            desc = res " " codec
        }
        if(hdr != "") desc = desc " (HDR)"
        print height, hdrflag, fps, id "|" desc
    }
}' | sort -k1,1nr -k2,2nr -k3,3nr | cut -d' ' -f4-)

declare -A VIDEO_MAP
MENU=()
MAP=()
i=1

while IFS="|" read -r ID DESC; do
    VIDEO_MAP["$DESC"]="$ID"
    MENU+=("$i" "$DESC")
    MAP[$i]="$DESC"
    ((i++))
done <<< "$VIDEO_OPTIONS"

MENU+=("$i" "Solo audio (OPUS)")
MAP[$i]="Solo audio (OPUS)"

CHOICE=$(kdialog --title "Seleccionar formato" \
    --menu "Selecciona la resolución del video:" \
    "${MENU[@]}")

[ -z "$CHOICE" ] && exit 0

SELECTED="${MAP[$CHOICE]}"

# ---------------------------------------------------------
# Determinar formato
# ---------------------------------------------------------

if [ "$SELECTED" = "Solo audio (OPUS)" ]; then
    QUALITY="AUDIO"
    FORMAT="bestaudio"
else
    QUALITY="VIDEO"
    VIDEO_ID="${VIDEO_MAP[$SELECTED]}"
    FORMAT="$VIDEO_ID+bestaudio"
fi

# ---------------------------------------------------------
# Formato final audio
# ---------------------------------------------------------

if [ "$QUALITY" = "AUDIO" ]; then
    AUDIO_MENU=(
        1 "mp3 - Alta compatibilidad"
        2 "opus - Mejor calidad/tamaño"
    )

    AUDIO_CHOICE=$(kdialog --title "Formato de audio" \
        --menu "Selecciona el formato final:" \
        "${AUDIO_MENU[@]}")

    [ -z "$AUDIO_CHOICE" ] && exit 0

    case "$AUDIO_CHOICE" in
        1) AUDIO_FORMAT="mp3" ;;
        2) AUDIO_FORMAT="opus" ;;
    esac
fi

# ---------------------------------------------------------
# Detectar archivo existente
# ---------------------------------------------------------

BASENAME_RESTRICT=$(echo "$TITLE" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')

FOUND_FILE=""

EXTS=("mkv" "mp4" "webm" "m4a" "opus" "mp3")

for EXT in "${EXTS[@]}"; do
    FILE="$DOWNLOAD_DIR/$BASENAME_RESTRICT.$EXT"

    if [ -f "$FILE" ]; then

        if [ "$QUALITY" = "AUDIO" ]; then
            ACTUAL_CODEC=$(ffprobe -v error \
                -select_streams a:0 \
                -show_entries stream=codec_name \
                -of default=nw=1:nk=1 "$FILE" 2>/dev/null)

            HAS_VIDEO=$(ffprobe -v error -select_streams v:0 \
                -show_entries stream=codec_type \
                -of csv=p=0 "$FILE" 2>/dev/null | grep -q video && echo yes)

            if [ "$HAS_VIDEO" != "yes" ] && \
               [ "$ACTUAL_CODEC" = "$AUDIO_FORMAT" ]; then
                FOUND_FILE="$FILE"
                break
            fi

        else
            if ffprobe -v error -select_streams v:0 \
                -show_entries stream=codec_type \
                -of csv=p=0 "$FILE" 2>/dev/null | grep -q video; then
                FOUND_FILE="$FILE"
                break
            fi
        fi
    fi
done

if [ -n "$FOUND_FILE" ]; then
    kdialog --yesno "Ya existe:

$(basename "$FOUND_FILE")

¿Reemplazar?"

    if [ $? -ne 0 ]; then
        kdialog --msgbox "Descarga cancelada."
        exit 0
    fi

    OVERWRITE_FLAG="--force-overwrites"
fi

# ---------------------------------------------------------
# Snapshot antes (seguro)
# ---------------------------------------------------------

BEFORE=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -printf "%f\n")

# ---------------------------------------------------------
# progreso KDE
# ---------------------------------------------------------

PIPE=$(mktemp -u /tmp/ytdownloader.XXXX)
mkfifo "$PIPE"

yt-dlp \
    -f "$FORMAT" \
    -o "$DOWNLOAD_DIR/%(title)s.%(ext)s" \
    --restrict-filenames \
    --merge-output-format mkv \
    --newline \
    --progress-template "%(progress._percent_str)s" \
    $OVERWRITE_FLAG \
    "$URL" > "$PIPE" 2>&1 &

YTPID=$!

PROGRESS=$(kdialog --title "Descargando" --progressbar "$TITLE" 100)
$QDBUS $PROGRESS showCancelButton true

CANCELLED=false

(
while read -r LINE; do
    CLEAN=$(echo "$LINE" | tr -d '[:space:]')

    # Si el diálogo ya no existe, salimos del lector
    if ! $QDBUS $PROGRESS >/dev/null 2>&1; then
        exit 0
    fi

    if [[ "$CLEAN" =~ ^([0-9]+(\.[0-9]+)?)%$ ]]; then
        RAW="${BASH_REMATCH[1]}"
        PERCENT=$(printf "%.0f" "$RAW")
        $QDBUS $PROGRESS Set "" value $PERCENT
    fi
done < "$PIPE"
) &
READER_PID=$!

# Bucle principal
while kill -0 $YTPID 2>/dev/null; do
    # Si el diálogo ya no existe, lo tomamos como cancelación
    if ! $QDBUS $PROGRESS >/dev/null 2>&1; then
        CANCELLED=true
        kill -TERM $YTPID 2>/dev/null
        kill -TERM $READER_PID 2>/dev/null
        rm -f "$PIPE"
        break
    fi

    CANCELED=$($QDBUS $PROGRESS wasCancelled 2>/dev/null)

    if [ "$CANCELED" = "true" ]; then
        CANCELLED=true
        kill -TERM $YTPID 2>/dev/null
        kill -TERM $READER_PID 2>/dev/null
        rm -f "$PIPE"
        break
    fi

    sleep 0.3
done

# Cerrar diálogo solo si sigue existiendo
if $QDBUS $PROGRESS >/dev/null 2>&1; then
    $QDBUS $PROGRESS close
fi

wait $YTPID 2>/dev/null
rm -f "$PIPE"

if [ "$CANCELLED" = true ]; then
    # Detectar archivo nuevo y borrarlo (como hacíamos con zenity)
    AFTER=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -printf "%f\n")
    NEWFILE=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | head -n1)

    if [ -n "$NEWFILE" ]; then
        rm -f "$DOWNLOAD_DIR/$NEWFILE"
    fi

    kdialog --sorry "Descarga cancelada."
    exit 0
fi

# ---------------------------------------------------------
# detectar archivo nuevo (seguro)
# ---------------------------------------------------------

AFTER=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -printf "%f\n")

NEWFILE=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | head -n1)

if [ -z "$NEWFILE" ] && [ -n "$FOUND_FILE" ]; then
    NEWFILE=$(basename "$FOUND_FILE")
fi

[ -z "$NEWFILE" ] && kdialog --error "No se encontró el archivo final." && exit 1

FULLPATH="$DOWNLOAD_DIR/$NEWFILE"

# ---------------------------------------------------------
# conversión audio
# ---------------------------------------------------------

if [ "$QUALITY" = "AUDIO" ]; then
    NEWFILE2=$(convert_audio "$FULLPATH" "$AUDIO_FORMAT")

    if [ -f "$NEWFILE2" ]; then
        rm "$FULLPATH"
        FULLPATH="$NEWFILE2"
    fi
fi

# ---------------------------------------------------------
# info final
# ---------------------------------------------------------

INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=height,codec_name \
    -of csv=p=0 "$FULLPATH" 2>/dev/null)

if [ -z "$INFO" ]; then
    RES="Solo audio"
    CODEC=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name -of csv=p=0 "$FULLPATH")
else
    CODEC=$(echo "$INFO" | cut -d',' -f1)
    HEIGHT=$(echo "$INFO" | cut -d',' -f2)
    RES="${HEIGHT}p"
fi

kdialog --msgbox "Descarga completada

$TITLE

Archivo:
$FULLPATH

Resolución: $RES
Códec: $CODEC"
