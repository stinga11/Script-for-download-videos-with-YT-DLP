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
    URL=$(zenity --entry --title="Descargar video" --text="Pega el link del video o playlist:")
fi

[ -z "$URL" ] && exit 1

# ---------------------------------------------------------
# Detectar si es una playlist
# ---------------------------------------------------------

IS_PLAYLIST=0
if echo "$URL" | grep -qE "(list=|/playlist\?|/sets/)"; then
    IS_PLAYLIST=1
fi

if echo "$URL" | grep -qE "list=" && echo "$URL" | grep -qE "[?&]v="; then
    CHOICE=$(zenity --list \
        --title="Video o Playlist" \
        --text="La URL contiene un video dentro de una playlist.\n¿Qué deseas descargar?" \
        --column="Opción" \
        "Solo este video" \
        "Toda la playlist")

    [ $? -ne 0 ] && exit 0
    [ -z "$CHOICE" ] && exit 0

    if [ "$CHOICE" = "Toda la playlist" ]; then
        IS_PLAYLIST=1
        LIST_ID=$(echo "$URL" | grep -Eo 'list=[A-Za-z0-9_-]+' | head -n1)
        URL="https://www.youtube.com/playlist?$LIST_ID"
    else
        IS_PLAYLIST=0
        URL=$(echo "$URL" | sed 's/&list=[^&]*//;s/?list=[^&]*/?/')
    fi
fi

# ==========================================================
# RAMA PLAYLIST
# ==========================================================

if [ "$IS_PLAYLIST" = "1" ]; then

    PLAYLIST_TITLE=$(yt-dlp --flat-playlist --print "%(playlist_title)s" "$URL" 2>/dev/null | head -n1)
    [ -z "$PLAYLIST_TITLE" ] && PLAYLIST_TITLE="Playlist"

    PLAYLIST_COUNT=$(yt-dlp --flat-playlist --print "%(playlist_index)s" "$URL" 2>/dev/null | wc -l)

    PLAYLIST_DIR_NAME=$(echo "$PLAYLIST_TITLE" | tr '/' '_' | tr -cd 'A-Za-z0-9 ._-' | sed 's/  */ /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$PLAYLIST_DIR_NAME" ] && PLAYLIST_DIR_NAME="Playlist"
    PLAYLIST_DEST="$DOWNLOAD_DIR/$PLAYLIST_DIR_NAME"

    zenity --question \
        --title="Descargar Playlist" \
        --text="Playlist detectada:\n\n<b>$PLAYLIST_TITLE</b>\n\n$PLAYLIST_COUNT videos\n\nSe guardará en:\n$PLAYLIST_DEST\n\n¿Continuar?" \
        --ok-label="Descargar" \
        --cancel-label="Cancelar"
    [ $? -ne 0 ] && exit 0

    FORMAT_LIST=$(yt-dlp -F --playlist-items 1 "$URL" 2>/dev/null)

    VIDEO_OPTIONS=$(echo "$FORMAT_LIST" | awk '
    /^[0-9]/ {
        id=$1; res=""; fps=0; codec=""; hdr=""; tbr=0; codec_rank=0
        for(i=1;i<=NF;i++){
            if($i ~ /^[0-9]+x[0-9]+$/){ split($i,r,"x"); res=r[2]"p" }
            if($i ~ /^[0-9]+p[0-9]+$/){ match($i,/^([0-9]+)p([0-9]+)$/,m); res=m[1]"p"; fps=m[2] }
            else if($i ~ /^[0-9]+p$/){ res=$i }
            if($i ~ /^[0-9]+fps$/){ fps=substr($i,1,length($i)-3) }
            if($i ~ /^[0-9]+$/ && $i+0>=1 && $i+0<=240 && res!="" && fps==0){ fps=$i+0 }
            if($i ~ /(vp9|avc|h264|av01|av1|hev1|hvc1)/){
                codec=$i; split(codec,c,"."); codec=c[1]
                if($i ~ /vp9\.2/ || $i ~ /av01.*M/ || $i ~ /hvc1/ || $i ~ /hev1/) hdr="HDR"
            }
            if($i ~ /^[0-9]+k$/){ tbr=substr($i,1,length($i)-1) }
        }
        if(codec=="av01"||codec=="av1") codec_rank=3
        else if(codec=="vp9") codec_rank=2
        else if(codec=="avc"||codec=="h264") codec_rank=1
        if(res!="" && codec!=""){
            split(res,rr,"p"); height=rr[1]; hdrflag=(hdr=="HDR")?1:0
            if(fps>0) desc=res" "fps"fps "codec
            else desc=res" "codec
            if(tbr>0) desc=desc" ("tbr"k)"
            if(hdr!="") desc=desc" (HDR)"
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
        --title="Seleccionar formato — Playlist" \
        --text="Selecciona la resolución para toda la playlist:" \
        --column="Formato" \
        "${ZENITY_LIST[@]}")
    [ $? -ne 0 ] && exit 0
    [ -z "$SELECTED" ] && exit 0

    if [ "$SELECTED" = "Solo audio (OPUS)" ]; then
        QUALITY="AUDIO"
        FORMAT="bestaudio"

        AUDIO_FORMAT=$(zenity --list \
            --title="Formato de audio" \
            --text="Selecciona el formato final del audio:" \
            --column="Formato" --column="Descripción" \
            "mp3" "Alta compatibilidad" \
            "opus" "Mejor calidad/tamaño")
        [ $? -ne 0 ] && exit 0
        [ -z "$AUDIO_FORMAT" ] && exit 0
    else
        QUALITY="VIDEO"
        VIDEO_ID="${VIDEO_MAP[$SELECTED]}"
        FORMAT="$VIDEO_ID+bestaudio"
    fi

    mkdir -p "$PLAYLIST_DEST"

    # ---- Detección de carpeta existente con contenido del mismo tipo ----
    OVERWRITE_FLAG=""
    EXISTING_COUNT=0
    if [ -d "$PLAYLIST_DEST" ]; then
        while IFS= read -r -d '' FPATH; do
            if [ "$QUALITY" = "AUDIO" ]; then
                ACTUAL_CODEC=$(ffprobe -v error \
                    -select_streams a:0 \
                    -show_entries stream=codec_name \
                    -of default=nw=1:nk=1 "$FPATH" 2>/dev/null)
                HAS_VIDEO=$(ffprobe -v error -select_streams v:0 \
                    -show_entries stream=codec_type \
                    -of csv=p=0 "$FPATH" 2>/dev/null | grep -q video && echo yes)
                if [ "$HAS_VIDEO" != "yes" ] && [ "$ACTUAL_CODEC" = "$AUDIO_FORMAT" ]; then
                    EXISTING_COUNT=$(( EXISTING_COUNT + 1 ))
                fi
            else
                if ffprobe -v error -select_streams v:0 \
                    -show_entries stream=codec_type \
                    -of csv=p=0 "$FPATH" 2>/dev/null | grep -q video; then
                    EXISTING_COUNT=$(( EXISTING_COUNT + 1 ))
                fi
            fi
        done < <(find "$PLAYLIST_DEST" -maxdepth 1 -type f -print0)
    fi

    if [ "$EXISTING_COUNT" -gt 0 ]; then
        zenity --question \
            --title="Carpeta existente" \
            --text="La carpeta ya existe y contiene $EXISTING_COUNT archivo(s) del mismo tipo:\n\n$PLAYLIST_DEST\n\n¿Deseas reemplazarlos?"

        if [ $? -ne 0 ]; then
            zenity --info --text="Descarga cancelada."
            exit 0
        fi

        OVERWRITE_FLAG="--force-overwrites"
    fi

    # ---- Descarga con progreso ----
    TMPLOG=$(mktemp /tmp/ytdownloader-XXXX.log)

    if [ "$QUALITY" = "AUDIO" ]; then
        POST_ARGS="--extract-audio --audio-format $AUDIO_FORMAT --audio-quality 0"
        OUT_TEMPLATE="$PLAYLIST_DEST/%(playlist_index)s - %(title)s.%(ext)s"
    else
        POST_ARGS="--merge-output-format mkv"
        OUT_TEMPLATE="$PLAYLIST_DEST/%(playlist_index)s - %(title)s.%(ext)s"
    fi

    yt-dlp \
        -f "$FORMAT" \
        -o "$OUT_TEMPLATE" \
        --restrict-filenames \
        --concurrent-fragments 8 \
        --retries 10 \
        --fragment-retries 10 \
        --newline \
        --progress-template "%(progress._percent_str)s|%(info.playlist_index)s|%(info.n_entries)s|%(info.title)s" \
        $POST_ARGS \
        $OVERWRITE_FLAG \
        "$URL" >> "$TMPLOG" 2>&1 &

    YTPID=$!

    (
    CURRENT_IDX=0
    TOTAL=0
    CURRENT_TITLE=""
    PERC=0
    tail -f --pid=$YTPID "$TMPLOG" | while read -r LINE; do
        if echo "$LINE" | grep -qE '^[0-9]+(\.?[0-9]*)%\|'; then
            IFS='|' read -r PERC IDX NTOTAL VTITLE <<< "$(echo "$LINE" | sed 's/%//')"

            if [[ "$PERC"   =~ ^[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*$ ]] && \
               [[ "$IDX"    =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] && \
               [[ "$NTOTAL" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]]; then

                PERC=$(printf "%.0f" "$PERC" 2>/dev/null || echo 0)
                IDX=$(echo "$IDX" | tr -d '[:space:]')
                NTOTAL=$(echo "$NTOTAL" | tr -d '[:space:]')

                [ "$PERC" -ge 100 ] && PERC=99
                CURRENT_IDX="$IDX"
                TOTAL="$NTOTAL"
                CURRENT_TITLE="${VTITLE:-$CURRENT_TITLE}"
                if [ "$TOTAL" -gt 0 ]; then
                    OVERALL=$(( ((CURRENT_IDX - 1) * 100 + PERC) / TOTAL ))
                    [ "$OVERALL" -ge 100 ] && OVERALL=99
                    echo "$OVERALL"
                    echo "# [Video $CURRENT_IDX/$TOTAL]  $CURRENT_TITLE — $PERC%   |   Playlist: $OVERALL%"
                fi
            fi
        fi
    done
    ) | zenity --progress \
        --title="Descargando playlist: $PLAYLIST_TITLE" \
        --text="Iniciando..." \
        --percentage=0 \
        --cancel-label="Cancelar" \
        --auto-close &

    ZENITY_PID=$!
    CANCELLED=false

    # Bucle principal
    while kill -0 $YTPID 2>/dev/null; do
        if ! kill -0 $ZENITY_PID 2>/dev/null; then
            CANCELLED=true
            kill -TERM $YTPID 2>/dev/null
            break
        fi
        sleep 0.3
    done

    # Race condition fix
    PL_DIALOG_CLOSED_BY_US=false

    if [ "$CANCELLED" != true ] && kill -0 $ZENITY_PID 2>/dev/null; then
        kill $ZENITY_PID 2>/dev/null
        PL_DIALOG_CLOSED_BY_US=true
    fi

    wait $YTPID 2>/dev/null
    wait $ZENITY_PID 2>/dev/null

    if [ "$CANCELLED" != true ] && [ "$PL_DIALOG_CLOSED_BY_US" != true ]; then
        CANCELLED=true
    fi

    if [ "$CANCELLED" = true ]; then
        rm -f "$TMPLOG"

        shopt -s nullglob
        for f in "$PLAYLIST_DEST"/*; do
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

    rm -f "$TMPLOG"

    # ---------------------------------------------------------
    # Info final (un solo resumen para toda la playlist)
    # ---------------------------------------------------------

    SAMPLE=""
    while IFS= read -r -d '' FPATH; do
        if [ "$QUALITY" = "AUDIO" ]; then
            ACTUAL_CODEC=$(ffprobe -v error \
                -select_streams a:0 \
                -show_entries stream=codec_name \
                -of default=nw=1:nk=1 "$FPATH" 2>/dev/null)
            HAS_VIDEO=$(ffprobe -v error -select_streams v:0 \
                -show_entries stream=codec_type \
                -of csv=p=0 "$FPATH" 2>/dev/null | grep -q video && echo yes)
            if [ "$HAS_VIDEO" != "yes" ] && [ "$ACTUAL_CODEC" = "$AUDIO_FORMAT" ]; then
                SAMPLE="$FPATH"
                break
            fi
        else
            if ffprobe -v error -select_streams v:0 \
                -show_entries stream=codec_type \
                -of csv=p=0 "$FPATH" 2>/dev/null | grep -q video; then
                SAMPLE="$FPATH"
                break
            fi
        fi
    done < <(find "$PLAYLIST_DEST" -maxdepth 1 -type f -print0 | sort -z)

    FILE_COUNT=$(find "$PLAYLIST_DEST" -maxdepth 1 -type f | wc -l)

    if [ -n "$SAMPLE" ]; then
        INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=height,codec_name \
            -of csv=p=0 "$SAMPLE" 2>/dev/null)

        if [ -z "$INFO" ]; then
            RES="Solo audio"
            CODEC=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
                -of csv=p=0 "$SAMPLE" 2>/dev/null)
        else
            CODEC=$(echo "$INFO" | cut -d',' -f1)
            HEIGHT=$(echo "$INFO" | cut -d',' -f2)
            RES="${HEIGHT}p"
        fi
    else
        RES="Desconocido"
        CODEC="Desconocido"
    fi

    zenity --info \
        --title="Playlist descargada" \
        --text="Descarga completada:\n\n$PLAYLIST_TITLE\n\nCarpeta:\n$PLAYLIST_DEST\n\n$FILE_COUNT archivos descargados\n\nResolución: $RES\nCódec: $CODEC"
    exit 0
fi

# ==========================================================
# RAMA VIDEO INDIVIDUAL
# ==========================================================

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

        if($i ~ /^[0-9]+$/ && $i+0>=1 && $i+0<=240 && res!="" && fps==0){
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
    --auto-close &

ZENITY_PID=$!
CANCELLED=false

# Bucle principal
while kill -0 $YTPID 2>/dev/null; do
    if ! kill -0 $ZENITY_PID 2>/dev/null; then
        CANCELLED=true
        kill -TERM $YTPID 2>/dev/null
        break
    fi
    sleep 0.3
done

# Race condition fix
DIALOG_CLOSED_BY_US=false

if [ "$CANCELLED" != true ] && kill -0 $ZENITY_PID 2>/dev/null; then
    kill $ZENITY_PID 2>/dev/null
    DIALOG_CLOSED_BY_US=true
fi

wait $YTPID 2>/dev/null
wait $ZENITY_PID 2>/dev/null

if [ "$CANCELLED" != true ] && [ "$DIALOG_CLOSED_BY_US" != true ]; then
    CANCELLED=true
fi

# ---------------------------------------------------------
# Cancelación
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

    zenity --info --text="Descarga cancelada."
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
    CONVERTTMP=$(mktemp /tmp/ytdownloader-converted-XXXX.tmp)

    (
        NEWFILE2=$(convert_audio "$FULLPATH" "$AUDIO_FORMAT")
        echo "$NEWFILE2" > "$CONVERTTMP"
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

zenity --info \
    --title="Descarga completada" \
    --text="Descarga completada:\n\n$TITLE\n\nArchivo:\n$FULLPATH\n\nResolución: $RES\nCódec: $CODEC"
