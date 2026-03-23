#!/bin/bash

DOWNLOAD_DIR="$HOME/Videos"
mkdir -p "$DOWNLOAD_DIR"

# ---------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------

convert_audio() {
    local INPUT="$1"
    local TARGET="$2"
    local OUTPUT="${INPUT%.*}.$TARGET"

    if [ "$TARGET" = "mp3" ]; then
        ffmpeg -y -threads auto -i "$INPUT" -vn -codec:a libmp3lame -qscale:a 2 "$OUTPUT"
    else
        ffmpeg -y -threads auto -i "$INPUT" -vn -codec:a libopus -b:a 128k "$OUTPUT"
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
    URL=$(yad --entry --title="Descargar video" --text="Pega el link del video:")
fi

[ -z "$URL" ] && exit 1

# ---------------------------------------------------------
# Metadata
# ---------------------------------------------------------

TITLE=$(yt-dlp --get-title "$URL" 2>/dev/null)
[ -z "$TITLE" ] && yad --error --text="No se pudo obtener información del video." && exit 1

FORMAT_LIST=$(yt-dlp -F "$URL" 2>/dev/null)
[ -z "$FORMAT_LIST" ] && yad --error --text="No se pudieron obtener los formatos disponibles." && exit 1

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

        # FPS como número suelto (columna FPS separada en formato NxN)
        if($i ~ /^[0-9]+$/ && $i+0 >= 1 && $i+0 <= 240 && res!="" && fps==0){
            fps=$i+0
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
YAD_LIST=()

while IFS="|" read -r ID DESC; do
    DESC_CLEAN=$(echo "$DESC" | tr '|' '/')
    YAD_LIST+=("$DESC_CLEAN")
    VIDEO_MAP["$DESC_CLEAN"]="$ID"
done <<< "$VIDEO_OPTIONS"

YAD_LIST+=("Solo audio (OPUS)")

SELECTED=$(yad --list \
    --title="Seleccionar formato" \
    --text="Selecciona la resolución del video o solo audio:" \
    --column="Formato" \
    --separator="|" \
    --width=350 --height=400 --center \
    --no-headers \
    "${YAD_LIST[@]}")

[ $? -ne 0 ] && exit 0
[ -z "$SELECTED" ] && exit 0

SELECTED=$(echo "$SELECTED" | cut -d'|' -f1 | sed 's/[[:space:]]*$//')

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
    AUDIO_FORMAT=$(yad --list \
        --title="Formato de audio" \
        --text="Selecciona el formato final del audio:" \
        --column="Formato" --column="Descripción" \
        "mp3" "Alta compatibilidad" \
        "opus" "Mejor calidad/tamaño")

    [ $? -ne 0 ] && exit 0
    [ -z "$AUDIO_FORMAT" ] && exit 0

    AUDIO_FORMAT=$(echo "$AUDIO_FORMAT" | cut -d'|' -f1)
fi

# ---------------------------------------------------------
# Nombre base y detección de archivo existente
# ---------------------------------------------------------

# Usamos --get-filename para obtener el nombre exacto que yt-dlp produciría,
# evitando discrepancias entre nuestra normalización y la de --restrict-filenames
EXPECTED_FILE=$(yt-dlp \
    -f "$FORMAT" \
    -o "$DOWNLOAD_DIR/%(title)s.%(ext)s" \
    --restrict-filenames \
    --merge-output-format mkv \
    --get-filename \
    "$URL" 2>/dev/null | head -n1)

FOUND_FILE=""
BASENAME_RESTRICT=""

if [ -n "$EXPECTED_FILE" ]; then
    BASENAME_RESTRICT=$(basename "${EXPECTED_FILE%.*}")

    if [ "$QUALITY" = "AUDIO" ]; then
        # Para audio buscamos el archivo convertido final (mp3/opus)
        AUDIO_CANDIDATE="$DOWNLOAD_DIR/$BASENAME_RESTRICT.$AUDIO_FORMAT"
        if [ -f "$AUDIO_CANDIDATE" ]; then
            HAS_VIDEO=$(ffprobe -v error \
                -select_streams v:0 \
                -show_entries stream=codec_type \
                -of csv=p=0 "$AUDIO_CANDIDATE" 2>/dev/null | grep -q video && echo yes)
            if [ "$HAS_VIDEO" != "yes" ]; then
                FOUND_FILE="$AUDIO_CANDIDATE"
            fi
        fi
    else
        # Para video el archivo esperado es exactamente el que yt-dlp produciría
        if [ -f "$EXPECTED_FILE" ]; then
            if ffprobe -v error \
                -select_streams v:0 \
                -show_entries stream=codec_type \
                -of csv=p=0 "$EXPECTED_FILE" 2>/dev/null | grep -q video; then
                FOUND_FILE="$EXPECTED_FILE"
            fi
        fi
    fi
fi

OVERWRITE_FLAG=""
if [ -n "$FOUND_FILE" ]; then
    yad --question --title="Archivo existente" \
        --text="Ya existe un archivo con este nombre:\n\n$(basename "$FOUND_FILE")\n\n¿Deseas reemplazarlo?"

    if [ $? -ne 0 ]; then
        yad --info --text="Descarga cancelada."
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
        echo "# Descargando: ${PERCENT}%"
    fi
done
) | yad --progress \
    --title="Descargando..." \
    --text="$TITLE" \
    --percentage=0 \
    --auto-close \
    --button=Cancelar:1 &

YAD_PID=$!
CANCELLED=false

# Bucle principal
while kill -0 $YTPID 2>/dev/null; do
    if ! kill -0 $YAD_PID 2>/dev/null; then
        CANCELLED=true
        kill -TERM $YTPID 2>/dev/null
        break
    fi
    sleep 0.3
done

# Race condition fix
DIALOG_CLOSED_BY_US=false

if [ "$CANCELLED" != true ] && kill -0 $YAD_PID 2>/dev/null; then
    kill $YAD_PID 2>/dev/null
    DIALOG_CLOSED_BY_US=true
fi

wait $YTPID 2>/dev/null
wait $YAD_PID 2>/dev/null

if [ "$CANCELLED" != true ] && [ "$DIALOG_CLOSED_BY_US" != true ]; then
    CANCELLED=true
fi

# ---------------------------------------------------------
# Cancelación: borrar archivo descargado parcialmente
# ---------------------------------------------------------

if [ "$CANCELLED" = true ]; then
    rm -f "$TMPLOG"

    if [ -n "$BASENAME_RESTRICT" ]; then
        shopt -s nullglob
        for LEFTOVER in "$DOWNLOAD_DIR/$BASENAME_RESTRICT".*; do
            rm -f "$LEFTOVER"
        done
        shopt -u nullglob
    fi

    yad --info --text="Descarga cancelada."
    exit 0
fi

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
    yad --error --text="No se encontró el archivo final."
    exit 1
fi

FULLPATH="$DOWNLOAD_DIR/$NEWFILE"

# ---------------------------------------------------------
# Conversión final si es audio
# ---------------------------------------------------------

if [ "$QUALITY" = "AUDIO" ]; then
    # Mostrar dialog pulsante mientras ffmpeg convierte en background
    CONVERTTMP=$(mktemp /tmp/ytdownloader-converted-XXXX.tmp)

    (
        NEWFILE2=$(convert_audio "$FULLPATH" "$AUDIO_FORMAT")
        echo "$NEWFILE2" > "$CONVERTTMP"
    ) &
    FFMPEG_PID=$!

    # El subshell solo necesita mantener el pipe abierto mientras
    # ffmpeg trabaja; yad --pulsate ignora el texto actualizado.
    (
        while kill -0 $FFMPEG_PID 2>/dev/null; do
            echo "0"
            echo "# Convirtiendo a $AUDIO_FORMAT..."
            sleep 0.1
        done
    ) | yad --progress \
        --title="Convirtiendo a $AUDIO_FORMAT..." \
        --text="$TITLE" \
        --pulsate \
        --auto-close \
        --no-buttons

    wait $FFMPEG_PID
    NEWFILE2=$(cat "$CONVERTTMP" 2>/dev/null)
    rm -f "$CONVERTTMP"

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

yad --info \
    --title="Descarga completada" \
    --text="Descarga completada:\n\n$TITLE\n\nArchivo:\n$FULLPATH\n\nResolución: $RES\nCódec: $CODEC"
