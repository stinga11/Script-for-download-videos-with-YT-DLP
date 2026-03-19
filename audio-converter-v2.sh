#!/bin/bash
# ════════════════════════════════════════════════════════════════
#  Audio Converter v3 — YAD + FFmpeg/FFprobe + CD Ripper
#  Fix: regex cdparanoia + metadata via gnudb (freedb)
#  Requiere: yad, ffmpeg, ffprobe, cdparanoia, cd-discid, curl, bc
# ════════════════════════════════════════════════════════════════

CONFIG_DIR="$HOME/.config/audio_converter"
CONFIG_FILE="$CONFIG_DIR/settings.conf"
HISTORY_FILE="$CONFIG_DIR/history.log"
TEMP_DIR=$(mktemp -d /tmp/audioconv_XXXXXX)
mkdir -p "$CONFIG_DIR"
trap 'rm -rf "$TEMP_DIR"; [[ -n "$CD_DEV" && "$MODE" == *"CD de audio"* ]] && eject "$CD_DEV" 2>/dev/null' EXIT

LAST_DIR="$HOME"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ════════════════════════════════════════════════════════════════
#  MENÚ PRINCIPAL
# ════════════════════════════════════════════════════════════════
MODE=$(yad --list \
    --title="🎵 Audio Converter v3" \
    --text="<b>¿Qué deseas convertir?</b>" \
    --column="Modo" \
    --column="Descripción" \
    "🗂  Archivos locales"  "Convierte archivos de audio desde tu disco" \
    "💿  CD de audio"       "Ripea y convierte pistas desde un CD" \
    --width=480 --height=230 \
    --print-column=1 \
    --no-headers \
    --button="gtk-cancel:1" \
    --button="Continuar ▶:0" 2>/dev/null)

[[ $? -ne 0 || -z "$MODE" ]] && exit 0
MODE=$(echo "$MODE" | tr -d '|' | xargs)

# ════════════════════════════════════════════════════════════════
#  FUNCIONES COMPARTIDAS
# ════════════════════════════════════════════════════════════════

select_format() {
    FORMAT_RAW=$(yad --list \
        --title="🎵 Audio Converter v3 — Formato de Salida" \
        --text="<b>Selecciona el formato al que deseas convertir:</b>" \
        --column="Ext" \
        --column="Nombre Completo" \
        --column="Tipo" \
        "mp3"  "MPEG Audio Layer III"           "Con pérdida" \
        "aac"  "Advanced Audio Coding"          "Con pérdida" \
        "flac" "Free Lossless Audio Codec"      "Sin pérdida ✦" \
        "ogg"  "Ogg Vorbis"                     "Con pérdida" \
        "wav"  "Waveform Audio File"            "Sin pérdida ✦" \
        "opus" "Opus Interactive Audio"         "Con pérdida" \
        "wma"  "Windows Media Audio"            "Con pérdida" \
        "m4a"  "MPEG-4 Audio"                   "Con pérdida" \
        "aiff" "Audio Interchange File Format"  "Sin pérdida ✦" \
        "mp2"  "MPEG Audio Layer II"            "Con pérdida" \
        --width=520 --height=450 \
        --print-column=1 \
        --button="gtk-cancel:1" \
        --button="Siguiente ▶:0" 2>/dev/null)
    [[ $? -ne 0 || -z "$FORMAT_RAW" ]] && return 1
    FORMAT=$(echo "$FORMAT_RAW" | tr -d '|' | xargs)
    return 0
}

select_quality() {
    IS_LOSSLESS=false
    BITRATE_OPT=""
    case "$FORMAT" in flac|wav|aiff) IS_LOSSLESS=true ;; esac
    if [[ "$IS_LOSSLESS" == "false" ]]; then
        QUALITY_RAW=$(yad --list \
            --title="🎵 Audio Converter v3 — Calidad de Audio" \
            --text="<b>Selecciona la calidad (bitrate) de salida:</b>" \
            --column="Bitrate" \
            --column="Calidad" \
            --column="Uso recomendado" \
            "64k"  "Baja"       "Voz, podcasts, audiolibros" \
            "96k"  "Media-baja" "Radio online, streaming básico" \
            "128k" "Media"      "Música casual, streaming general" \
            "192k" "Alta"       "Música de buena calidad  ✦" \
            "256k" "Muy alta"   "Música de alta fidelidad" \
            "320k" "Máxima"     "Audiófilos, archivos maestros" \
            --width=540 --height=380 \
            --print-column=1 \
            --button="gtk-cancel:1" \
            --button="Siguiente ▶:0" 2>/dev/null)
        [[ $? -ne 0 || -z "$QUALITY_RAW" ]] && return 1
        BITRATE_OPT=$(echo "$QUALITY_RAW" | tr -d '|' | xargs)
    fi
    return 0
}

select_output_dir() {
    OUTPUT_DIR=$(yad --file \
        --title="🎵 Audio Converter v3 — Carpeta de Destino" \
        --text="<b>Selecciona la carpeta donde se guardarán los archivos:</b>" \
        --directory \
        --filename="$LAST_DIR/" \
        --width=750 --height=520 \
        --button="gtk-cancel:1" \
        --button="Confirmar ✔:0" 2>/dev/null)
    [[ $? -ne 0 || -z "$OUTPUT_DIR" ]] && return 1
    echo "LAST_DIR=\"$OUTPUT_DIR\"" > "$CONFIG_FILE"
    return 0
}

convert_file() {
    local INPUT_FILE="$1"
    local OUTPUT_FILE="$2"
    local LABEL_EXTRA="${3:-}"

    local BASENAME=$(basename "$INPUT_FILE")
    local RAW_DUR=$(ffprobe -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$INPUT_FILE" 2>/dev/null)
    local DUR_INT=${RAW_DUR%.*}
    [[ -z "$DUR_INT" || ! "$DUR_INT" =~ ^[0-9]+$ || "$DUR_INT" -le 0 ]] && DUR_INT=0

    local PIPE=$(mktemp -u /tmp/audioconv_PIPE_XXXXXX)
    mkfifo "$PIPE"

    if [[ "$IS_LOSSLESS" == "true" ]]; then
        ffmpeg -y -i "$INPUT_FILE" -progress "$PIPE" -nostats \
               "$OUTPUT_FILE" >/dev/null 2>&1 &
    else
        ffmpeg -y -i "$INPUT_FILE" -b:a "$BITRATE_OPT" -progress "$PIPE" -nostats \
               "$OUTPUT_FILE" >/dev/null 2>&1 &
    fi
    FFMPEG_PID=$!

    local QLABEL="$FORMAT"
    [[ -n "$BITRATE_OPT" ]] && QLABEL="$FORMAT @ $BITRATE_OPT"
    local DIALOG_TEXT="<b>Convirtiendo:</b>  <i>$BASENAME</i>\n  <b>Calidad:</b>  $QLABEL"
    [[ -n "$LABEL_EXTRA" ]] && DIALOG_TEXT+="\n$LABEL_EXTRA"

    (
        local PCT=0
        while IFS= read -r line; do
            if [[ "$line" =~ ^out_time_ms=([0-9]+)$ ]]; then
                local T="${BASH_REMATCH[1]}"
                if [[ $DUR_INT -gt 0 ]]; then
                    PCT=$(( T / (DUR_INT * 10000) ))
                    [[ $PCT -gt 99 ]] && PCT=99
                else
                    PCT=$(( (PCT + 1) % 98 ))
                fi
                echo "$PCT"
            fi
            [[ "$line" == "progress=end" ]] && echo "100" && break
        done < "$PIPE"
    ) | yad --progress \
        --title="🔄 Convirtiendo..." \
        --text="$DIALOG_TEXT" \
        --percentage=0 \
        --auto-close \
        --width=560 \
        --button="⛔  Cancelar:1" 2>/dev/null

    local YAD_EXIT=$?
    rm -f "$PIPE"

    if [[ $YAD_EXIT -ne 0 ]]; then
        kill "$FFMPEG_PID" 2>/dev/null
        wait "$FFMPEG_PID" 2>/dev/null
        rm -f "$OUTPUT_FILE"
        yad --warning \
            --title="Cancelado" \
            --text="<b>⚠ Conversión cancelada.</b>\nArchivo parcial eliminado." \
            --width=400 --button="OK:0" 2>/dev/null
        return 2
    fi

    wait "$FFMPEG_PID"
    return $?
}

show_final_dialog() {
    local CONVERTED=$1; local FAILED=$2; local TOTAL=$3
    shift 3
    local FILES=("$@")

    local QLABEL="$FORMAT"
    [[ -n "$BITRATE_OPT" ]] && QLABEL="$FORMAT @ $BITRATE_OPT"

    local DONE_TEXT="<b><span foreground='#4CAF50' size='large'>✅  ¡Proceso completado!</span></b>\n\n"
    DONE_TEXT+="  <b>Convertidos:</b>  $CONVERTED de $TOTAL\n"
    [[ $FAILED -gt 0 ]] && \
        DONE_TEXT+="  <b><span foreground='#F44336'>Fallidos:</span></b>  $FAILED\n"
    DONE_TEXT+="  <b>Formato:</b>  $QLABEL\n"
    DONE_TEXT+="  <b>Ubicación:</b>  $OUTPUT_DIR\n\n"

    if [[ ${#FILES[@]} -gt 0 ]]; then
        DONE_TEXT+="<b>Archivos generados:</b>\n"
        local LIMIT=$(( ${#FILES[@]} < 8 ? ${#FILES[@]} : 8 ))
        for (( i=0; i<LIMIT; i++ )); do
            local CF="${FILES[$i]}"
            local FSIZE=$(du -sh "$CF" 2>/dev/null | cut -f1)
            DONE_TEXT+="  📄 $(basename "$CF")  <i>($FSIZE)</i>\n"
        done
        [[ ${#FILES[@]} -gt 8 ]] && \
            DONE_TEXT+="  … y $((${#FILES[@]}-8)) archivo(s) más\n"
    fi

    yad --info \
        --title="✅ Conversión completada" \
        --text="$DONE_TEXT" \
        --width=580 --height=360 \
        --button="🕑  Historial:3" \
        --button="📂  Abrir carpeta:2" \
        --button="gtk-ok:0" 2>/dev/null
    local BTN=$?
    [[ $BTN -eq 2 ]] && xdg-open "$OUTPUT_DIR" &
    if [[ $BTN -eq 3 ]]; then
        yad --text-info \
            --title="🕑 Historial de conversiones" \
            --filename="$HISTORY_FILE" \
            --width=800 --height=460 \
            --tail \
            --button="🗑  Borrar historial:2" \
            --button="gtk-ok:0" 2>/dev/null
        [[ $? -eq 2 ]] && > "$HISTORY_FILE"
    fi
}

# ════════════════════════════════════════════════════════════════
#  FUNCIÓN: Resolver conflicto de archivo existente
#  Uso: resolve_conflict "$OUTPUT_FILE" "$FNAME" "$FORMAT" "$DIR"
#  Sets: OUTPUT_FILE (nueva ruta), SKIP_FILE=true si cancela
# ════════════════════════════════════════════════════════════════
resolve_conflict() {
    local EXISTING="$1"
    local FNAME="$2"
    local FMT="$3"
    local DIR="$4"
    SKIP_FILE=false

    local FSIZE; FSIZE=$(du -sh "$EXISTING" 2>/dev/null | cut -f1)
    local FDATE; FDATE=$(stat -c "%y" "$EXISTING" 2>/dev/null | cut -d. -f1)
    local BNAME; BNAME=$(basename "$EXISTING")

    local ACTION
    ACTION=$(yad --list \
        --title="⚠ Archivo ya existe" \
        --text="<b>El archivo ya existe:</b>

  📄 <b>$BNAME</b>
  Tamaño: <i>$FSIZE</i>  |  Modificado: <i>$FDATE</i>

<b>¿Qué deseas hacer?</b>" \
        --column="Acción" \
        --column="Descripción" \
        "Reemplazar"  "Sobreescribir el archivo existente" \
        "Renombrar"   "Guardar con un nombre nuevo automáticamente" \
        "Omitir"      "Saltar este archivo y continuar" \
        --print-column=1 \
        --width=500 --height=260 \
        --no-headers \
        --button="Confirmar:0" 2>/dev/null)

    ACTION=$(echo "$ACTION" | tr -d '|' | xargs)

    case "$ACTION" in
        Reemplazar)
            OUTPUT_FILE="$EXISTING"
            ;;
        Renombrar)
            local C=1
            while [[ -f "$DIR/${FNAME}_${C}.$FMT" ]]; do ((C++)); done
            OUTPUT_FILE="$DIR/${FNAME}_${C}.$FMT"
            ;;
        *)
            SKIP_FILE=true
            ;;
    esac
}

# ════════════════════════════════════════════════════════════════
#  MODO A — ARCHIVOS LOCALES
# ════════════════════════════════════════════════════════════════
if [[ "$MODE" == *"Archivos locales"* ]]; then

    INPUT_RAW=$(yad --file \
        --title="🎵 Paso 1 — Seleccionar Archivos" \
        --text="<b>Selecciona uno o varios archivos de audio:</b>\n<i>Ctrl o Shift para seleccionar varios</i>" \
        --multiple \
        --file-filter="Archivos de Audio|*.mp3 *.aac *.flac *.ogg *.wav *.opus *.wma *.m4a *.aiff *.mp2 *.webm" \
        --file-filter="Todos los archivos|*" \
        --width=750 --height=520 \
        --button="gtk-cancel:1" \
        --button="Siguiente ▶:0" 2>/dev/null)
    [[ $? -ne 0 || -z "$INPUT_RAW" ]] && exit 0

    IFS='|' read -ra RAW_LIST <<< "$INPUT_RAW"
    INPUT_FILES=()
    for f in "${RAW_LIST[@]}"; do
        f="${f#"${f%%[![:space:]]*}"}"   # trim leading spaces
        f="${f%"${f##*[![:space:]]}"}"    # trim trailing spaces
        [[ -f "$f" ]] && INPUT_FILES+=("$f")
    done
    [[ ${#INPUT_FILES[@]} -eq 0 ]] && exit 1
    FILE_COUNT=${#INPUT_FILES[@]}

    # Construir lista para yad --list (una fila por archivo)
    INFO_ROWS=()
    for f in "${INPUT_FILES[@]}"; do
        BNAME=$(basename "$f")
        RAW2=$(ffprobe -v error             -show_entries format=duration,size             -show_entries stream=codec_name             -of default=noprint_wrappers=1 "$f" 2>/dev/null)
        F_DUR2=$(echo "$RAW2" | grep "^duration=" | head -1 | cut -d= -f2)
        F_SIZE2=$(echo "$RAW2" | grep "^size="    | head -1 | cut -d= -f2)
        F_COD2=$(echo "$RAW2"  | grep "^codec_name=" | head -1 | cut -d= -f2)
        DI2=${F_DUR2%.*}
        [[ "$DI2" =~ ^[0-9]+$ ]] && DUR2="$((DI2/60))m $((DI2%60))s" || DUR2="N/A"
        if [[ "$F_SIZE2" =~ ^[0-9]+$ ]]; then
            KB2=$((F_SIZE2/1024))
            if [[ $KB2 -gt 1024 ]]; then
                MB_INT2=$(( KB2 / 1024 ))
                MB_DEC2=$(( (KB2 % 1024) * 10 / 1024 ))
                SZ2="${MB_INT2}.${MB_DEC2} MB"
            else
                SZ2="${KB2} KB"
            fi
        else
            SZ2="N/A"
        fi
        INFO_ROWS+=("TRUE" "$BNAME" "${F_COD2:-N/A}" "$DUR2" "$SZ2")
    done

    # Paso 2: checklist para confirmar/deseleccionar archivos
    SELECTED_FILES_RAW=$(yad --list \
        --title="🎵 Paso 2 — Confirmar Archivos (${FILE_COUNT} archivos)" \
        --text="<b>Confirma los archivos a convertir:</b>\n<i>Desmarca los que no quieras incluir</i>" \
        --checklist \
        --column="✔" \
        --column="Nombre" \
        --column="Códec" \
        --column="Duración" \
        --column="Tamaño" \
        "${INFO_ROWS[@]}" \
        --print-column=2 \
        --width=820 --height=460 \
        --button="gtk-cancel:1" \
        --button="☑  Todas:2" \
        --button="Continuar ▶:0" 2>/dev/null)

    BTN_FILES=$?
    [[ $BTN_FILES -eq 1 ]] && exit 0

    if [[ $BTN_FILES -eq 2 ]]; then
        FINAL_FILES=("${INPUT_FILES[@]}")
    else
        FINAL_FILES=()
        while IFS= read -r sel_name; do
            sel_name="${sel_name//|/}"              # strip pipes
            sel_name="${sel_name#"${sel_name%%[![:space:]]*}"}"
            sel_name="${sel_name%"${sel_name##*[![:space:]]}"}"
            [[ -z "$sel_name" ]] && continue
            for orig in "${INPUT_FILES[@]}"; do
                if [[ "$(basename "$orig")" == "$sel_name" ]]; then
                    FINAL_FILES+=("$orig")
                    break
                fi
            done
        done <<< "$SELECTED_FILES_RAW"
    fi

    if [[ ${#FINAL_FILES[@]} -eq 0 ]]; then
        yad --warning --title="Sin archivos" \
            --text="No seleccionaste ningún archivo." \
            --width=360 --button="OK:0" 2>/dev/null
        exit 0
    fi

    INPUT_FILES=("${FINAL_FILES[@]}")
    FILE_COUNT=${#INPUT_FILES[@]}

    select_format  || exit 0
    select_quality || exit 0
    select_output_dir || exit 0

    CONVERTED=0; FAILED=0; CONVERTED_FILES=()
    for INPUT_FILE in "${INPUT_FILES[@]}"; do
        BASENAME=$(basename "$INPUT_FILE")
        FNAME="${BASENAME%.*}"
        OUTPUT_FILE="$OUTPUT_DIR/$FNAME.$FORMAT"
        if [[ -f "$OUTPUT_FILE" ]]; then
            resolve_conflict "$OUTPUT_FILE" "$FNAME" "$FORMAT" "$OUTPUT_DIR"
            [[ "$SKIP_FILE" == "true" ]] && continue
        fi
        convert_file "$INPUT_FILE" "$OUTPUT_FILE"
        CONV_RESULT=$?
        [[ $CONV_RESULT -eq 2 ]] && exit 0
        if [[ $CONV_RESULT -eq 0 ]]; then
            ((CONVERTED++)); CONVERTED_FILES+=("$OUTPUT_FILE")
            echo "$(date '+%Y-%m-%d %H:%M')  |  $BASENAME  →  $(basename "$OUTPUT_FILE")  |  ${BITRATE_OPT:-lossless}  |  $OUTPUT_DIR" >> "$HISTORY_FILE"
        else
            ((FAILED++)); rm -f "$OUTPUT_FILE"
        fi
    done
    show_final_dialog "$CONVERTED" "$FAILED" "$FILE_COUNT" "${CONVERTED_FILES[@]}"

# ════════════════════════════════════════════════════════════════
#  MODO B — CD DE AUDIO
# ════════════════════════════════════════════════════════════════
elif [[ "$MODE" == *"CD de audio"* ]]; then

    # ── Detectar dispositivo CD ──────────────────────────────────
    CD_DEV=""
    for dev in /dev/cdrom /dev/sr0 /dev/sr1 /dev/dvd; do
        [[ -b "$dev" ]] && CD_DEV="$dev" && break
    done

    if [[ -z "$CD_DEV" ]]; then
        yad --error \
            --title="CD no encontrado" \
            --text="<b>❌ No se detectó ningún dispositivo de CD.</b>\n\nVerifica que:\n  • El CD está insertado\n  • El dispositivo existe en /dev/cdrom o /dev/sr0" \
            --width=440 --button="OK:0" 2>/dev/null
        exit 1
    fi

    # ── Leer TOC y disc-id ───────────────────────────────────────
    yad --progress \
        --title="💿 Leyendo CD..." \
        --text="<b>Leyendo tabla de contenidos del disco...</b>" \
        --pulsate --auto-close --no-buttons --width=420 2>/dev/null &
    PULSE_PID=$!

    DISC_ID=$(cd-discid "$CD_DEV" 2>/dev/null)
    CD_INFO=$(cdparanoia -Q -d "$CD_DEV" 2>&1)

    kill "$PULSE_PID" 2>/dev/null; wait "$PULSE_PID" 2>/dev/null

    if [[ -z "$DISC_ID" ]]; then
        yad --error \
            --title="Error al leer CD" \
            --text="<b>❌ No se pudo leer el CD.</b>\n\nVerifica que es un CD de audio válido." \
            --width=420 --button="OK:0" 2>/dev/null
        exit 1
    fi

    # ── Parsear pistas del TOC ───────────────────────────────────
    # Formato real de cdparanoia -Q:
    #   1.    16374 [03:38.24]        0 [00:00.00]    no   no  2
    # Capturamos: número de pista y duración [MM:SS.FF]
    declare -a TRACKS_DATA
    declare -A TRACK_DUR_STR

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]+([0-9]+)\.[[:space:]]+[0-9]+[[:space:]]+\[([0-9]+):([0-9]+)\.[0-9]+\] ]]; then
            TNUM="${BASH_REMATCH[1]}"
            T_MIN="${BASH_REMATCH[2]}"
            T_SEC="${BASH_REMATCH[3]}"
            T_DUR="${T_MIN}:${T_SEC}"
            TRACK_DUR_STR[$TNUM]="$T_DUR"
            TRACKS_DATA+=("$TNUM" "$T_DUR")
        fi
    done <<< "$CD_INFO"

    if [[ ${#TRACKS_DATA[@]} -eq 0 ]]; then
        yad --error --title="Error" \
            --text="<b>❌ No se pudieron leer las pistas del CD.</b>" \
            --width=480 --button="OK:0" 2>/dev/null
        exit 1
    fi

    # ── Consultar gnudb (protocolo freedb) ──────────────────────
    yad --progress \
        --title="💿 Buscando metadata..." \
        --text="<b>Consultando gnudb.gnudb.org...</b>\n<i>Buscando artista, álbum y nombres de pistas</i>" \
        --pulsate --auto-close --no-buttons --width=440 2>/dev/null &
    PULSE_PID=$!

    # cd-discid devuelve: DISCID TRACKS OFF1 OFF2 ... TOTAL_SECS
    DISC_ID_PARTS=($DISC_ID)
    DISCID_HEX="${DISC_ID_PARTS[0]}"
    NUM_TRACKS_ID="${DISC_ID_PARTS[1]}"
    OFFSETS=("${DISC_ID_PARTS[@]:2:$NUM_TRACKS_ID}")
    TOTAL_SECS="${DISC_ID_PARTS[-1]}"
    OFFSETS_QUERY=$(IFS=+; echo "${OFFSETS[*]}")

    GNUDB_QUERY="cmd=cddb+query+${DISCID_HEX}+${NUM_TRACKS_ID}+${OFFSETS_QUERY}+${TOTAL_SECS}"
    GNUDB_HELLO="hello=user+localhost+AudioConverterV3+1.0"
    GNUDB_URL="http://gnudb.gnudb.org/~cddb/cddb.cgi?${GNUDB_QUERY}&${GNUDB_HELLO}&proto=6"
    GNUDB_RESULT=$(curl -s --max-time 10 "$GNUDB_URL" 2>/dev/null)

    ARTIST="Desconocido"
    ALBUM="CD de Audio"
    YEAR=""
    declare -A TRACK_NAMES
    META_SOURCE="<span foreground='#FF9800'>⚠ Metadata no encontrada — usando nombres genéricos</span>"

    if [[ -n "$GNUDB_RESULT" ]]; then
        RESP_CODE=$(echo "$GNUDB_RESULT" | head -1 | awk '{print $1}')

        if [[ "$RESP_CODE" == "200" || "$RESP_CODE" == "210" || "$RESP_CODE" == "211" ]]; then
            if [[ "$RESP_CODE" == "200" ]]; then
                CDDB_CAT=$(echo "$GNUDB_RESULT" | head -1 | awk '{print $2}')
                CDDB_ID=$(echo  "$GNUDB_RESULT" | head -1 | awk '{print $3}')
            else
                CDDB_CAT=$(echo "$GNUDB_RESULT" | sed -n '2p' | awk '{print $1}')
                CDDB_ID=$(echo  "$GNUDB_RESULT" | sed -n '2p' | awk '{print $2}')
            fi

            READ_URL="http://gnudb.gnudb.org/~cddb/cddb.cgi?cmd=cddb+read+${CDDB_CAT}+${CDDB_ID}&${GNUDB_HELLO}&proto=6"
            CDDB_ENTRY=$(curl -s --max-time 10 "$READ_URL" 2>/dev/null)

            if [[ -n "$CDDB_ENTRY" ]]; then
                DTITLE=$(echo "$CDDB_ENTRY" | grep "^DTITLE=" | head -1 | cut -d= -f2-)
                DYEAR=$( echo "$CDDB_ENTRY" | grep "^DYEAR="  | head -1 | cut -d= -f2-)

                if [[ "$DTITLE" == *" / "* ]]; then
                    ARTIST=$(echo "$DTITLE" | sed 's/ \/ .*//')
                    ALBUM=$( echo "$DTITLE" | sed 's/.*\/ //')
                else
                    ALBUM="$DTITLE"
                fi
                [[ -n "$DYEAR" ]] && YEAR="$DYEAR"

                while IFS= read -r line; do
                    if [[ "$line" =~ ^TTITLE([0-9]+)=(.+)$ ]]; then
                        IDX="${BASH_REMATCH[1]}"
                        NAME="${BASH_REMATCH[2]}"
                        TRACK_NAMES[$((IDX+1))]="$NAME"
                    fi
                done <<< "$CDDB_ENTRY"

                META_SOURCE="<span foreground='#4CAF50'>✔ Metadata encontrada en gnudb</span>"
            fi
        fi
    fi

    kill "$PULSE_PID" 2>/dev/null; wait "$PULSE_PID" 2>/dev/null

    # ── Construir lista de pistas para checklist ─────────────────
    declare -a TRACKS_LIST
    for (( i=0; i<${#TRACKS_DATA[@]}; i+=2 )); do
        TNUM="${TRACKS_DATA[$i]}"
        T_DUR="${TRACKS_DATA[$((i+1))]}"
        TNAME="${TRACK_NAMES[$TNUM]:-Pista $TNUM}"
        TRACKS_LIST+=("TRUE" "$TNUM" "$TNAME" "$T_DUR")
    done

    YEAR_STR=""; [[ -n "$YEAR" ]] && YEAR_STR=" ($YEAR)"

    SELECTED_RAW=$(yad --list \
        --title="💿 CD de Audio — Seleccionar Pistas" \
        --text="<b>Álbum:</b>  $ALBUM$YEAR_STR\n<b>Artista:</b>  $ARTIST\n$META_SOURCE\n\n<i>Selecciona las pistas que deseas ripear:</i>" \
        --checklist \
        --column="✔" \
        --column="Núm" \
        --column="Título" \
        --column="Duración" \
        "${TRACKS_LIST[@]}" \
        --print-column=2 \
        --width=620 --height=520 \
        --button="gtk-cancel:1" \
        --button="☑  Todas:2" \
        --button="Siguiente ▶:0" 2>/dev/null)

    BTN_TRACKS=$?
    [[ $BTN_TRACKS -eq 1 ]] && exit 0

    if [[ $BTN_TRACKS -eq 2 ]]; then
        SEL_TRACKS=()
        for (( i=0; i<${#TRACKS_DATA[@]}; i+=2 )); do
            SEL_TRACKS+=("${TRACKS_DATA[$i]}")
        done
    else
        # SELECTED_RAW tiene formato "1|\n2|\n3|..." — normalizar y parsear
        SEL_TRACKS=()
        while IFS= read -r t; do
            t="${t//|/}"
            t="${t#"${t%%[![:space:]]*}"}"
            [[ -n "$t" ]] && SEL_TRACKS+=("$t")
        done <<< "$SELECTED_RAW"
    fi

    if [[ ${#SEL_TRACKS[@]} -eq 0 ]]; then
        yad --warning --title="Sin selección" \
            --text="No seleccionaste ninguna pista." \
            --width=360 --button="OK:0" 2>/dev/null
        exit 0
    fi

    # ── Seleccionar velocidad de ripeado ────────────────────────
    RIP_SPEED_RAW=$(yad --list \
        --title="💿 CD de Audio — Velocidad de Ripeado" \
        --text="<b>Selecciona la velocidad de ripeado:</b>\n<i>Para CDs en buen estado, Rápido es suficiente.\nUsa Paranoid solo si el CD tiene rayaduras.</i>" \
        --column="Modo" \
        --column="Velocidad estimada" \
        --column="Descripción" \
        "Rápido"    "5-10x más rápido"  "Sin corrección — ideal para CDs limpios  ✦" \
        "Normal"    "2-3x más rápido"   "Corrección básica de errores" \
        "Paranoid"  "Tiempo real"       "Máxima corrección — para CDs rayados" \
        --width=580 --height=280 \
        --print-column=1 \
        --button="gtk-cancel:1" \
        --button="Siguiente ▶:0" 2>/dev/null)
    [[ $? -ne 0 || -z "$RIP_SPEED_RAW" ]] && exit 0
    RIP_SPEED=$(echo "$RIP_SPEED_RAW" | tr -d '|' | xargs)
    case "$RIP_SPEED" in
        "Rápido")   CDPARA_FLAGS="-Z" ;;
        "Normal")   CDPARA_FLAGS="-z" ;;
        "Paranoid") CDPARA_FLAGS=""   ;;
        *)          CDPARA_FLAGS="-Z" ;;
    esac

    select_format  || exit 0
    select_quality || exit 0
    select_output_dir || exit 0

    SAFE_ALBUM=$(echo "$ALBUM" | tr '/:*?"<>|\\' '_')
    ALBUM_DIR="$OUTPUT_DIR/$SAFE_ALBUM"
    mkdir -p "$ALBUM_DIR"

    CONVERTED=0; FAILED=0; CONVERTED_FILES=()
    TOTAL_SEL=${#SEL_TRACKS[@]}

    for TNUM in "${SEL_TRACKS[@]}"; do
        TRACK_IDX=$((CONVERTED + FAILED + 1))
        TNAME="${TRACK_NAMES[$TNUM]:-Pista $TNUM}"
        SAFE_TNAME=$(echo "$TNAME" | tr '/:*?"<>|\\' '_')
        TRACK_FILENAME=$(printf "%02d - %s" "$TNUM" "$SAFE_TNAME")
        WAV_FILE="$TEMP_DIR/track${TNUM}.wav"
        OUTPUT_FILE="$ALBUM_DIR/$TRACK_FILENAME.$FORMAT"

        # ── Verificar si el archivo ya existe ───────────────────
        if [[ -f "$OUTPUT_FILE" ]]; then
            resolve_conflict "$OUTPUT_FILE" "$TRACK_FILENAME" "$FORMAT" "$ALBUM_DIR"
            if [[ "$SKIP_FILE" == "true" ]]; then
                continue
            fi
        fi

        # ── Ripear con cdparanoia (barra pulsante + cancelación) ────
        RIP_LOG="$TEMP_DIR/rip_${TNUM}.log"
        RIP_PIPE=$(mktemp -u /tmp/audioconv_RIP_XXXXXX)
        mkfifo "$RIP_PIPE"

        cdparanoia ${CDPARA_FLAGS} -d "$CD_DEV" "$TNUM" "$WAV_FILE" \
            > "$RIP_LOG" 2>&1 &
        CDPARA_PID=$!

        # Feeder: manda pulsos mientras cdparanoia vive, luego 100 para auto-close
        (
            while kill -0 "$CDPARA_PID" 2>/dev/null; do
                echo "1"
                sleep 0.5
            done
            echo "100"
        ) > "$RIP_PIPE" &
        FEEDER_PID=$!

        yad --progress \
            --title="💿 Ripeando pista $TRACK_IDX de $TOTAL_SEL..." \
            --text="<b>Ripeando del CD:</b>  Pista $TNUM — <i>$TNAME</i>\n  <b>Álbum:</b>  $ALBUM\n  <b>Artista:</b>  $ARTIST\n\n  <i>Esto puede tardar unos minutos…</i>" \
            --pulsate \
            --auto-close \
            --width=580 \
            --button="⛔  Cancelar:1" < "$RIP_PIPE" 2>/dev/null
        YAD_RIP=$?

        # Limpiar feeder y pipe
        kill "$FEEDER_PID" 2>/dev/null
        wait "$FEEDER_PID" 2>/dev/null
        rm -f "$RIP_PIPE"

        # Si yad devuelve != 0 el usuario canceló
        if [[ $YAD_RIP -ne 0 ]]; then
            kill "$CDPARA_PID" 2>/dev/null
            wait "$CDPARA_PID" 2>/dev/null
            rm -f "$WAV_FILE" "$RIP_LOG"
            yad --warning \
                --title="Cancelado" \
                --text="<b>⚠ Ripeado cancelado.</b>" \
                --width=380 --button="OK:0" 2>/dev/null
            exit 0
        fi

        wait "$CDPARA_PID"; RIP_EXIT=$?

        if [[ $RIP_EXIT -ne 0 || ! -f "$WAV_FILE" ]]; then
            yad --error \
                --title="Error al ripear" \
                --text="<b>❌ Error al ripear la pista $TNUM.</b>\n\nRevisa que el CD no esté rayado." \
                --width=400 --button="OK:0" 2>/dev/null
            ((FAILED++)); continue
        fi

        # ── Convertir WAV → formato deseado ─────────────────────
        convert_file "$WAV_FILE" "$OUTPUT_FILE" \
            "  <b>Álbum:</b>  $ALBUM  —  Pista $TNUM / $TOTAL_SEL"
        CONV_RESULT=$?
        rm -f "$WAV_FILE"
        [[ $CONV_RESULT -eq 2 ]] && exit 0

        # ── Incrustar metadata ───────────────────────────────────
        if [[ $CONV_RESULT -eq 0 ]]; then
            TMP_META="$TEMP_DIR/meta_${TNUM}.$FORMAT"
            META_ARGS=(-metadata title="$TNAME"
                       -metadata artist="$ARTIST"
                       -metadata album="$ALBUM"
                       -metadata track="$TNUM")
            [[ -n "$YEAR" ]] && META_ARGS+=(-metadata date="$YEAR")
            ffmpeg -y -i "$OUTPUT_FILE" "${META_ARGS[@]}" -codec copy \
                   "$TMP_META" >/dev/null 2>&1 \
                && mv "$TMP_META" "$OUTPUT_FILE" \
                || rm -f "$TMP_META"

            ((CONVERTED++))
            CONVERTED_FILES+=("$OUTPUT_FILE")
            echo "$(date '+%Y-%m-%d %H:%M')  |  CD: $ALBUM — $TNAME  →  $TRACK_FILENAME.$FORMAT  |  ${BITRATE_OPT:-lossless}  |  $ALBUM_DIR" >> "$HISTORY_FILE"
        else
            ((FAILED++))
            rm -f "$OUTPUT_FILE"
        fi
    done

    OUTPUT_DIR="$ALBUM_DIR"
    show_final_dialog "$CONVERTED" "$FAILED" "$TOTAL_SEL" "${CONVERTED_FILES[@]}"
    # Expulsar el CD al terminar
    eject "$CD_DEV" 2>/dev/null

fi

exit 0
