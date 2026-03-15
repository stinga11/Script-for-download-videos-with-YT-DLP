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
# Parseo de formatos
# ---------------------------------------------------------

VIDEO_OPTIONS=$(echo "$FORMAT_LIST" | awk '
/^[0-9]/ {
    id=$1
    res=""
    fps=0
    codec=""
    hdr=""
    tbr=0
    codec_rank=0

    for(i=1;i<=NF;i++){

        if($i ~ /^[0-9]+x[0-9]+$/){
            split($i,r,"x")
            res=r[2]"p"
        }

        if($i ~ /^[0-9]+p[0-9]+$/){
            match($i,/^([0-9]+)p([0-9]+)$/,m)
            res=m[1]"p"
            fps=m[2]
        }
        else if($i ~ /^[0-9]+p$/){
            res=$i
        }

        if($i ~ /^[0-9]+fps$/){
            fps=substr($i,1,length($i)-3)
        }

        if($i ~ /(vp9|avc|h264|av01|av1|hev1|hvc1)/){
            codec=$i
            split(codec,c,".")
            codec=c[1]

            if($i ~ /vp9\.2/ || $i ~ /av01.*M/ || $i ~ /hvc1/ || $i ~ /hev1/)
                hdr="HDR"
        }

        if($i ~ /^[0-9]+k$/){
            tbr=substr($i,1,length($i)-1)
        }
    }

    # prioridad de codec: av1 > vp9 > avc/h264
    if(codec=="av01" || codec=="av1")
        codec_rank=3
    else if(codec=="vp9")
        codec_rank=2
    else if(codec=="avc" || codec=="h264")
        codec_rank=1

    if(res!="" && codec!=""){

        split(res,rr,"p")
        height=rr[1]
        hdrflag=(hdr=="HDR")?1:0

        if(fps>0)
            desc=res" "fps"fps "codec
        else
            desc=res" "codec

        if(tbr>0)
            desc=desc" ("tbr"k)"

        if(hdr!="")
            desc=desc" (HDR)"

        print height, hdrflag, fps, codec_rank, tbr, id "|" desc
    }

}' | sort -k1,1nr -k2,2nr -k3,3nr -k4,4nr -k5,5nr | cut -d" " -f6-)

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
# Nombre base y detección de archivo existente
# ---------------------------------------------------------

BASENAME_RESTRICT=$(echo "$TITLE" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')

if [ "$QUALITY" = "AUDIO" ]; then
    EXTS=("webm" "m4a" "opus" "mp3")
else
    EXTS=("mkv" "mp4" "webm" "m4a" "opus")
fi

FOUND_FILE=""
for BASE in "$TITLE" "$BASENAME_RESTRICT"; do
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

BEFORE=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -printf "%f\n" | sort)

# ---------------------------------------------------------
# Descarga
# ---------------------------------------------------------

# Usamos un archivo temporal en lugar de un FIFO para evitar
# bloqueos: un FIFO congela al abrir si no hay lector/escritor
# simultáneo. Con un archivo + tail -f no hay ese problema.
TMPLOG=$(mktemp /tmp/ytdownloader-XXXX.log)

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
    "$URL" >> "$TMPLOG" 2>&1 &

YTPID=$!

(
tail -f --pid=$YTPID "$TMPLOG" | while read -r LINE; do
    CLEAN=$(echo "$LINE" | tr -d '[:space:]')
    if [[ "$CLEAN" =~ ^([0-9]+(\.[0-9]+)?)%$ ]]; then
        RAW="${BASH_REMATCH[1]}"
        PERCENT=$(printf "%.0f" "$RAW")
        [ "$PERCENT" -ge 100 ] && PERCENT=99
        echo "$PERCENT"
        echo "# Descargando: $PERCENT %"
    fi
done
) | zenity --progress \
    --title="$TITLE" \
    --text="Descargando..." \
    --percentage=0 \
    --cancel-label="Cancelar" \
    --auto-close

ZENITY_EXIT=$?

# ---------------------------------------------------------
# Cancelación: borrar archivos temporales del basename
# ---------------------------------------------------------

if [ $ZENITY_EXIT -ne 0 ]; then
    kill -TERM $YTPID 2>/dev/null
    wait $YTPID 2>/dev/null
    rm -f "$TMPLOG"

    # Borrar el archivo que yt-dlp alcanzó a crear antes de ser cancelado
    AFTER_CANCEL=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -printf "%f\n" | sort)
    NEWFILE_CANCEL=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER_CANCEL") | head -n1)
    if [ -n "$NEWFILE_CANCEL" ]; then
        rm -f "$DOWNLOAD_DIR/$NEWFILE_CANCEL"
    fi

    zenity --info --text="Descarga cancelada."
    exit 0
fi

wait $YTPID
rm -f "$TMPLOG"

# ---------------------------------------------------------
# Snapshot después
# ---------------------------------------------------------

AFTER=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -printf "%f\n" | sort)

# ---------------------------------------------------------
# Detectar archivo final
# ---------------------------------------------------------

# comm -13 con nombres solos detecta archivos nuevos siempre.
# Si se sobreescribió (mismo nombre en BEFORE y AFTER), comm no
# lo detecta → fallback a FOUND_FILE, igual que en kdialog.
NEWFILE=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | head -n1)

if [ -z "$NEWFILE" ] && [ -n "$FOUND_FILE" ]; then
    NEWFILE=$(basename "$FOUND_FILE")
fi

if [ -z "$NEWFILE" ]; then
    zenity --error --text="No se encontró el archivo final."
    exit 1
fi

FULLPATH="$DOWNLOAD_DIR/$NEWFILE"

# ---------------------------------------------------------
# Conversión final si es audio
# ---------------------------------------------------------

if [ "$QUALITY" = "AUDIO" ]; then
    # Mostrar dialog mientras ffmpeg convierte en background
    (
        NEWFILE2=$(convert_audio "$FULLPATH" "$AUDIO_FORMAT")
        echo "$NEWFILE2" > /tmp/ytdownloader-converted.tmp
    ) &
    FFMPEG_PID=$!

    (
        while kill -0 $FFMPEG_PID 2>/dev/null; do
            echo "# Convirtiendo a $AUDIO_FORMAT..."
            sleep 0.5
        done
    ) | zenity --progress \
        --title="$TITLE" \
        --text="Convirtiendo a $AUDIO_FORMAT..." \
        --percentage=0 \
        --pulsate \
        --auto-close \
        --no-cancel

    wait $FFMPEG_PID
    NEWFILE2=$(cat /tmp/ytdownloader-converted.tmp 2>/dev/null)
    rm -f /tmp/ytdownloader-converted.tmp

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
        -of csv=p=0 "$FULLPATH" 2>/dev/null)
else
    CODEC=$(echo "$INFO" | cut -d',' -f1)
    HEIGHT=$(echo "$INFO" | cut -d',' -f2)
    RES="${HEIGHT}p"
fi

zenity --info \
    --title="Descarga completada" \
    --text="Descarga completada:\n\n$TITLE\n\nArchivo:\n$FULLPATH\n\nResolución: $RES\nCódec: $CODEC"
