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
    URL=$(kdialog --title "Descargar video" --inputbox "Pega el link del video o playlist:")
fi

[ -z "$URL" ] && exit 1

# ---------------------------------------------------------
# Detectar si es una playlist
# ---------------------------------------------------------

IS_PLAYLIST=0
if echo "$URL" | grep -qE "(list=|/playlist\?|/sets/)"; then
    IS_PLAYLIST=1
fi

# URL con video Y lista → preguntar qué descargar
if echo "$URL" | grep -qE "list=" && echo "$URL" | grep -qE "[?&]v="; then
    CHOICE=$(kdialog --title "Video o Playlist" \
        --menu "La URL contiene un video dentro de una playlist.\n¿Qué deseas descargar?" \
        1 "Solo este video" \
        2 "Toda la playlist")
    [ $? -ne 0 ] && exit 0

    if [ "$CHOICE" = "2" ]; then
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

    PLAYLIST_DIR_NAME=$(echo "$PLAYLIST_TITLE" | tr '/' '_' | tr -cd 'A-Za-z0-9 ._-' | \
        sed 's/  */ /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$PLAYLIST_DIR_NAME" ] && PLAYLIST_DIR_NAME="Playlist"
    PLAYLIST_DEST="$DOWNLOAD_DIR/$PLAYLIST_DIR_NAME"

    kdialog --title "Descargar Playlist" \
        --yesno "Playlist detectada:\n\n$PLAYLIST_TITLE\n\n$PLAYLIST_COUNT videos\n\nSe guardará en:\n$PLAYLIST_DEST\n\n¿Continuar?" \
        --yes-label "Descargar" --no-label "Cancelar"
    [ $? -ne 0 ] && exit 0

    # ---- Obtener y parsear formatos (usando el primer video) ----
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
    PL_MENU=()
    PL_MAP=()
    pi=1

    while IFS="|" read -r ID DESC; do
        VIDEO_MAP["$DESC"]="$ID"
        PL_MENU+=("$pi" "$DESC")
        PL_MAP[$pi]="$DESC"
        ((pi++))
    done <<< "$VIDEO_OPTIONS"

    PL_MENU+=("$pi" "Solo audio (OPUS)")
    PL_MAP[$pi]="Solo audio (OPUS)"

    PL_CHOICE=$(kdialog --title "Seleccionar formato — Playlist" \
        --menu "Selecciona la resolución para toda la playlist:" \
        "${PL_MENU[@]}")
    [ $? -ne 0 ] && exit 0
    [ -z "$PL_CHOICE" ] && exit 0

    SELECTED="${PL_MAP[$PL_CHOICE]}"

    if [ "$SELECTED" = "Solo audio (OPUS)" ]; then
        QUALITY="AUDIO"
        FORMAT="bestaudio"

        AUDIO_MENU=(
            1 "mp3 - Alta compatibilidad"
            2 "opus - Mejor calidad/tamaño"
        )
        AUDIO_CHOICE=$(kdialog --title "Formato de audio" \
            --menu "Selecciona el formato final:" \
            "${AUDIO_MENU[@]}")
        [ $? -ne 0 ] && exit 0

        case "$AUDIO_CHOICE" in
            1) AUDIO_FORMAT="mp3" ;;
            2) AUDIO_FORMAT="opus" ;;
        esac
    else
        QUALITY="VIDEO"
        VIDEO_ID="${VIDEO_MAP[$SELECTED]}"
        FORMAT="$VIDEO_ID+bestaudio"
    fi

    mkdir -p "$PLAYLIST_DEST"

    # ---- Detectar archivos existentes del mismo tipo ----
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
        kdialog --title "Carpeta existente" \
            --yesno "La carpeta ya existe y contiene $EXISTING_COUNT archivo(s) del mismo tipo:\n\n$PLAYLIST_DEST\n\n¿Deseas reemplazarlos?"
        if [ $? -ne 0 ]; then
            kdialog --sorry "Descarga cancelada."
            exit 0
        fi
        OVERWRITE_FLAG="--force-overwrites"
    fi

    # ---- Configurar argumentos según tipo ----
    if [ "$QUALITY" = "AUDIO" ]; then
        POST_ARGS="--extract-audio --audio-format $AUDIO_FORMAT --audio-quality 0"
        OUT_TEMPLATE="$PLAYLIST_DEST/%(playlist_index)s - %(title)s.%(ext)s"
    else
        POST_ARGS="--merge-output-format mkv"
        OUT_TEMPLATE="$PLAYLIST_DEST/%(playlist_index)s - %(title)s.%(ext)s"
    fi

    # ---- Descarga con progreso kdialog ----
    TMPLOG=$(mktemp /tmp/ytdownloader-XXXX.log)

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

    PL_PROGRESS=$(kdialog --title "Descargando playlist: $PLAYLIST_TITLE" \
        --progressbar "Iniciando..." 100)
    $QDBUS $PL_PROGRESS showCancelButton true

    CANCELLED=false

    (
    tail -f --pid=$YTPID "$TMPLOG" | while read -r LINE; do
        if ! $QDBUS $PL_PROGRESS >/dev/null 2>&1; then
            exit 0
        fi
        if echo "$LINE" | grep -qE '^[0-9]+(\.?[0-9]*)%\|'; then
            IFS='|' read -r PERC IDX NTOTAL VTITLE <<< "$(echo "$LINE" | sed 's/%//')"
            if [[ "$PERC"   =~ ^[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*$ ]] && \
               [[ "$IDX"    =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] && \
               [[ "$NTOTAL" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]]; then
                PERC=$(printf "%.0f" "$PERC" 2>/dev/null || echo 0)
                IDX=$(echo "$IDX" | tr -d '[:space:]')
                NTOTAL=$(echo "$NTOTAL" | tr -d '[:space:]')
                [ "$PERC" -ge 100 ] && PERC=99
                if [ "$NTOTAL" -gt 0 ]; then
                    OVERALL=$(( ((IDX - 1) * 100 + PERC) / NTOTAL ))
                    [ "$OVERALL" -ge 100 ] && OVERALL=99
                    $QDBUS $PL_PROGRESS Set "" value $OVERALL 2>/dev/null
                    $QDBUS $PL_PROGRESS setLabelText "[Video $IDX/$NTOTAL]  ${VTITLE}  —  $PERC%   |   Playlist: $OVERALL%" 2>/dev/null
                fi
            fi
        fi
    done
    ) &
    PL_READER_PID=$!

    # Bucle principal de cancelación
    while kill -0 $YTPID 2>/dev/null; do
        if ! $QDBUS $PL_PROGRESS >/dev/null 2>&1; then
            CANCELLED=true
            kill -TERM $YTPID 2>/dev/null
            kill -TERM $PL_READER_PID 2>/dev/null
            rm -f "$TMPLOG"
            break
        fi
        PL_CANCELED=$($QDBUS $PL_PROGRESS wasCancelled 2>/dev/null)
        if [ "$PL_CANCELED" = "true" ]; then
            CANCELLED=true
            kill -TERM $YTPID 2>/dev/null
            kill -TERM $PL_READER_PID 2>/dev/null
            rm -f "$TMPLOG"
            break
        fi
        sleep 0.3
    done

    # Race condition fix
    PL_DIALOG_CLOSED_BY_US=false
    if [ "$CANCELLED" != true ] && $QDBUS $PL_PROGRESS >/dev/null 2>&1; then
        PL_LAST_CHECK=$($QDBUS $PL_PROGRESS wasCancelled 2>/dev/null)
        if [ "$PL_LAST_CHECK" = "true" ]; then
            CANCELLED=true
            kill -TERM $PL_READER_PID 2>/dev/null
            rm -f "$TMPLOG"
        fi
    fi

    if $QDBUS $PL_PROGRESS >/dev/null 2>&1; then
        $QDBUS $PL_PROGRESS close
        PL_DIALOG_CLOSED_BY_US=true
    fi

    wait $YTPID 2>/dev/null
    kill $PL_READER_PID 2>/dev/null
    [ -f "$TMPLOG" ] && rm -f "$TMPLOG"

    if [ "$CANCELLED" != true ] && [ "$PL_DIALOG_CLOSED_BY_US" != true ]; then
        CANCELLED=true
    fi

    if [ "$CANCELLED" = true ]; then
        shopt -s nullglob
        for f in "$PLAYLIST_DEST"/*; do
            case "$f" in
                *.part|*.part-*|*.ytdl|*.temp) rm -f "$f" ;;
            esac
        done
        shopt -u nullglob
        kdialog --sorry "Descarga cancelada."
        exit 0
    fi

    # ---- Info final de la playlist ----
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
        PL_INFO=$(ffprobe -v error -select_streams v:0 -show_entries stream=height,codec_name \
            -of csv=p=0 "$SAMPLE" 2>/dev/null)
        if [ -z "$PL_INFO" ]; then
            RES="Solo audio"
            CODEC=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
                -of csv=p=0 "$SAMPLE" 2>/dev/null)
        else
            CODEC=$(echo "$PL_INFO" | cut -d',' -f1)
            HEIGHT=$(echo "$PL_INFO" | cut -d',' -f2)
            RES="${HEIGHT}p"
        fi
    else
        RES="Desconocido"
        CODEC="Desconocido"
    fi

    kdialog --title "Playlist descargada" \
        --msgbox "Descarga completada\n\n$PLAYLIST_TITLE\n\nCarpeta:\n$PLAYLIST_DEST\n\n$FILE_COUNT archivos descargados\n\nResolución: $RES\nCódec: $CODEC"
    exit 0
fi

# ==========================================================
# RAMA VIDEO INDIVIDUAL
# ==========================================================

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
            HAS_VIDEO=$(ffprobe -v error -select_streams v:0 \
                -show_entries stream=codec_type \
                -of csv=p=0 "$AUDIO_CANDIDATE" 2>/dev/null | grep -q video && echo yes)
            if [ "$HAS_VIDEO" != "yes" ]; then
                FOUND_FILE="$AUDIO_CANDIDATE"
            fi
        fi
    else
        if [ -f "$EXPECTED_FILE" ]; then
            if ffprobe -v error -select_streams v:0 \
                -show_entries stream=codec_type \
                -of csv=p=0 "$EXPECTED_FILE" 2>/dev/null | grep -q video; then
                FOUND_FILE="$EXPECTED_FILE"
            fi
        fi
    fi
fi

if [ -n "$FOUND_FILE" ]; then
    kdialog --yesno "Ya existe:\n\n$(basename "$FOUND_FILE")\n\n¿Reemplazar?"

    if [ $? -ne 0 ]; then
        kdialog --msgbox "Descarga cancelada."
        exit 0
    fi

    OVERWRITE_FLAG="--force-overwrites"
fi

# ---------------------------------------------------------
# Snapshot antes (seguro)
# ---------------------------------------------------------

BEFORE=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -printf "%f\n" | sort)

# ---------------------------------------------------------
# Progreso KDE con FIFO
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

PROGRESS=$(kdialog --title "Descargando" --progressbar "$TITLE" 100)
$QDBUS $PROGRESS showCancelButton true

CANCELLED=false

(
while read -r LINE; do
    CLEAN=$(echo "$LINE" | tr -d '[:space:]')

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

# Race condition fix
DIALOG_CLOSED_BY_US=false

if [ "$CANCELLED" != true ] && $QDBUS $PROGRESS >/dev/null 2>&1; then
    LAST_CHECK=$($QDBUS $PROGRESS wasCancelled 2>/dev/null)
    if [ "$LAST_CHECK" = "true" ]; then
        CANCELLED=true
        kill -TERM $READER_PID 2>/dev/null
        rm -f "$PIPE"
    fi
fi

if $QDBUS $PROGRESS >/dev/null 2>&1; then
    $QDBUS $PROGRESS close
    DIALOG_CLOSED_BY_US=true
fi

wait $YTPID 2>/dev/null
rm -f "$PIPE"

if [ "$CANCELLED" != true ] && [ "$DIALOG_CLOSED_BY_US" != true ]; then
    CANCELLED=true
fi

if [ "$CANCELLED" = true ]; then
    for PART in "$DOWNLOAD_DIR/$BASENAME_RESTRICT".*.part \
                "$DOWNLOAD_DIR/$BASENAME_RESTRICT".*.ytdl; do
        [ -f "$PART" ] && rm -f "$PART"
    done

    AFTER=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -printf "%f\n" | sort)
    NEWFILE=$(comm -13 <(echo "$BEFORE" | sort) <(echo "$AFTER") | head -n1)
    if [ -n "$NEWFILE" ]; then
        rm -f "$DOWNLOAD_DIR/$NEWFILE"
    fi

    kdialog --sorry "Descarga cancelada."
    exit 0
fi

# ---------------------------------------------------------
# Detectar archivo nuevo (seguro)
# ---------------------------------------------------------

AFTER=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -printf "%f\n" | sort)

NEWFILE=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | head -n1)

if [ -z "$NEWFILE" ] && [ -n "$FOUND_FILE" ]; then
    NEWFILE=$(basename "$FOUND_FILE")
fi

[ -z "$NEWFILE" ] && kdialog --error "No se encontró el archivo final." && exit 1

FULLPATH="$DOWNLOAD_DIR/$NEWFILE"

# ---------------------------------------------------------
# Conversión audio
# ---------------------------------------------------------

if [ "$QUALITY" = "AUDIO" ]; then
    CONV_PROGRESS=$(kdialog --title "Convirtiendo audio" \
        --progressbar "Convirtiendo a $AUDIO_FORMAT..." 0)
    $QDBUS $CONV_PROGRESS showCancelButton false

    NEWFILE2=$(convert_audio "$FULLPATH" "$AUDIO_FORMAT")

    $QDBUS $CONV_PROGRESS close

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
    CODEC=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name -of csv=p=0 "$FULLPATH")
else
    CODEC=$(echo "$INFO" | cut -d',' -f1)
    HEIGHT=$(echo "$INFO" | cut -d',' -f2)
    RES="${HEIGHT}p"
fi

kdialog --msgbox "Descarga completada\n\n$TITLE\n\nArchivo:\n$FULLPATH\n\nResolución: $RES\nCódec: $CODEC"
