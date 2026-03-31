#!/bin/bash
# ════════════════════════════════════════════════════════════════
#  Audio Converter v1 — YAD + FFmpeg/FFprobe
#  Convierte archivos de audio locales en lote
#  Requiere: yad, ffmpeg, ffprobe, numfmt (coreutils)
# ════════════════════════════════════════════════════════════════

CONFIG_DIR="$HOME/.config/audio_converter"
CONFIG_FILE="$CONFIG_DIR/settings.conf"
HISTORY_FILE="$CONFIG_DIR/history.log"
TEMP_DIR=$(mktemp -d /tmp/audioconv_XXXXXX)
mkdir -p "$CONFIG_DIR"

# ════════════════════════════════════════════════════════════════
#  FUNCIÓN DE LIMPIEZA Y TRAP
# ════════════════════════════════════════════════════════════════
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM

# ════════════════════════════════════════════════════════════════
#  VERIFICACIÓN DE DEPENDENCIAS
# ════════════════════════════════════════════════════════════════
MISSING_DEPS=()
for dep in yad ffmpeg ffprobe; do
    command -v "$dep" &>/dev/null || MISSING_DEPS+=("$dep")
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    MSG="<b>❌ Faltan dependencias necesarias:</b>\n\n"
    for d in "${MISSING_DEPS[@]}"; do
        MSG+="  • $d\n"
    done
    MSG+="\n<i>Instálalas antes de continuar.</i>"
    yad --error --title="Dependencias faltantes" --text="$MSG" \
        --width=420 --button="OK:0" 2>/dev/null
    exit 1
fi

# ─── Cargar última carpeta usada ─────────────────────────────────
LAST_DIR="$HOME"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ════════════════════════════════════════════════════════════════
#  FUNCIÓN: Limpiar nombres para uso seguro en sistema de archivos
# ════════════════════════════════════════════════════════════════
clean_filename() {
    echo "$1" | sed 's/[/:*?"<>|\\]/-/g'
}

# ════════════════════════════════════════════════════════════════
#  FUNCIÓN: Resolver conflictos de nombre de archivo
# ════════════════════════════════════════════════════════════════
SKIP_FILE=false
resolve_conflict() {
    local EXISTING="$1"
    local FNAME="$2"
    local FMT="$3"
    local DIR="$4"
    SKIP_FILE=false

    ACTION=$(yad --list \
        --title="⚠ Archivo ya existe" \
        --text="<b>El archivo ya existe:</b>\n\n  <i>$(basename "$EXISTING")</i>\n\n<b>¿Qué deseas hacer?</b>" \
        --column="Acción" \
        --column="Descripción" \
        "Reemplazar" "Sobreescribir el archivo existente" \
        "Renombrar"  "Guardar con nombre alternativo" \
        "Omitir"     "No convertir este archivo" \
        --print-column=1 \
        --width=500 --height=260 \
        --button="Confirmar:0" 2>/dev/null | tr -d '|' | xargs)

    case "$ACTION" in
        Reemplazar)
            # Sin cambios, OUTPUT_FILE sigue igual
            ;;
        Renombrar)
            local COUNTER=1
            while [[ -f "$DIR/${FNAME}_${COUNTER}.$FMT" ]]; do
                ((COUNTER++))
            done
            OUTPUT_FILE="$DIR/${FNAME}_${COUNTER}.$FMT"
            ;;
        Omitir|"")
            SKIP_FILE=true
            ;;
    esac
}

# ════════════════════════════════════════════════════════════════
#  FUNCIÓN: Convertir un archivo con barra de progreso real
# ════════════════════════════════════════════════════════════════
convert_file() {
    local INPUT_FILE="$1"
    local OUTPUT_FILE="$2"
    local FILE_NUM="$3"
    local FILE_COUNT="$4"

    local BASENAME
    BASENAME=$(basename "$INPUT_FILE")

    # Obtener duración para calcular porcentaje
    local RAW_DUR
    RAW_DUR=$(ffprobe -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$INPUT_FILE" 2>/dev/null)
    local DUR_INT="${RAW_DUR%.*}"
    [[ -z "$DUR_INT" || ! "$DUR_INT" =~ ^[0-9]+$ || "$DUR_INT" -le 0 ]] && DUR_INT=0

    local PIPE
    PIPE=$(mktemp -u "$TEMP_DIR/pipe_XXXXXX")
    mkfifo "$PIPE"

    # Lanzar ffmpeg en background
    local QUALITY_LABEL="$FORMAT"
    [[ -n "$BITRATE_OPT" ]] && QUALITY_LABEL="$FORMAT @ $BITRATE_OPT"

    # Construir flags opcionales
    local EXTRA_FLAGS=()
    [[ -n "$SAMPLE_RATE" ]] && EXTRA_FLAGS+=(-ar "$SAMPLE_RATE")
    [[ -n "$BIT_DEPTH" && "$IS_LOSSLESS" == "true" ]] && EXTRA_FLAGS+=(-sample_fmt "$BIT_DEPTH")

    if [[ "$IS_LOSSLESS" == "true" ]]; then
        ffmpeg -hide_banner -loglevel error -y -threads auto \
               -i "$INPUT_FILE" "${EXTRA_FLAGS[@]}" -progress "$PIPE" -nostats \
               "$OUTPUT_FILE" &
    else
        ffmpeg -hide_banner -loglevel error -y -threads auto \
               -i "$INPUT_FILE" -b:a "$BITRATE_OPT" "${EXTRA_FLAGS[@]}" -progress "$PIPE" -nostats \
               "$OUTPUT_FILE" &
    fi
    local FFMPEG_PID=$!

    # Subshell: lee progreso y lo pasa a yad
    (
        local PCT=0
        while IFS= read -r line; do
            if [[ "$line" =~ ^out_time_ms=([0-9]+)$ ]]; then
                local T="${BASH_REMATCH[1]}"
                if [[ $DUR_INT -gt 0 ]]; then
                    PCT=$(( T / (DUR_INT * 10000) ))
                    [[ $PCT -ge 100 ]] && PCT=99
                else
                    PCT=$(( (PCT + 1) % 98 ))
                fi
                echo "$PCT"
            fi
            [[ "$line" == "progress=end" ]] && echo "100" && break
        done < "$PIPE"
    ) | yad --progress \
        --title="🔄 Convirtiendo ($FILE_NUM / $FILE_COUNT)..." \
        --text="<b>Archivo $FILE_NUM de $FILE_COUNT</b>\n\n  <b>Archivo:</b>  <i>$BASENAME</i>\n  <b>Calidad:</b>  $QUALITY_LABEL\n  <b>Destino:</b>  <i>$OUTPUT_DIR</i>" \
        --percentage=0 \
        --auto-close \
        --width=560 \
        --button="⛔  Cancelar:1" 2>/dev/null

    local YAD_EXIT=$?
    rm -f "$PIPE"

    # Cancelación por el usuario
    if [[ $YAD_EXIT -ne 0 ]]; then
        kill "$FFMPEG_PID" 2>/dev/null
        wait "$FFMPEG_PID" 2>/dev/null
        rm -f "$OUTPUT_FILE"
        yad --warning \
            --title="Conversión cancelada" \
            --text="<b>⚠ Conversión cancelada.</b>\n\nEl archivo parcial fue eliminado." \
            --width=420 --button="OK:0" 2>/dev/null
        exit 0
    fi

    wait "$FFMPEG_PID"
    return $?
}

# ════════════════════════════════════════════════════════════════
#  PASO 1 — Seleccionar archivos (soporte multi-archivo)
# ════════════════════════════════════════════════════════════════
INPUT_RAW=$(yad --file \
    --title="🎵 Audio Converter — Seleccionar Archivos" \
    --text="<b>Selecciona uno o varios archivos de audio:</b>\n<i>Mantén Ctrl o Shift para seleccionar varios</i>" \
    --multiple \
    --file-filter="Archivos de Audio|*.mp3 *.aac *.flac *.ogg *.wav *.opus *.wma *.m4a *.aiff *.mp2 *.webm *.mkv" \
    --file-filter="Todos los archivos|*" \
    --width=750 --height=520 \
    --button="gtk-cancel:1" \
    --button="Siguiente ▶:0" 2>/dev/null)

[[ $? -ne 0 || -z "$INPUT_RAW" ]] && exit 0

# Parsear archivos separados por | — igual que v3, robusto con apóstrofes y caracteres especiales
IFS='|' read -ra RAW_LIST <<< "$INPUT_RAW"
INPUT_FILES=()
for f in "${RAW_LIST[@]}"; do
    f="${f#"${f%%[![:space:]]*}"}"   # trim leading spaces
    f="${f%"${f##*[![:space:]]}"}"   # trim trailing spaces
    [[ -f "$f" ]] && INPUT_FILES+=("$f")
done

if [[ ${#INPUT_FILES[@]} -eq 0 ]]; then
    yad --error --title="Error" \
        --text="No se encontraron archivos válidos." \
        --width=380 --button="OK:0" 2>/dev/null
    exit 1
fi

# ════════════════════════════════════════════════════════════════
#  PASO 2 — Checklist interactivo: confirmar/deseleccionar archivos
# ════════════════════════════════════════════════════════════════
INFO_ROWS=()
for f in "${INPUT_FILES[@]}"; do
    BNAME=$(basename "$f")

    # Extraer info básica con ffprobe
    F_COD2=$(ffprobe -v error -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null | head -1)
    RAW_DUR2=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null)
    F_SIZE2=$(ffprobe -v error -show_entries format=size \
        -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null)

    # Formatear duración
    if [[ -n "$RAW_DUR2" && "$RAW_DUR2" =~ ^[0-9] ]]; then
        DI2=${RAW_DUR2%.*}
        DUR2="$((DI2/60))m $((DI2%60))s"
    else
        DUR2="N/A"
    fi

    # Formatear tamaño con numfmt
    if [[ "$F_SIZE2" =~ ^[0-9]+$ ]]; then
        SZ2=$(numfmt --to=iec --suffix=B "$F_SIZE2" 2>/dev/null || echo "N/A")
    else
        SZ2="N/A"
    fi

    INFO_ROWS+=("TRUE" "$BNAME" "${F_COD2:-N/A}" "$DUR2" "$SZ2")
done

CHECKLIST_OUT=$(yad --list \
    --title="🎵 Audio Converter — Confirmar Archivos" \
    --text="<b>Confirma los archivos a convertir:</b>\n<i>Desmarca los que quieras excluir</i>" \
    --checklist \
    --column="✔" \
    --column="Archivo" \
    --column="Códec" \
    --column="Duración" \
    --column="Tamaño" \
    "${INFO_ROWS[@]}" \
    --print-column=2 \
    --separator="|" \
    --width=720 --height=420 \
    --button="gtk-cancel:1" \
    --button="Continuar ▶:0" 2>/dev/null)

[[ $? -ne 0 || -z "$CHECKLIST_OUT" ]] && exit 0

# Filtrar INPUT_FILES según los seleccionados — igual que v3
FINAL_FILES=()
while IFS= read -r sel_name; do
    sel_name="${sel_name//|/}"
    sel_name="${sel_name#\"${sel_name%%[![:space:]]*}\"}"  # trim leading
    sel_name="${sel_name%\"${sel_name##*[![:space:]]}\"}"  # trim trailing
    [[ -z "$sel_name" ]] && continue
    for orig in "${INPUT_FILES[@]}"; do
        if [[ "$(basename "$orig")" == "$sel_name" ]]; then
            FINAL_FILES+=("$orig")
            break
        fi
    done
done <<< "$CHECKLIST_OUT"

if [[ ${#FINAL_FILES[@]} -eq 0 ]]; then
    yad --info --title="Sin archivos" \
        --text="No se seleccionó ningún archivo." \
        --width=360 --button="OK:0" 2>/dev/null
    exit 0
fi
INPUT_FILES=("${FINAL_FILES[@]}")
FILE_COUNT=${#INPUT_FILES[@]}

# ════════════════════════════════════════════════════════════════
#  PASO 3 — Seleccionar formato de salida
# ════════════════════════════════════════════════════════════════
FORMAT_RAW=$(yad --list \
    --title="🎵 Audio Converter — Formato de Salida" \
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

[[ $? -ne 0 || -z "$FORMAT_RAW" ]] && exit 0
FORMAT=$(echo "$FORMAT_RAW" | tr -d '|' | xargs)

# ════════════════════════════════════════════════════════════════
#  PASO 4 — Seleccionar calidad/bitrate (solo formatos con pérdida)
# ════════════════════════════════════════════════════════════════
BITRATE_OPT=""
IS_LOSSLESS=false
case "$FORMAT" in flac|wav|aiff) IS_LOSSLESS=true ;; esac

if [[ "$IS_LOSSLESS" == "false" ]]; then
    QUALITY_RAW=$(yad --list \
        --title="🎵 Audio Converter — Calidad de Audio" \
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

    [[ $? -ne 0 || -z "$QUALITY_RAW" ]] && exit 0
    BITRATE_OPT=$(echo "$QUALITY_RAW" | tr -d '|' | xargs)
fi

# ════════════════════════════════════════════════════════════════
#  PASO 4b — Seleccionar sample rate (según el formato)
# ════════════════════════════════════════════════════════════════

SR_OPTIONS=()
SR_HINT="<i>44100 Hz es estándar para música. 48000 Hz para video.</i>"

case "$FORMAT" in
    opus)
        SR_HINT="<b>Opus resamplea internamente a un máximo de 48 kHz.</b>"
        SR_OPTIONS=(
            "48000" "48 kHz (Recomendado ✦)" "Estándar Opus"
            "24000" "24 kHz" "Optimizado voz"
            "16000" "16 kHz" "Baja calidad"
            "12000" "12 kHz" "Muy baja"
            "8000"  "8 kHz"  "Telefonía"
        )
        ;;
    mp3)
        SR_HINT="<b>MP3 no soporta frecuencias superiores a 48 kHz.</b>"
        SR_OPTIONS=(
            "48000" "48 kHz ✦" "Calidad Máxima"
            "44100" "44.1 kHz" "CD Estándar"
            "32000" "32 kHz" "Radio FM"
            "24000" "24 kHz" "Voz clara"
            "22050" "22.05 kHz" "Calidad media"
        )
        ;;
    mp2)
        SR_HINT="<b>MP2 solo soporta ciertos valores estándar.</b>"
        SR_OPTIONS=(
            "48000" "48 kHz" "Video"
            "44100" "44.1 kHz ✦" "CD"
            "32000" "32 kHz" "Broadcast"
            "24000" "24 kHz" "Baja"
        )
        ;;
    aac|m4a)
        SR_HINT="<b>AAC soporta hasta 96 kHz (Hi-Res limitado).</b>"
        SR_OPTIONS=(
            "orig"   "Sin cambios ✦" "Mantener original"
            "96000"  "96 kHz" "Hi-Res AAC"
            "48000"  "48 kHz" "Video HD"
            "44100"  "44.1 kHz" "CD estándar"
        )
        ;;
    flac|wav|aiff)
        SR_HINT="<b>Formatos sin pérdida: Soportan alta resolución real.</b>"
        SR_OPTIONS=(
            "orig"   "Sin cambios ✦" "Mantener original"
            "192000" "192 kHz" "Mastering / Audiófilo"
            "96000"  "96 kHz" "Estudio / Hi-Res"
            "88200"  "88.2 kHz" "Multiplo CD"
            "48000"  "48 kHz" "Estándar Pro"
            "44100"  "44.1 kHz" "Estándar CD"
        )
        ;;
    *)
        SR_OPTIONS=(
            "orig"   "Sin cambios ✦" "Mantener original"
            "48000"  "48 kHz" "Video / Streaming"
            "44100"  "44.1 kHz" "CD estándar"
        )
        ;;
esac

SR_RAW=$(yad --list \
    --title="🎵 Audio Converter — Sample Rate" \
    --text="<b>Selecciona el sample rate para $FORMAT:</b>\n$SR_HINT" \
    --column="Hz" \
    --column="Nombre" \
    --column="Uso típico" \
    "${SR_OPTIONS[@]}" \
    --width=540 --height=400 \
    --print-column=1 \
    --button="gtk-cancel:1" \
    --button="Siguiente ▶:0" 2>/dev/null)

[[ $? -ne 0 || -z "$SR_RAW" ]] && exit 0
SR_VAL=$(echo "$SR_RAW" | tr -d '|' | xargs)
[[ "$SR_VAL" != "orig" ]] && SAMPLE_RATE="$SR_VAL"

# ════════════════════════════════════════════════════════════════
#  PASO 4c — Seleccionar bit depth (solo formatos sin pérdida)
# ════════════════════════════════════════════════════════════════
BIT_DEPTH=""
if [[ "$IS_LOSSLESS" == "true" ]]; then
    BD_RAW=$(yad --list \
        --title="🎵 Audio Converter — Bit Depth" \
        --text="<b>Selecciona la profundidad de bits:</b>\n<i>Solo aplica a formatos sin pérdida (FLAC, WAV, AIFF).</i>" \
        --column="Formato ffmpeg" \
        --column="Bit Depth" \
        --column="Descripción" \
        "orig" "Sin cambios ✦"  "Mantener la profundidad de bits original" \
        "s16"  "16-bit"         "Estándar CD — compatible con todo" \
        "s32"  "24-bit (s32)"   "Alta resolución — producción y masterización" \
        "s64"  "32-bit float"   "Máxima precisión — edición profesional" \
        --width=540 --height=340 \
        --print-column=1 \
        --button="gtk-cancel:1" \
        --button="Siguiente ▶:0" 2>/dev/null)

    [[ $? -ne 0 || -z "$BD_RAW" ]] && exit 0
    BD_VAL=$(echo "$BD_RAW" | tr -d '|' | xargs)
    [[ "$BD_VAL" != "orig" ]] && BIT_DEPTH="$BD_VAL"
fi

# ════════════════════════════════════════════════════════════════
#  PASO 5 — Seleccionar carpeta de destino (recuerda la última)
# ════════════════════════════════════════════════════════════════
OUTPUT_DIR=$(yad --file \
    --title="🎵 Audio Converter — Carpeta de Destino" \
    --text="<b>Selecciona la carpeta donde se guardarán los archivos convertidos:</b>" \
    --directory \
    --filename="$LAST_DIR/" \
    --width=750 --height=520 \
    --button="gtk-cancel:1" \
    --button="Confirmar ✔:0" 2>/dev/null)

[[ $? -ne 0 || -z "$OUTPUT_DIR" ]] && exit 0

# Guardar carpeta en configuración para la próxima vez
echo "LAST_DIR=\"$OUTPUT_DIR\"" > "$CONFIG_FILE"

# ════════════════════════════════════════════════════════════════
#  CONVERSIÓN — Procesar cada archivo
# ════════════════════════════════════════════════════════════════
CONVERTED=0
FAILED=0
CONVERTED_FILES=()
FILE_NUM=0

for INPUT_FILE in "${INPUT_FILES[@]}"; do
    ((FILE_NUM++))

    BASENAME=$(basename "$INPUT_FILE")
    FILENAME="${BASENAME%.*}"
    SAFE_NAME=$(clean_filename "$FILENAME")
    OUTPUT_FILE="$OUTPUT_DIR/$SAFE_NAME.$FORMAT"

    # Resolver conflicto si el archivo ya existe
    if [[ -f "$OUTPUT_FILE" ]]; then
        resolve_conflict "$OUTPUT_FILE" "$SAFE_NAME" "$FORMAT" "$OUTPUT_DIR"
        $SKIP_FILE && { ((FAILED++)); continue; }
    fi

    convert_file "$INPUT_FILE" "$OUTPUT_FILE" "$FILE_NUM" "$FILE_COUNT"
    CONV_RESULT=$?

    if [[ $CONV_RESULT -eq 0 ]]; then
        ((CONVERTED++))
        CONVERTED_FILES+=("$OUTPUT_FILE")
        QUALITY_LABEL="$FORMAT"
        [[ -n "$BITRATE_OPT" ]] && QUALITY_LABEL="$FORMAT @ $BITRATE_OPT"
        echo "$(date '+%Y-%m-%d %H:%M')  |  $BASENAME  →  $(basename "$OUTPUT_FILE")  |  $QUALITY_LABEL  |  $OUTPUT_DIR" \
            >> "$HISTORY_FILE"
    else
        ((FAILED++))
        rm -f "$OUTPUT_FILE"
    fi

done

# ════════════════════════════════════════════════════════════════
#  DIALOG FINAL — Resumen de completado
# ════════════════════════════════════════════════════════════════
QUALITY_LABEL="$FORMAT"
[[ -n "$BITRATE_OPT" ]] && QUALITY_LABEL="$FORMAT @ $BITRATE_OPT"
[[ -n "$SAMPLE_RATE" ]] && QUALITY_LABEL+="  ${SAMPLE_RATE}Hz"
[[ -n "$BIT_DEPTH"   ]] && QUALITY_LABEL+="  ${BIT_DEPTH}"

DONE_TEXT="<b><span foreground='#4CAF50' size='large'>✅  ¡Proceso completado!</span></b>\n\n"
DONE_TEXT+="  <b>Convertidos:</b>  $CONVERTED de $FILE_COUNT\n"
[[ $FAILED -gt 0 ]] && \
    DONE_TEXT+="  <b><span foreground='#F44336'>Omitidos/Fallidos:</span></b>  $FAILED\n"
DONE_TEXT+="  <b>Formato:</b>  $QUALITY_LABEL\n"
DONE_TEXT+="  <b>Ubicación:</b>  $OUTPUT_DIR\n\n"

if [[ ${#CONVERTED_FILES[@]} -gt 0 ]]; then
    DONE_TEXT+="<b>Archivos generados:</b>\n"
    LIMIT=$(( ${#CONVERTED_FILES[@]} < 8 ? ${#CONVERTED_FILES[@]} : 8 ))
    for (( i=0; i<LIMIT; i++ )); do
        CF="${CONVERTED_FILES[$i]}"
        FSIZE=$(du -sh "$CF" 2>/dev/null | cut -f1)
        DONE_TEXT+="  📄 $(basename "$CF")  <i>($FSIZE)</i>\n"
    done
    [[ ${#CONVERTED_FILES[@]} -gt 8 ]] && \
        DONE_TEXT+="  … y $((${#CONVERTED_FILES[@]}-8)) archivo(s) más\n"
fi

yad --info \
    --title="✅ Conversión completada" \
    --text="$DONE_TEXT" \
    --width=580 --height=360 \
    --button="🕑  Historial:3" \
    --button="📂  Abrir carpeta:2" \
    --button="gtk-ok:0" 2>/dev/null

BTN=$?
[[ $BTN -eq 2 ]] && xdg-open "$OUTPUT_DIR" &
if [[ $BTN -eq 3 ]]; then
    yad --text-info \
        --title="🕑 Historial de conversiones" \
        --filename="$HISTORY_FILE" \
        --width=760 --height=440 \
        --tail \
        --button="🗑  Borrar historial:2" \
        --button="gtk-ok:0" 2>/dev/null
    [[ $? -eq 2 ]] && > "$HISTORY_FILE"
fi

exit 0
