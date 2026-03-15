#!/bin/bash
# ════════════════════════════════════════════════════════════════
#  Audio Converter v2 — YAD + FFmpeg/FFprobe
#  Mejoras: lote, calidad/bitrate, historial, vista previa info
#  Requiere: yad, ffmpeg, ffprobe, bc, xdg-open
# ════════════════════════════════════════════════════════════════

CONFIG_DIR="$HOME/.config/audio_converter"
CONFIG_FILE="$CONFIG_DIR/settings.conf"
HISTORY_FILE="$CONFIG_DIR/history.log"
mkdir -p "$CONFIG_DIR"

# ─── Cargar última carpeta usada ─────────────────────────────────
LAST_DIR="$HOME"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ════════════════════════════════════════════════════════════════
#  PASO 1 — Seleccionar archivos (soporte multi-archivo)
# ════════════════════════════════════════════════════════════════
INPUT_RAW=$(yad --file \
    --title="🎵 Audio Converter v2 — Paso 1/5: Seleccionar Archivos" \
    --text="<b>Selecciona uno o varios archivos de audio:</b>\n<i>Mantén Ctrl o Shift para seleccionar varios</i>" \
    --multiple \
    --file-filter="Archivos de Audio|*.mp3 *.aac *.flac *.ogg *.wav *.opus *.wma *.m4a *.aiff *.mp2 *.webm *.mkv" \
    --file-filter="Todos los archivos|*" \
    --width=750 --height=520 \
    --button="gtk-cancel:1" \
    --button="Siguiente ▶:0" 2>/dev/null)

[[ $? -ne 0 || -z "$INPUT_RAW" ]] && exit 0

# Parsear archivos separados por | y validar que existen
IFS='|' read -ra RAW_LIST <<< "$INPUT_RAW"
INPUT_FILES=()
for f in "${RAW_LIST[@]}"; do
    f=$(echo "$f" | xargs)
    [[ -f "$f" ]] && INPUT_FILES+=("$f")
done

if [[ ${#INPUT_FILES[@]} -eq 0 ]]; then
    yad --error --title="Error" \
        --text="No se encontraron archivos válidos." \
        --width=380 --button="OK:0" 2>/dev/null
    exit 1
fi
FILE_COUNT=${#INPUT_FILES[@]}

# ════════════════════════════════════════════════════════════════
#  PASO 2 — Vista previa: info de archivos con ffprobe
# ════════════════════════════════════════════════════════════════
INFO_TEXT="<b>Archivos seleccionados: $FILE_COUNT</b>\n\n"

for f in "${INPUT_FILES[@]}"; do
    FNAME=$(basename "$f")

    # Extraer metadatos con ffprobe
    RAW=$(ffprobe -v error \
        -show_entries format=duration,bit_rate,size \
        -show_entries stream=codec_name,sample_rate,channels \
        -of default=noprint_wrappers=1 "$f" 2>/dev/null)

    F_DUR=$(  echo "$RAW" | grep "^duration="   | head -1 | cut -d= -f2)
    F_BR=$(   echo "$RAW" | grep "^bit_rate="   | head -1 | cut -d= -f2)
    F_CODEC=$(echo "$RAW" | grep "^codec_name=" | head -1 | cut -d= -f2)
    F_SR=$(   echo "$RAW" | grep "^sample_rate="| head -1 | cut -d= -f2)
    F_CH=$(   echo "$RAW" | grep "^channels="   | head -1 | cut -d= -f2)
    F_SIZE=$( echo "$RAW" | grep "^size="       | head -1 | cut -d= -f2)

    # Formatear duración
    if [[ -n "$F_DUR" && "$F_DUR" != "N/A" ]]; then
        DI=${F_DUR%.*}
        DUR_STR="$((DI/60))m $((DI%60))s"
    else
        DUR_STR="N/A"
    fi

    # Formatear bitrate
    if [[ -n "$F_BR" && "$F_BR" =~ ^[0-9]+$ ]]; then
        BR_STR="$((F_BR/1000)) kbps"
    else
        BR_STR="N/A"
    fi

    # Formatear tamaño
    if [[ -n "$F_SIZE" && "$F_SIZE" =~ ^[0-9]+$ ]]; then
        KB=$((F_SIZE/1024))
        if [[ $KB -gt 1024 ]]; then
            MB=$(echo "scale=1; $KB/1024" | bc)
            SIZE_STR="${MB} MB"
        else
            SIZE_STR="${KB} KB"
        fi
    else
        SIZE_STR="N/A"
    fi

    # Canales en texto
    case "$F_CH" in
        1) CH_STR="Mono"   ;;
        2) CH_STR="Estéreo";;
        6) CH_STR="5.1"    ;;
        *) CH_STR="${F_CH}ch" ;;
    esac

    INFO_TEXT+="  📄 <b>$FNAME</b>\n"
    INFO_TEXT+="     Códec: <b>${F_CODEC:-N/A}</b>  |  Duración: <b>$DUR_STR</b>  |  Bitrate: <b>$BR_STR</b>\n"
    INFO_TEXT+="     Sample rate: <b>${F_SR:-N/A} Hz</b>  |  Canales: <b>$CH_STR</b>  |  Tamaño: <b>$SIZE_STR</b>\n\n"
done

yad --info \
    --title="🎵 Audio Converter v2 — Paso 2/5: Info de Archivos" \
    --text="$INFO_TEXT" \
    --width=640 --height=420 \
    --button="gtk-cancel:1" \
    --button="Continuar ▶:0" 2>/dev/null

[[ $? -ne 0 ]] && exit 0

# ════════════════════════════════════════════════════════════════
#  PASO 3 — Seleccionar formato de salida
# ════════════════════════════════════════════════════════════════
FORMAT_RAW=$(yad --list \
    --title="🎵 Audio Converter v2 — Paso 3/5: Formato de Salida" \
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
        --title="🎵 Audio Converter v2 — Paso 4/5: Calidad de Audio" \
        --text="<b>Selecciona la calidad (bitrate) de salida:</b>\n<i>Mayor bitrate → mejor calidad y mayor tamaño de archivo</i>" \
        --column="Bitrate" \
        --column="Calidad" \
        --column="Uso recomendado" \
        "64k"  "Baja"        "Voz, podcasts, audiolibros" \
        "96k"  "Media-baja"  "Radio online, streaming básico" \
        "128k" "Media"       "Música casual, streaming general" \
        "192k" "Alta"        "Música de buena calidad  ✦" \
        "256k" "Muy alta"    "Música de alta fidelidad" \
        "320k" "Máxima"      "Audiófilos, archivos maestros" \
        --width=540 --height=380 \
        --print-column=1 \
        --button="gtk-cancel:1" \
        --button="Siguiente ▶:0" 2>/dev/null)

    [[ $? -ne 0 || -z "$QUALITY_RAW" ]] && exit 0
    BITRATE_OPT=$(echo "$QUALITY_RAW" | tr -d '|' | xargs)
fi

# ════════════════════════════════════════════════════════════════
#  PASO 5 — Seleccionar carpeta de destino (recuerda la última)
# ════════════════════════════════════════════════════════════════
OUTPUT_DIR=$(yad --file \
    --title="🎵 Audio Converter v2 — Paso 5/5: Carpeta de Destino" \
    --text="<b>Selecciona la carpeta donde se guardarán los archivos convertidos:</b>\n<i>Se recuerda la última carpeta usada</i>" \
    --directory \
    --filename="$LAST_DIR/" \
    --width=750 --height=520 \
    --button="gtk-cancel:1" \
    --button="Convertir ✔:0" 2>/dev/null)

[[ $? -ne 0 || -z "$OUTPUT_DIR" ]] && exit 0

# Guardar carpeta en configuración para la próxima vez
echo "LAST_DIR=\"$OUTPUT_DIR\"" > "$CONFIG_FILE"

# ════════════════════════════════════════════════════════════════
#  CONVERSIÓN — Procesar cada archivo
# ════════════════════════════════════════════════════════════════
CONVERTED=0
FAILED=0
CONVERTED_FILES=()

for INPUT_FILE in "${INPUT_FILES[@]}"; do

    BASENAME=$(basename "$INPUT_FILE")
    FILENAME="${BASENAME%.*}"
    OUTPUT_FILE="$OUTPUT_DIR/$FILENAME.$FORMAT"

    # Evitar sobreescribir: añadir sufijo numérico si ya existe
    if [[ -f "$OUTPUT_FILE" ]]; then
        COUNTER=1
        while [[ -f "$OUTPUT_DIR/${FILENAME}_${COUNTER}.$FORMAT" ]]; do
            ((COUNTER++))
        done
        FILENAME="${FILENAME}_${COUNTER}"
        OUTPUT_FILE="$OUTPUT_DIR/$FILENAME.$FORMAT"
    fi

    # Duración para calcular % de progreso
    RAW_DUR=$(ffprobe -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$INPUT_FILE" 2>/dev/null)
    DUR_INT=${RAW_DUR%.*}
    [[ -z "$DUR_INT" || ! "$DUR_INT" =~ ^[0-9]+$ || "$DUR_INT" -le 0 ]] && DUR_INT=0

    PIPE=$(mktemp -u /tmp/audioconv_XXXXXX)
    mkfifo "$PIPE"

    # Lanzar ffmpeg
    if [[ "$IS_LOSSLESS" == "true" ]]; then
        ffmpeg -y -i "$INPUT_FILE" -progress "$PIPE" -nostats \
               "$OUTPUT_FILE" >/dev/null 2>&1 &
    else
        ffmpeg -y -i "$INPUT_FILE" -b:a "$BITRATE_OPT" -progress "$PIPE" -nostats \
               "$OUTPUT_FILE" >/dev/null 2>&1 &
    fi
    FFMPEG_PID=$!

    FILE_NUM=$((CONVERTED + FAILED + 1))
    QUALITY_LABEL="$FORMAT"
    [[ -n "$BITRATE_OPT" ]] && QUALITY_LABEL="$FORMAT @ $BITRATE_OPT"

    # Subshell que calcula % y lo pasa a yad --progress
    (
        PCT=0
        while IFS= read -r line; do
            if [[ "$line" =~ ^out_time_ms=([0-9]+)$ ]]; then
                T="${BASH_REMATCH[1]}"
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
        --title="🔄 Convirtiendo ($FILE_NUM / $FILE_COUNT)..." \
        --text="<b>Archivo $FILE_NUM de $FILE_COUNT</b>\n\n  <b>Archivo:  </b><i>$BASENAME</i>\n  <b>Calidad:  </b>$QUALITY_LABEL\n  <b>Destino:  </b><i>$OUTPUT_DIR</i>" \
        --percentage=0 \
        --auto-close \
        --width=540 \
        --button="⛔  Cancelar conversión:1" 2>/dev/null

    YAD_EXIT=$?
    rm -f "$PIPE"

    # ── Cancelación por el usuario ──────────────────────────────
    if [[ $YAD_EXIT -ne 0 ]]; then
        kill "$FFMPEG_PID" 2>/dev/null
        wait "$FFMPEG_PID" 2>/dev/null
        rm -f "$OUTPUT_FILE"
        yad --warning \
            --title="Conversión cancelada" \
            --text="<b>⚠ Conversión cancelada.</b>\n\nEl archivo parcial fue eliminado:\n<i>$OUTPUT_FILE</i>" \
            --width=440 --button="OK:0" 2>/dev/null
        exit 0
    fi

    wait "$FFMPEG_PID"; FFMPEG_EXIT=$?

    if [[ $FFMPEG_EXIT -eq 0 ]]; then
        ((CONVERTED++))
        CONVERTED_FILES+=("$OUTPUT_FILE")
        # Guardar en historial
        echo "$(date '+%Y-%m-%d %H:%M')  |  $BASENAME  →  $FILENAME.$FORMAT  |  $QUALITY_LABEL  |  $OUTPUT_DIR" \
            >> "$HISTORY_FILE"
    else
        ((FAILED++))
        rm -f "$OUTPUT_FILE"
    fi

done   # fin del bucle de archivos

# ════════════════════════════════════════════════════════════════
#  DIALOG FINAL — Resumen de completado
# ════════════════════════════════════════════════════════════════
DONE_TEXT="<b><span foreground='#4CAF50' size='large'>✅  ¡Proceso completado!</span></b>\n\n"
DONE_TEXT+="  <b>Convertidos:</b>  $CONVERTED de $FILE_COUNT\n"
[[ $FAILED -gt 0 ]] && \
    DONE_TEXT+="  <b><span foreground='#F44336'>Fallidos:</span></b>  $FAILED\n"
DONE_TEXT+="  <b>Formato:</b>  $FORMAT"
[[ -n "$BITRATE_OPT" ]] && DONE_TEXT+=" @ $BITRATE_OPT"
DONE_TEXT+="\n  <b>Ubicación:</b>  $OUTPUT_DIR\n\n"

# Listar archivos generados (máx 8 para no saturar el dialog)
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
    --width=580 --height=340 \
    --button="🕑  Historial:3" \
    --button="📂  Abrir carpeta:2" \
    --button="gtk-ok:0" 2>/dev/null

BTN=$?
[[ $BTN -eq 2 ]] && xdg-open "$OUTPUT_DIR" &
[[ $BTN -eq 3 ]] && yad --text-info \
    --title="🕑 Historial de conversiones" \
    --filename="$HISTORY_FILE" \
    --width=760 --height=440 \
    --tail \
    --button="🗑  Borrar historial:2" \
    --button="gtk-ok:0" 2>/dev/null
# Botón "Borrar historial"
[[ $? -eq 2 ]] && > "$HISTORY_FILE"

exit 0
