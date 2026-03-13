#!/bin/bash

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
    URL=$(zenity --entry --title="Descargar video" --text="Pega el link del video:")
fi

[ -z "$URL" ] && exit 1

# ---------------------------------------------------------
# Metadata
# ---------------------------------------------------------

TITLE=$(yt-dlp --get-title "$URL" 2>/dev/null)
[ -z "$TITLE" ] && zenity --error --text="No se pudo obtener información del video." && exit 1

FORMAT_LIST=$(yt-dlp -F "$URL" 2>/dev/null)
[ -z "$FORMAT_LIST" ] && zenity --error --text="No se pudieron obtener los formatos disponibles." && exit 1

# ---------------------------------------------------------
# Parseo PRO de formatos
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
ZENITY_LIST=()

while IFS="|" read -r ID DESC; do
    VIDEO_MAP["$DESC"]="$ID"
    ZENITY_LIST+=("$DESC")
done <<< "$VIDEO_OPTIONS"

ZENITY_LIST+=("Solo audio (OPUS)")

SELECTED=$(zenity --list \
    --title="Seleccionar formato" \
    --text="Selecciona la resolución del video o solo audio:" \
    --column="Formato" \
    "${ZENITY_LIST[@]}")

[ $? -ne 0 ] && exit 0
[ -z "$SELECTED" ] && exit 0

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
# Si es audio, elegir formato final
# ---------------------------------------------------------

if [ "$QUALITY" = "AUDIO" ]; then
    AUDIO_FORMAT=$(zenity --list \
        --title="Formato de audio" \
        --text="Selecciona el formato final del audio:" \
        --column="Formato" --column="Descripción" \
        "mp3" "Alta compatibilidad" \
        "opus" "Mejor calidad/tamaño")

    [ $? -ne 0 ] && exit 0
    [ -z "$AUDIO_FORMAT" ] && exit 0
fi

# ---------------------------------------------------------
# Nombre base y detección de archivo existente (como el original)
# ---------------------------------------------------------

# Usamos el título para construir el basename "restringido"
BASENAME_ORIG="$TITLE"
BASENAME_RESTRICT=$(echo "$BASENAME_ORIG" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')

if [ "$QUALITY" = "AUDIO" ]; then
    EXTS=("webm" "m4a" "opus" "mp3")
else
    EXTS=("mkv" "mp4" "webm" "m4a" "opus")
fi

FOUND_FILE=""
for BASE in "$BASENAME_ORIG" "$BASENAME_RESTRICT"; do
    for EXT in "${EXTS[@]}"; do
        CANDIDATE="$DOWNLOAD_DIR/${BASE}.$EXT"
        if [ -f "$CANDIDATE" ]; then
            if [ "$QUALITY" = "AUDIO" ]; then
                is_audio_only "$CANDIDATE" && FOUND_FILE="$CANDIDATE" && break 2
            else
                ! is_audio_only "$CANDIDATE" && FOUND_FILE="$CANDIDATE" && break 2
            fi
        fi
    done
done

OVERWRITE_FLAG=""
if [ -n "$FOUND_FILE" ]; then
    zenity --question --title="Archivo existente" \
        --text="Ya existe un archivo con este nombre:\n\n$(basename "$FOUND_FILE")\n\n¿Deseas reemplazarlo?"

    if [ $? -ne 0 ]; then
        zenity --info --text="Descarga cancelada."
        exit 0
    fi

    OVERWRITE_FLAG="--force-overwrites"
fi

# ---------------------------------------------------------
# Snapshot de archivos antes
# ---------------------------------------------------------

BEFORE=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -printf "%f %s\n" | sort)

# ---------------------------------------------------------
# Descarga PRO
# ---------------------------------------------------------

PIPE=$(mktemp -u /tmp/ytdownloader.XXXX)
mkfifo "$PIPE"

yt-dlp \
    -f "$FORMAT" \
    -o "$DOWNLOAD_DIR/%(title)s.%(ext)s" \
    --restrict-filenames \
    --concurrent-fragments 8 \
    --retries 10 \
    --fragment-retries 10 \
    --merge-output-format mkv \
    --newline \
    --progress-template "%(progress._percent_str)s" \
    $OVERWRITE_FLAG \
    "$URL" > "$PIPE" 2>&1 &

YTPID=$!

(
while read -r LINE; do
    CLEAN=$(echo "$LINE" | tr -d '[:space:]')
    if [[ "$CLEAN" =~ ^([0-9]+(\.[0-9]+)?)%$ ]]; then
        RAW="${BASH_REMATCH[1]}"
        PERCENT=$(printf "%.0f" "$RAW")
        [ "$PERCENT" -ge 100 ] && PERCENT=99
        echo "$PERCENT"
        echo "# Descargando: $PERCENT %"
    fi
done < "$PIPE"
) | zenity --progress \
    --title="Descargando" \
    --text="Descargando:\n\n$TITLE" \
    --percentage=0 \
    --cancel-label="Cancelar" \
    --auto-close

# ---------------------------------------------------------
# Cancelación: borrar archivos relacionados al basename (como el original)
# ---------------------------------------------------------

if [ $? -ne 0 ]; then
    kill -TERM $YTPID 2>/dev/null
    wait $YTPID 2>/dev/null
    rm -f "$PIPE"

    shopt -s nullglob
    for f in "$DOWNLOAD_DIR"/"${BASENAME_RESTRICT}"*; do
        case "$f" in
            *.part|*.part-*|*.ytdl|*.temp)
                rm -f "$f"
                ;;
        esac
    done
    shopt -u nullglob

    zenity --info --text="Descarga cancelada."
    exit 0
fi

wait $YTPID
rm -f "$PIPE"

# ---------------------------------------------------------
# Snapshot después
# ---------------------------------------------------------

AFTER=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -printf "%f %s\n" | sort)

# ---------------------------------------------------------
# Detectar archivo final
# ---------------------------------------------------------

NEWFILE=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | awk '{print $1}' | head -n1)

if [ -z "$NEWFILE" ]; then
    zenity --error --text="No se encontró el archivo final."
    exit 1
fi

FULLPATH="$DOWNLOAD_DIR/$NEWFILE"

# ---------------------------------------------------------
# Conversión final si es audio
# ---------------------------------------------------------

if [ "$QUALITY" = "AUDIO" ]; then
    NEWFILE2=$(convert_audio "$FULLPATH" "$AUDIO_FORMAT")
    if [ -f "$NEWFILE2" ]; then
        rm "$FULLPATH"
        FULLPATH="$NEWFILE2"
    fi
fi

# ---------------------------------------------------------
# Info final
# ---------------------------------------------------------

INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=height,codec_name \
    -of csv=p=0 "$FULLPATH" 2>/dev/null)

if [ -z "$INFO" ]; then
    RES="Solo audio"
    CODEC=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
        -of csv=p=0 "$FULLPATH")
else
    CODEC=$(echo "$INFO" | cut -d',' -f1)
    HEIGHT=$(echo "$INFO" | cut -d',' -f2)
    RES="${HEIGHT}p"
fi

zenity --info \
    --title="Descarga completada" \
    --text="Descarga completada:\n\n$TITLE\n\nArchivo:\n$FULLPATH\n\nResolución: $RES\nCódec: $CODEC"
