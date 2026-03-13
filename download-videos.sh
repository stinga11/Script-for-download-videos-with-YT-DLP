#!/bin/bash

DOWNLOAD_DIR="$HOME/Videos"

# ---------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------

# Detectar si un archivo es solo audio (sin stream de video)
is_audio_only() {
    local FILE="$1"
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_type \
        -of csv=p=0 "$FILE" 2>/dev/null | grep -q "video" && return 1
    return 0
}

# Convertir audio a mp3 u opus
convert_audio() {
    local INPUT="$1"
    local TARGET="$2"
    local OUTPUT="${INPUT%.*}.$TARGET"

    if [ "$TARGET" = "mp3" ]; then
        ffmpeg -y -i "$INPUT" -vn -codec:a libmp3lame -qscale:a 2 "$OUTPUT"
    elif [ "$TARGET" = "opus" ]; then
        ffmpeg -y -i "$INPUT" -vn -codec:a libopus -b:a 128k "$OUTPUT"
    fi

    echo "$OUTPUT"
}

# Contenedores separados
VIDEO_EXTS=("mkv" "mp4" "webm")
AUDIO_EXTS=("webm" "m4a" "opus")

# ---------------------------------------------------------
# Detectar URL del portapapeles
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
# Obtener metadata
# ---------------------------------------------------------

TITLE=$(yt-dlp --get-title "$URL" 2>/dev/null)
SIZE=$(yt-dlp --get-filesize "$URL" 2>/dev/null)

[ -z "$TITLE" ] && zenity --error --text="No se pudo obtener información del video." && exit 1

if [ -n "$SIZE" ]; then
    SIZE_MB=$((SIZE/1024/1024))
    SIZE_TEXT="~${SIZE_MB} MB"
else
    SIZE_TEXT="Desconocido"
fi

# ---------------------------------------------------------
# Listar formatos disponibles con yt-dlp -F
# ---------------------------------------------------------

FORMAT_LIST=$(yt-dlp -F "$URL" 2>/dev/null)

if [ -z "$FORMAT_LIST" ]; then
    zenity --error --text="No se pudieron obtener los formatos disponibles."
    exit 1
fi

# Extraer SOLO formatos de video (ignorar audio)
VIDEO_OPTIONS=$(echo "$FORMAT_LIST" | awk '
/^[0-9]/ {
    id=$1
    res=""
    fps=0
    codec=""
    hdr=""
    for(i=1;i<=NF;i++){
        # Detectar resolución
        if($i ~ /^[0-9]+x[0-9]+$/){
            split($i, r, "x")
            res = r[2] "p"
        }
        if($i ~ /^[0-9]+p/){
            res = $i
        }

        # Detectar FPS
        if($i ~ /^[0-9]+fps$/){
            fps = substr($i, 1, length($i)-3)
        }

        # Detectar códec
        if($i ~ /(vp9|avc|h264|av01|av1|hev1|hvc1)/){
            codec=$i
            split(codec, c, ".")
            codec=c[1]

            # Detectar HDR
            if($i ~ /vp9\.2/ || $i ~ /av01.*M/ || $i ~ /hvc1/ || $i ~ /hev1/){
                hdr="HDR"
            }
        }
    }

    if(res != "" && codec != ""){
        # Extraer altura numérica (ej: 2160 de 2160p60)
        split(res, rr, "p")
        height = rr[1]

        # Formato para ordenar: height fps hdrflag id desc
        hdrflag = (hdr == "HDR") ? 1 : 0

        desc = res " " codec
        if(hdr != "") desc = desc " (HDR)"

        print height, fps, hdrflag, id "|" desc
    }
}' | sort -k1,1nr -k2,2nr -k3,3nr | cut -d' ' -f4-)

# Construir lista para Zenity y mapear ID internamente
ZENITY_LIST=()
declare -A VIDEO_MAP

while IFS="|" read -r ID DESC; do
    VIDEO_MAP["$DESC"]="$ID"
    ZENITY_LIST+=("$DESC" "$ID")
done <<< "$VIDEO_OPTIONS"

# Añadir opción de solo audio
VIDEO_MAP["Solo audio (OPUS)"]="AUDIO"
ZENITY_LIST+=("Solo audio (OPUS)" "AUDIO")

# Mostrar selector con columna oculta
SELECTED_DESC=$(zenity --list \
    --title="Seleccionar formato" \
    --text="Selecciona la resolución del video o solo audio:" \
    --column="Formato" --column="" \
    --hide-column=2 \
    --print-column=1 \
    --cancel-label="Cancelar" \
    "${ZENITY_LIST[@]}")

# Si canceló
[ $? -ne 0 ] && exit 0

[ -z "$SELECTED_DESC" ] && exit 0

# ---------------------------------------------------------
# Determinar formato según selección
# ---------------------------------------------------------

if [ "$SELECTED_DESC" = "Solo audio (OPUS)" ]; then
    QUALITY="5"
    FORMAT="bestaudio[acodec=opus]/bestaudio"
else
    QUALITY="VIDEO"
    VIDEO_ID="${VIDEO_MAP[$SELECTED_DESC]}"
    FORMAT="$VIDEO_ID+bestaudio/best"
fi

# ---------------------------------------------------------
# Si es audio, elegir formato final
# ---------------------------------------------------------

if [ "$QUALITY" = "5" ]; then
    AUDIO_FORMAT=$(zenity --list \
    --title="Formato de audio" \
    --text="Selecciona el formato final del audio:" \
    --column="Formato" --column="Descripción" \
    --cancel-label="Cancelar" \
    "mp3" "Alta compatibilidad" \
    "opus" "Mejor calidad/tamaño")

# Si canceló
[ $? -ne 0 ] && exit 0

# Si no eligió nada
[ -z "$AUDIO_FORMAT" ] && exit 0
fi

# ---------------------------------------------------------
# Obtener nombre final
# ---------------------------------------------------------

FILENAME=$(yt-dlp --get-filename -f "$FORMAT" -o "%(title)s.%(ext)s" "$URL" | head -n1)

[ -z "$FILENAME" ] && zenity --error --text="No se pudo determinar el nombre del archivo." && exit 1

BASENAME_ORIG="${FILENAME%.*}"
BASENAME_RESTRICT=$(echo "$BASENAME_ORIG" | tr ' ' '_' | tr -cd 'A-Za-z0-9._-')

# ---------------------------------------------------------
# Detectar archivo existente
# ---------------------------------------------------------

if [ "$QUALITY" = "5" ]; then
    EXTS=("${AUDIO_EXTS[@]}")
else
    EXTS=("${VIDEO_EXTS[@]}" "m4a" "opus")
fi

FOUND_FILE=""
for BASE in "$BASENAME_ORIG" "$BASENAME_RESTRICT"; do
    for EXT in "${EXTS[@]}"; do
        CANDIDATE="$DOWNLOAD_DIR/${BASE}.$EXT"
        if [ -f "$CANDIDATE" ]; then

            if [ "$QUALITY" = "5" ]; then
                is_audio_only "$CANDIDATE" && FOUND_FILE="$CANDIDATE" && break 2
            else
                ! is_audio_only "$CANDIDATE" && FOUND_FILE="$CANDIDATE" && break 2
            fi

        fi
    done
done

if [ -n "$FOUND_FILE" ]; then
    zenity --question --title="Archivo existente" \
        --text="Ya existe un archivo con este nombre:\n\n$(basename "$FOUND_FILE")\n\n¿Deseas reemplazarlo?"

    [ $? -ne 0 ] && zenity --info --text="Descarga cancelada." && exit 0

    OVERWRITE_FLAG="--force-overwrites"
fi

mkdir -p "$DOWNLOAD_DIR"

# ---------------------------------------------------------
# Descargar
# ---------------------------------------------------------

BEFORE=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -printf "%f\n" | sort)

PIPE=$(mktemp -u /tmp/ytdownloader.XXXX)
mkfifo "$PIPE"

yt-dlp \
    -f "$FORMAT" \
    -o "$DOWNLOAD_DIR/%(title)s.%(ext)s" \
    --restrict-filenames \
    --retries 10 \
    --fragment-retries 10 \
    --progress \
    --merge-output-format mkv \
    --concurrent-fragments 8 \
    $OVERWRITE_FLAG \
    --newline \
    --progress-template "%(progress._percent_str)s" \
    "$URL" > "$PIPE" 2>&1 &

YTPID=$!

(
while read -r LINE; do
    CLEAN=$(tr -d '[:space:]' <<< "$LINE")
    if [[ "$CLEAN" =~ ^([0-9]+\.[0-9]+)%$ ]]; then
        RAW="${BASH_REMATCH[1]}"
        PERCENT=$(printf "%.0f" "$RAW")
        [ "$PERCENT" -ge 100 ] && PERCENT=99
        echo $PERCENT
        echo "# Descargando: $PERCENT %"
    fi
done < "$PIPE"
) | zenity --progress \
    --title="Descargando" \
    --text="Descargando:\n\n$TITLE" \
    --percentage=0 \
    --cancel-label="Cancelar" \
    --auto-close

# Si el usuario canceló, zenity devuelve código distinto de 0
if [ $? -ne 0 ]; then
    kill $YTPID 2>/dev/null
    rm -f "$PIPE"

    # Activar nullglob para evitar errores si no hay coincidencias
    shopt -s nullglob

    # Borrar archivos incompletos (.part, .part-Frag*, .ytdl, .temp)
    for f in "$DOWNLOAD_DIR"/"${BASENAME_RESTRICT}"*; do
        case "$f" in
            *.part|*.part-*|*.ytdl|*.temp)
                rm -f "$f"
                ;;
        esac
    done

    # Desactivar nullglob
    shopt -u nullglob

    zenity --info --text="Descarga cancelada."
    exit 0
fi

wait $YTPID
rm -f "$PIPE"

# ---------------------------------------------------------
# Detectar archivo final
# ---------------------------------------------------------

AFTER=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -printf "%f\n" | sort)

if [ "$QUALITY" = "5" ]; then
    EXTS=("${AUDIO_EXTS[@]}")
else
    EXTS=("${VIDEO_EXTS[@]}" "m4a" "opus")
fi

FOUND_FINAL=""
FILE=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER"))

if [ -n "$FILE" ]; then
    FOUND_FINAL="$DOWNLOAD_DIR/$FILE"
else
    for BASE in "$BASENAME_ORIG" "$BASENAME_RESTRICT"; do
        for EXT in "${EXTS[@]}"; do
            CANDIDATE="$DOWNLOAD_DIR/${BASE}.$EXT"

            if [ -f "$CANDIDATE" ]; then
                if [ "$QUALITY" = "5" ]; then
                    is_audio_only "$CANDIDATE" && FOUND_FINAL="$CANDIDATE" && break 2
                else
                    ! is_audio_only "$CANDIDATE" && FOUND_FINAL="$CANDIDATE" && break 2
                fi
            fi
        done
    done
fi

if [ -z "$FOUND_FINAL" ] || [ ! -f "$FOUND_FINAL" ]; then
    zenity --error --text="No se encontró el archivo final."
    exit 1
fi

FULLPATH="$FOUND_FINAL"

# ---------------------------------------------------------
# Conversión final si es audio
# ---------------------------------------------------------

if [ "$QUALITY" = "5" ]; then
    NEWFILE=$(convert_audio "$FULLPATH" "$AUDIO_FORMAT")

    # Si quieres borrar el archivo original, descomenta:
    rm "$FULLPATH"

    FULLPATH="$NEWFILE"
fi

# ---------------------------------------------------------
# Mostrar información final
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
