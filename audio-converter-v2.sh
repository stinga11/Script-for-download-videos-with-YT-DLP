#!/bin/bash
################################################################################
# Audio Converter V2 — YAD + FFmpeg/FFprobe + Ripeador de CD
#
# Convierte archivos de audio locales en lote con interfaz gráfica interactiva.
# También permite ripear y convertir pistas desde un CD de audio.
#
# REQUISITOS: yad, ffmpeg, ffprobe, numfmt (coreutils)
#             cdparanoia, cd-discid, curl, iconv  (solo para modo CD)
# USO: ./audio-converter-v2.sh
################################################################################

################################################################################
# CONFIGURACIÓN GLOBAL
################################################################################
readonly CONFIG_DIR="$HOME/.config/audio_converter"
readonly CONFIG_FILE="$CONFIG_DIR/settings.conf"
readonly HISTORY_FILE="$CONFIG_DIR/history.log"
readonly TEMP_DIR=$(mktemp -d /tmp/audioconv_XXXXXX)
readonly CACHE_DIR="$CONFIG_DIR/cddb_cache"
WAV_ONLY=false
CD_DEV=""

mkdir -p "$CONFIG_DIR" "$CACHE_DIR"

################################################################################
# MANEJO DE LIMPIEZA Y TRAPS
################################################################################
cleanup() {
    [[ -n "$CD_DEV" ]] && eject "$CD_DEV" 2>/dev/null
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}

trap cleanup EXIT HUP INT TERM

################################################################################
# VERIFICACIÓN DE DEPENDENCIAS
################################################################################
verify_dependencies() {
    local missing_deps=()

    for dep in yad ffmpeg ffprobe numfmt; do
        command -v "$dep" &>/dev/null || missing_deps+=("$dep")
    done

    # cd-discid y cdparanoia solo son necesarios en el modo CD
    for dep in cdparanoia cd-discid; do
        command -v "$dep" &>/dev/null || missing_deps+=("$dep (necesario para ripear CDs)")
    done

    if (( ${#missing_deps[@]} > 0 )); then
        local msg="<b>❌ Faltan dependencias necesarias:</b>\n\n"
        for d in "${missing_deps[@]}"; do
            msg+="  • <b>$d</b>\n"
        done
        msg+="\n<i>Instálalas antes de continuar:</i>\n"
        msg+="  <tt>sudo apt install ${missing_deps[*]}</tt>"

        yad --error \
            --title="⚠️  Dependencias faltantes" \
            --text="$msg" \
            --width=480 \
            --button="Salir:0" 2>/dev/null
        exit 1
    fi
}

################################################################################
# CARGA DE CONFIGURACIÓN PERSISTENTE
################################################################################
load_config() {
    local last_dir="$HOME"
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" 2>/dev/null || true
    echo "$last_dir"
}

################################################################################
# FUNCIÓN: Limpiar caracteres inválidos en nombres de archivo
################################################################################
clean_filename() {
    local filename="$1"
    filename=$(echo "$filename" | sed 's/[/:*?"<>|\\]/-/g')
    filename=$(echo "$filename" | sed 's/--*/-/g')
    filename="${filename#-}"
    filename="${filename%-}"
    echo "$filename"
}

################################################################################
# FUNCIÓN: Resolver conflictos de nombre de archivo duplicado
# Exporta: OUTPUT_FILE (ruta final), SKIP_FILE=true si el usuario omite
################################################################################
resolve_conflict() {
    local existing="$1"
    local fname="$2"
    local fmt="$3"
    local dir="$4"
    SKIP_FILE=false

    local fsize fdate bname
    fsize=$(du -sh "$existing" 2>/dev/null | cut -f1)
    fdate=$(stat -c "%y" "$existing" 2>/dev/null | cut -d. -f1)
    bname=$(basename "$existing")

    local action
    action=$(yad --list \
        --title="⚠️  Archivo ya existe" \
        --text="<b>El archivo ya existe en el sistema:</b>\n\n  📄 <b>$bname</b>\n  Tamaño: <i>$fsize</i>  |  Modificado: <i>$fdate</i>\n\n<b>¿Qué deseas hacer?</b>" \
        --column="Acción" \
        --column="Descripción" \
        "Reemplazar" "Sobreescribir el archivo existente" \
        "Renombrar"  "Guardar con un nombre nuevo automáticamente" \
        "Omitir"     "Saltar este archivo y continuar con el siguiente" \
        --print-column=1 \
        --width=520 --height=260 \
        --no-headers \
        --button="Confirmar:0" 2>/dev/null)

    action=$(echo "$action" | tr -d '|' | xargs)

    case "$action" in
        Reemplazar)
            OUTPUT_FILE="$existing"
            ;;
        Renombrar)
            local c=1
            while [[ -f "$dir/${fname}_${c}.$fmt" ]]; do (( c++ )); done
            OUTPUT_FILE="$dir/${fname}_${c}.$fmt"
            ;;
        *)
            SKIP_FILE=true
            ;;
    esac
}

################################################################################
# PASO 1: SELECCIONAR ARCHIVOS DE AUDIO
################################################################################
select_input_files() {
    local input_raw

    input_raw=$(yad --file \
        --title="🎵 Audio Converter — Seleccionar Archivos" \
        --text="<b>Selecciona uno o más archivos de audio:</b>\n<i>Mantén Ctrl o Shift para múltiple selección</i>" \
        --multiple \
        --file-filter="Archivos de Audio|*.mp3 *.aac *.flac *.ogg *.wav *.opus *.wma *.m4a *.aiff *.mp2 *.webm *.mkv" \
        --file-filter="Todos los archivos|*" \
        --width=780 --height=560 \
        --button="gtk-cancel:1" \
        --button="Siguiente ▶:0" 2>/dev/null)

    (( $? != 0 )) && return 1
    [[ -z "$input_raw" ]] && return 1

    IFS='|' read -ra raw_list <<< "$input_raw"
    INPUT_FILES=()
    for f in "${raw_list[@]}"; do
        f="${f#"${f%%[![:space:]]*}"}"
        f="${f%"${f##*[![:space:]]}"}"
        [[ -f "$f" ]] && INPUT_FILES+=("$f")
    done

    if (( ${#INPUT_FILES[@]} == 0 )); then
        yad --error \
            --title="❌ Error" \
            --text="No se encontraron archivos válidos." \
            --width=380 \
            --button="OK:0" 2>/dev/null
        return 1
    fi

    return 0
}

################################################################################
# PASO 2: CONFIRMAR ARCHIVOS CON INFORMACIÓN
################################################################################
confirm_input_files() {
    local file_count=${#INPUT_FILES[@]}
    local -a info_rows=()

    for f in "${INPUT_FILES[@]}"; do
        local bname
        bname=$(basename "$f")

        local raw
        raw=$(ffprobe -v error \
            -show_entries format=duration,size \
            -show_entries stream=codec_name \
            -of default=noprint_wrappers=1 "$f" 2>/dev/null)

        local dur_raw size_bytes codec
        dur_raw=$(echo "$raw"    | grep "^duration="   | head -1 | cut -d= -f2)
        size_bytes=$(echo "$raw" | grep "^size="        | head -1 | cut -d= -f2)
        codec=$(echo "$raw"      | grep "^codec_name="  | head -1 | cut -d= -f2)

        local di=${dur_raw%.*}
        local dur_str
        [[ "$di" =~ ^[0-9]+$ ]] \
            && dur_str="$(( di / 60 ))m $(( di % 60 ))s" \
            || dur_str="N/A"

        if [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
            size_bytes=$(numfmt --to=iec --suffix=B "$size_bytes" 2>/dev/null || echo "N/A")
        else
            size_bytes="N/A"
        fi

        info_rows+=("TRUE" "$bname" "${codec:-N/A}" "$dur_str" "$size_bytes")
    done

    local selected_raw
    selected_raw=$(yad --list \
        --title="🎵 Audio Converter — Confirmar Archivos ($file_count archivos)" \
        --text="<b>Confirma los archivos a convertir:</b>\n<i>Desmarca los que no quieras incluir.</i>" \
        --checklist \
        --column="✔" \
        --column="Nombre" \
        --column="Códec" \
        --column="Duración" \
        --column="Tamaño" \
        "${info_rows[@]}" \
        --print-column=2 \
        --width=820 --height=460 \
        --button="gtk-cancel:1" \
        --button="☑  Todas:2" \
        --button="Continuar ▶:0" 2>/dev/null)

    local btn=$?
    [[ $btn -ne 0 && $btn -ne 2 ]] && return 1

    if [[ $btn -eq 2 ]]; then
        return 0   # Todas seleccionadas; INPUT_FILES no cambia
    fi

    local -a final_files=()
    while IFS= read -r sel_name; do
        sel_name="${sel_name//|/}"
        sel_name="${sel_name#"${sel_name%%[![:space:]]*}"}"
        sel_name="${sel_name%"${sel_name##*[![:space:]]}"}"
        [[ -z "$sel_name" ]] && continue
        for orig in "${INPUT_FILES[@]}"; do
            if [[ "$(basename "$orig")" == "$sel_name" ]]; then
                final_files+=("$orig")
                break
            fi
        done
    done <<< "$selected_raw"

    if (( ${#final_files[@]} == 0 )); then
        yad --warning \
            --title="Sin archivos" \
            --text="No seleccionaste ningún archivo." \
            --width=360 \
            --button="OK:0" 2>/dev/null
        return 1
    fi

    INPUT_FILES=("${final_files[@]}")
    return 0
}

################################################################################
# PASOS 3-7: SELECCIÓN DE OPCIONES DE CONVERSIÓN
# Exporta: FORMAT, BITRATE_OPT, IS_LOSSLESS, SAMPLE_RATE, BIT_DEPTH, OUTPUT_DIR
# Retorna: 0=Confirmar  1=Cancelar  2=Atrás desde Formato (lo gestiona el llamador)
################################################################################
select_audio_options() {
    local start_step="${1:-3}"
    FORMAT=""
    BITRATE_OPT=""
    IS_LOSSLESS=false
    SAMPLE_RATE=""
    BIT_DEPTH=""
    OUTPUT_DIR=""

    local step=$start_step

    while true; do
        case $step in

        ########################################################################
        # PASO 3: FORMATO DE SALIDA
        ########################################################################
        3)
            local format_raw
            format_raw=$(yad --list \
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
                --button="◀ Atrás:2" \
                --button="Siguiente ▶:0" 2>/dev/null)

            local rc=$?
            [[ $rc -eq 2 ]] && return 2   # El llamador decide a dónde retroceder
            [[ $rc -ne 0 ]] && return 1   # Cancelar o cierre de ventana
            [[ -z "$format_raw" ]] && continue

            FORMAT=$(echo "$format_raw" | tr -d '|' | xargs)

            IS_LOSSLESS=false
            case "$FORMAT" in flac|wav|aiff) IS_LOSSLESS=true ;; esac

            BITRATE_OPT=""
            step=4
            ;;

        ########################################################################
        # PASO 4: BITRATE (solo formatos con pérdida)
        ########################################################################
        4)
            # Los formatos sin pérdida no tienen bitrate configurable
            if [[ "$IS_LOSSLESS" == "true" ]]; then
                step=5
                continue
            fi

            local quality_raw
            quality_raw=$(yad --list \
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
                --button="◀ Atrás:2" \
                --button="Siguiente ▶:0" 2>/dev/null)

            local rc=$?
            [[ $rc -eq 2 ]] && { step=3; continue; }
            [[ $rc -ne 0 ]] && return 1   # Cancelar o cierre de ventana
            [[ -z "$quality_raw" ]] && continue

            BITRATE_OPT=$(echo "$quality_raw" | tr -d '|' | xargs)
            step=5
            ;;

        ########################################################################
        # PASO 5: SAMPLE RATE
        ########################################################################
        5)
            local -a sr_options=()
            local sr_hint="<i>44100 Hz es estándar para música. 48000 Hz para video.</i>"

            case "$FORMAT" in
                opus)
                    sr_hint="<b>Opus resamplea internamente a un máximo de 48 kHz.</b>"
                    sr_options=(
                        "48000" "48 kHz (Recomendado ✦)" "Estándar Opus"
                        "44100" "44.1 kHz"    "Estándar CD"
                    ) ;;
                mp3)
                    sr_hint="<b>MP3 no soporta frecuencias superiores a 48 kHz.</b>"
                    sr_options=(
                        "48000" "48 kHz ✦"    "Calidad máxima"
                        "44100" "44.1 kHz"    "Estándar CD"
                    ) ;;
                mp2)
                    sr_hint="<b>MP2 solo soporta valores de sample rate estándar.</b>"
                    sr_options=(
                        "48000" "48 kHz"      "Video"
                        "44100" "44.1 kHz ✦"  "Estándar CD"
                    ) ;;
                aac|m4a)
                    sr_hint="<b>AAC soporta hasta 96 kHz (Hi-Res con soporte limitado).</b>"
                    sr_options=(
                        "orig"   "Sin cambios ✦" "Mantener original"
                        "96000"  "96 kHz"        "Estudio / Hi-Res"
                        "88200"  "88.2 kHz"      "Múltiplo de CD"
                        "48000"  "48 kHz"        "Estándar profesional"
                        "44100"  "44.1 kHz"      "Estándar CD"
                    ) ;;
                flac|wav|aiff)
                    sr_hint="<b>Formatos sin pérdida: soportan alta resolución real.</b>"
                    sr_options=(
                        "orig"   "Sin cambios ✦" "Mantener original"
                        "192000" "192 kHz"       "Mastering / Audiófilo"
                        "96000"  "96 kHz"        "Estudio / Hi-Res"
                        "88200"  "88.2 kHz"      "Múltiplo de CD"
                        "48000"  "48 kHz"        "Estándar profesional"
                        "44100"  "44.1 kHz"      "Estándar CD"
                    ) ;;
                *)
                    sr_options=(
                        "orig"  "Sin cambios ✦" "Mantener original"
                        "48000" "48 kHz"        "Video / Streaming"
                        "44100" "44.1 kHz"      "Estándar CD"
                    ) ;;
            esac

            local sr_raw
            sr_raw=$(yad --list \
                --title="🎵 Audio Converter — Sample Rate" \
                --text="<b>Selecciona el sample rate para $FORMAT:</b>\n$sr_hint" \
                --column="Hz" \
                --column="Nombre" \
                --column="Uso típico" \
                "${sr_options[@]}" \
                --width=540 --height=420 \
                --print-column=1 \
                --button="gtk-cancel:1" \
                --button="◀ Atrás:2" \
                --button="Siguiente ▶:0" 2>/dev/null)

            local rc=$?
            if [[ $rc -eq 2 ]]; then
                # Retroceder a bitrate (con pérdida) o a formato (sin pérdida)
                [[ "$IS_LOSSLESS" == "true" ]] && step=3 || step=4
                continue
            fi
            [[ $rc -ne 0 ]] && return 1   # Cancelar o cierre de ventana
            [[ -z "$sr_raw" ]] && continue

            local sr_val
            sr_val=$(echo "$sr_raw" | tr -d '|' | xargs)
            SAMPLE_RATE=""
            [[ "$sr_val" != "orig" ]] && SAMPLE_RATE="$sr_val"
            step=6
            ;;

        ########################################################################
        # PASO 6: BIT DEPTH (solo formatos sin pérdida)
        ########################################################################
        6)
            # Los formatos con pérdida no exponen control de bit depth
            if [[ "$IS_LOSSLESS" == "false" ]]; then
                step=7
                continue
            fi

            local bd_raw
            bd_raw=$(yad --list \
                --title="🎵 Audio Converter — Bit Depth" \
                --text="<b>Selecciona la profundidad de bits:</b>\n<i>Solo aplica a formatos sin pérdida (FLAC, WAV, AIFF).</i>" \
                --column="Formato ffmpeg" \
                --column="Bit Depth" \
                --column="Descripción" \
                "orig" "Sin cambios ✦" "Mantener la profundidad de bits original" \
                "s16"  "16 bits"       "Estándar CD — compatible con todos los reproductores" \
                "s32"  "24 bits (s32)" "Alta resolución — producción y masterización" \
                "s64"  "32 bits float" "Máxima precisión — edición profesional" \
                --width=540 --height=340 \
                --print-column=1 \
                --button="gtk-cancel:1" \
                --button="◀ Atrás:2" \
                --button="Siguiente ▶:0" 2>/dev/null)

            local rc=$?
            [[ $rc -eq 2 ]] && { step=5; continue; }
            [[ $rc -ne 0 ]] && return 1   # Cancelar o cierre de ventana
            [[ -z "$bd_raw" ]] && continue

            local bd_val
            bd_val=$(echo "$bd_raw" | tr -d '|' | xargs)
            BIT_DEPTH=""
            [[ "$bd_val" != "orig" ]] && BIT_DEPTH="$bd_val"
            step=7
            ;;

        ########################################################################
        # PASO 7: CARPETA DE DESTINO
        ########################################################################
        7)
            OUTPUT_DIR=$(yad --file \
                --title="🎵 Audio Converter — Carpeta de Destino" \
                --text="<b>Selecciona la carpeta donde se guardarán los archivos convertidos:</b>" \
                --directory \
                --filename="$LAST_DIR/" \
                --width=750 --height=520 \
                --button="gtk-cancel:1" \
                --button="◀ Atrás:2" \
                --button="Confirmar ✔:0" 2>/dev/null)

            local rc=$?
            if [[ $rc -eq 2 ]]; then
                # Retroceder a bit depth (sin pérdida) o a sample rate (con pérdida)
                [[ "$IS_LOSSLESS" == "true" ]] && step=6 || step=5
                continue
            fi
            [[ $rc -ne 0 ]] && return 1   # Cancelar o cierre de ventana
            [[ -z "$OUTPUT_DIR" ]] && continue

            # Persistir la última carpeta usada
            echo "LAST_DIR=\"$OUTPUT_DIR\"" > "$CONFIG_FILE"
            break
            ;;
        esac
    done

    return 0
}

################################################################################
# FUNCIÓN: Convertir archivo de audio con barra de progreso
# Uso: convert_file INPUT OUTPUT [LABEL_EXTRA]
# Retorna: 0=OK  2=Cancelado por el usuario  otro=Error de FFmpeg
################################################################################
convert_file() {
    local input_file="$1"
    local output_file="$2"
    local label_extra="${3:-}"

    local base_name
    base_name=$(basename "$input_file")

    # Obtener duración del archivo en segundos para calcular el porcentaje
    local raw_dur
    raw_dur=$(ffprobe -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$input_file" 2>/dev/null)
    local dur_int=${raw_dur%.*}
    [[ -z "$dur_int" || ! "$dur_int" =~ ^[0-9]+$ || "$dur_int" -le 0 ]] && dur_int=0

    # FIFO para recibir el progreso en tiempo real desde FFmpeg
    local pipe
    pipe=$(mktemp -u "$TEMP_DIR/pipe_XXXXXX")
    mkfifo "$pipe"

    # Construir flags opcionales de sample rate y bit depth
    local extra_flags=()
    [[ -n "$SAMPLE_RATE" ]] && extra_flags+=(-ar "$SAMPLE_RATE")
    [[ -n "$BIT_DEPTH" && "$IS_LOSSLESS" == "true" ]] && extra_flags+=(-sample_fmt "$BIT_DEPTH")

    # Lanzar FFmpeg en segundo plano según el tipo de formato
    if [[ "$IS_LOSSLESS" == "true" ]]; then
        ffmpeg -hide_banner -loglevel error -y -threads auto \
               -i "$input_file" -vn "${extra_flags[@]}" \
               -progress "$pipe" -nostats \
               "$output_file" &
    else
        ffmpeg -hide_banner -loglevel error -y -threads auto \
               -i "$input_file" -vn -b:a "$BITRATE_OPT" "${extra_flags[@]}" \
               -progress "$pipe" -nostats \
               "$output_file" &
    fi
    local ffmpeg_pid=$!

    # Construir etiqueta de calidad para mostrar en el diálogo
    local qlabel
    if [[ "${WAV_ONLY:-false}" == "true" ]]; then
        qlabel="WAV sin convertir"
    else
        qlabel="$FORMAT"
        [[ -n "$BITRATE_OPT" ]] && qlabel="$FORMAT @ $BITRATE_OPT"
        [[ -n "$SAMPLE_RATE" ]] && qlabel+="  ${SAMPLE_RATE} Hz"
        [[ -n "$BIT_DEPTH"   ]] && qlabel+="  ${BIT_DEPTH}"
    fi

    local dialog_text="<b>Convirtiendo:</b>  <i>$base_name</i>\n  <b>Calidad:</b>  $qlabel"
    [[ -n "$label_extra" ]] && dialog_text+="\n$label_extra"

    # Leer el pipe de progreso y alimentar la barra de YAD
    (
        local pct=0
        while IFS= read -r line; do
            if [[ "$line" =~ ^out_time_ms=([0-9]+)$ ]]; then
                local t="${BASH_REMATCH[1]}"
                if [[ $dur_int -gt 0 ]]; then
                    pct=$(( t / (dur_int * 10000) ))
                    (( pct >= 100 )) && pct=99
                else
                    # Duración desconocida: avanzar cíclicamente hasta 97 %
                    pct=$(( (pct + 1) % 98 ))
                fi
                echo "$pct"
            fi
            [[ "$line" == "progress=end" ]] && echo "100" && break
        done < "$pipe"
    ) | yad --progress \
        --title="🔄 Convirtiendo..." \
        --text="$dialog_text" \
        --percentage=0 \
        --auto-close \
        --width=560 \
        --button="⛔  Cancelar:1" 2>/dev/null

    local yad_exit=$?
    rm -f "$pipe"

    # El usuario presionó Cancelar
    if [[ $yad_exit -ne 0 ]]; then
        kill "$ffmpeg_pid" 2>/dev/null
        wait "$ffmpeg_pid" 2>/dev/null
        rm -f "$output_file"
        yad --warning \
            --title="Cancelado" \
            --text="<b>⚠ Conversión cancelada.</b>\nEl archivo parcial fue eliminado." \
            --width=400 \
            --button="OK:0" 2>/dev/null
        return 2
    fi

    wait "$ffmpeg_pid"
    return $?
}

################################################################################
# FUNCIÓN: Mostrar historial de conversiones
################################################################################
show_history_dialog() {
    if [[ ! -f "$HISTORY_FILE" ]]; then
        yad --info \
            --title="🕑 Historial de conversiones" \
            --text="<i>No hay historial disponible aún.</i>" \
            --width=400 \
            --button="OK:0" 2>/dev/null
        return
    fi

    yad --text-info \
        --title="🕑 Historial de conversiones" \
        --filename="$HISTORY_FILE" \
        --width=800 --height=460 \
        --tail \
        --button="🗑️  Limpiar historial:2" \
        --button="OK:0" 2>/dev/null

    if (( $? == 2 )); then
        > "$HISTORY_FILE"
        yad --info \
            --title="Historial limpiado" \
            --text="El historial ha sido eliminado." \
            --width=300 \
            --button="OK:0" 2>/dev/null
    fi
}

################################################################################
# FUNCIÓN: Mostrar resumen final de conversión
################################################################################
show_final_dialog() {
    local converted=$1
    local failed=$2
    local total=$3
    shift 3
    local files=("$@")

    # Construir etiqueta de calidad del proceso
    local qlabel
    if [[ "${WAV_ONLY:-false}" == "true" ]]; then
        qlabel="WAV sin convertir"
    else
        qlabel="$FORMAT"
        [[ -n "$BITRATE_OPT" ]] && qlabel="$FORMAT @ $BITRATE_OPT"
        [[ -n "$SAMPLE_RATE" ]] && qlabel+="  ${SAMPLE_RATE} Hz"
        [[ -n "$BIT_DEPTH"   ]] && qlabel+="  ${BIT_DEPTH}"
    fi

    local done_text
    done_text="<b><span foreground='#4CAF50' size='large'>✅  ¡Proceso completado!</span></b>\n\n"
    done_text+="  <b>Convertidos:</b>  $converted de $total\n"
    [[ $failed -gt 0 ]] && \
        done_text+="  <b><span foreground='#F44336'>Fallidos:</span></b>  $failed\n"
    done_text+="  <b>Formato:</b>  $qlabel\n"
    done_text+="  <b>Ubicación:</b>  $OUTPUT_DIR\n\n"

    # Listar hasta 8 archivos generados con su tamaño
    if [[ ${#files[@]} -gt 0 ]]; then
        done_text+="<b>Archivos generados:</b>\n"
        local limit=$(( ${#files[@]} < 8 ? ${#files[@]} : 8 ))
        for (( i = 0; i < limit; i++ )); do
            local cf="${files[$i]}"
            local fsize
            fsize=$(du -sh "$cf" 2>/dev/null | cut -f1)
            done_text+="  📄 $(basename "$cf")  <i>($fsize)</i>\n"
        done
        (( ${#files[@]} > 8 )) && \
            done_text+="  … y $(( ${#files[@]} - 8 )) archivo(s) más\n"
    fi

    yad --info \
        --title="✅ Conversión completada" \
        --text="$done_text" \
        --width=580 --height=360 \
        --button="🕑  Historial:3" \
        --button="📂  Abrir carpeta:2" \
        --button="✔️  Finalizar:0" 2>/dev/null

    local btn=$?
    [[ $btn -eq 2 ]] && xdg-open "$OUTPUT_DIR" &
    [[ $btn -eq 3 ]] && show_history_dialog
}

################################################################################
# FUNCIÓN PRINCIPAL DE CONVERSIÓN DE ARCHIVOS LOCALES
################################################################################
process_conversions() {
    local converted=0
    local failed=0
    local -a converted_files=()
    local file_number=0
    local total_files=${#INPUT_FILES[@]}

    for input_file in "${INPUT_FILES[@]}"; do
        (( file_number++ ))

        local base_name="${input_file##*/}"
        local fname="${base_name%.*}"
        local safe_name
        safe_name=$(clean_filename "$fname")
        local output_file="$OUTPUT_DIR/$safe_name.$FORMAT"

        # Resolver conflicto si el archivo de destino ya existe
        if [[ -f "$output_file" ]]; then
            resolve_conflict "$output_file" "$safe_name" "$FORMAT" "$OUTPUT_DIR"
            [[ "$SKIP_FILE" == "true" ]] && { (( failed++ )); continue; }
            output_file="$OUTPUT_FILE"
        fi

        convert_file "$input_file" "$output_file" \
            "  <b>Archivo</b>  $file_number de $total_files"
        local conv_result=$?

        if (( conv_result == 2 )); then
            return 2
        fi

        if (( conv_result == 0 )); then
            (( converted++ ))
            converted_files+=("$output_file")

            local hist_label="${BITRATE_OPT:-lossless}"
            [[ -n "$SAMPLE_RATE" ]] && hist_label+=" ${SAMPLE_RATE} Hz"
            [[ -n "$BIT_DEPTH"   ]] && hist_label+=" ${BIT_DEPTH}"
            echo "$(date '+%Y-%m-%d %H:%M')  |  $base_name  →  $(basename "$output_file")  |  $hist_label  |  $OUTPUT_DIR" \
                >> "$HISTORY_FILE"
        else
            (( failed++ ))
            rm -f "$output_file"
        fi
    done

    show_final_dialog "$converted" "$failed" "$total_files" "${converted_files[@]}"
}

################################################################################
# FLUJO PRINCIPAL — MODO A: ARCHIVOS LOCALES  /  MODO B: CD DE AUDIO
################################################################################

verify_dependencies
LAST_DIR=$(load_config)

# ── Menú principal: selección de modo ────────────────────────────────────────
MODE=$(yad --list \
    --title="🎵 Audio Converter" \
    --text="<b>¿Qué deseas convertir?</b>" \
    --column="Modo" \
    --column="Descripción" \
    "🗂  Archivos locales" "Convierte archivos de audio desde tu disco" \
    "💿  CD de audio"      "Ripea y convierte pistas desde un CD" \
    --width=480 --height=230 \
    --print-column=1 \
    --no-headers \
    --button="gtk-cancel:1" \
    --button="Continuar ▶:0" 2>/dev/null)

[[ $? -ne 0 || -z "$MODE" ]] && exit 0
MODE=$(echo "$MODE" | tr -d '|' | xargs)

# =============================================================================
#  MODO A — ARCHIVOS LOCALES
# =============================================================================

if [[ "$MODE" == *"Archivos locales"* ]]; then

    # ── Paso 1: Selección de archivos (solo una vez) ──────────────────────────
    if ! select_input_files; then
        exit 0
    fi

    # ── Loop principal: permite volver al paso 2 ──────────────────────────────
    while true; do

        # ── Paso 2: Confirmar archivos ────────────────────────────────────────
        if ! confirm_input_files; then
            if ! select_input_files; then
                exit 0
            fi
            continue
        fi

        # ── Pasos 3-7: Configuración de conversión ────────────────────────────
        select_audio_options 3
        local_rc=$?

        if (( local_rc == 1 )); then
            exit 0
        elif (( local_rc == 2 )); then
            continue
        fi

        # ── Conversión ────────────────────────────────────────────────────────
        process_conversions
        conv_rc=$?

        if (( conv_rc == 2 )); then
            continue
        fi

        exit 0
    done

# =============================================================================
#  MODO B — CD DE AUDIO
# =============================================================================

elif [[ "$MODE" == *"CD de audio"* ]]; then

    # ── Detectar dispositivo de CD ────────────────────────────────────────────
    CD_DEV=""
    for dev in /dev/cdrom /dev/sr0 /dev/sr1 /dev/dvd; do
        [[ -b "$dev" ]] && CD_DEV="$dev" && break
    done

    if [[ -z "$CD_DEV" ]]; then
        yad --error \
            --title="CD no encontrado" \
            --text="<b>❌ No se detectó ningún dispositivo de CD.</b>\n\nVerifica que:\n  • El CD está insertado correctamente\n  • El dispositivo existe en /dev/cdrom o /dev/sr0" \
            --width=440 \
            --button="OK:0" 2>/dev/null
        exit 1
    fi

    # ── Leer tabla de contenidos (TOC) y disc-id ──────────────────────────────
    yad --progress \
        --title="💿 Leyendo CD..." \
        --text="<b>Leyendo tabla de contenidos del disco...</b>" \
        --pulsate --auto-close --no-buttons --width=420 2>/dev/null &
    PULSE_PID=$!

    DISC_ID=$(cd-discid "$CD_DEV" 2>/dev/null)
    CD_INFO=$(cdparanoia -Q -d "$CD_DEV" 2>&1)

    kill "$PULSE_PID" 2>/dev/null
    wait "$PULSE_PID" 2>/dev/null

    if [[ -z "$DISC_ID" ]]; then
        yad --error \
            --title="Error al leer CD" \
            --text="<b>❌ No se pudo leer el CD.</b>\n\nVerifica que es un CD de audio válido y que no está dañado." \
            --width=420 \
            --button="OK:0" 2>/dev/null
        exit 1
    fi

    # ── Parsear pistas del TOC de cdparanoia ─────────────────────────────────
    # Formato de salida de cdparanoia -Q:
    #   N.    SECTORS [MM:SS.FF]    OFFSET [MM:SS.FF]    pre  copy  channels
    # Capturamos: número de pista y duración [MM:SS]
    declare -a TRACKS_DATA
    declare -A TRACK_DUR_STR

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]+([0-9]+)\.[[:space:]]+[0-9]+[[:space:]]+\[([0-9]+):([0-9]+)\.[0-9]+\] ]]; then
            TNUM="${BASH_REMATCH[1]}"
            T_MIN="${BASH_REMATCH[2]}"
            T_SEC="${BASH_REMATCH[3]}"
            TRACK_DUR_STR[$TNUM]="${T_MIN}:${T_SEC}"
            TRACKS_DATA+=("$TNUM" "${T_MIN}:${T_SEC}")
        fi
    done <<< "$CD_INFO"

    if [[ ${#TRACKS_DATA[@]} -eq 0 ]]; then
        yad --error \
            --title="Error al leer pistas" \
            --text="<b>❌ No se pudieron leer las pistas del CD.</b>\n\nIntenta limpiar el disco y vuelve a intentarlo." \
            --width=480 \
            --button="OK:0" 2>/dev/null
        exit 1
    fi

    # ── Consultar metadata en gnudb (protocolo freedb) ───────────────────────
    yad --progress \
        --title="💿 Buscando metadata..." \
        --text="<b>Consultando gnudb.gnudb.org...</b>\n<i>Buscando artista, álbum y nombres de pistas</i>" \
        --pulsate --auto-close --no-buttons --width=440 2>/dev/null &
    PULSE_PID=$!

    # Descomponer el disc-id en sus partes: DISCID TRACKS OFF1 ... TOTAL_SECS
    DISC_ID_PARTS=($DISC_ID)
    DISCID_HEX="${DISC_ID_PARTS[0]}"
    NUM_TRACKS_ID="${DISC_ID_PARTS[1]}"
    OFFSETS=("${DISC_ID_PARTS[@]:2:$NUM_TRACKS_ID}")
    TOTAL_SECS="${DISC_ID_PARTS[-1]}"
    OFFSETS_QUERY=$(IFS=+; echo "${OFFSETS[*]}")

    # Construir URL de consulta al servidor gnudb
    GNUDB_QUERY="cmd=cddb+query+${DISCID_HEX}+${NUM_TRACKS_ID}+${OFFSETS_QUERY}+${TOTAL_SECS}"
    GNUDB_HELLO="hello=$(whoami)+$(hostname)+AudioConverter+1.0"
    GNUDB_URL="http://gnudb.gnudb.org/~cddb/cddb.cgi?${GNUDB_QUERY}&${GNUDB_HELLO}&proto=6"

    # Usar caché local para evitar consultar gnudb en discos ya procesados
    if [[ -f "$CACHE_DIR/$DISCID_HEX" ]]; then
        GNUDB_RESULT=$(cat "$CACHE_DIR/$DISCID_HEX")
    else
        GNUDB_RESULT=$(curl -sL -A "AudioConverter/1.0" --max-time 10 "$GNUDB_URL" 2>/dev/null)
        [[ -n "$GNUDB_RESULT" ]] && echo "$GNUDB_RESULT" > "$CACHE_DIR/$DISCID_HEX"
    fi

    # Valores por defecto si no se encuentra metadata
    ARTIST="Desconocido"
    ALBUM="CD de Audio"
    YEAR=""
    declare -A TRACK_NAMES
    META_SOURCE="<span foreground='#FF9800'>⚠ Metadata no encontrada — usando nombres genéricos</span>"

    if [[ -n "$GNUDB_RESULT" ]]; then
        RESP_CODE=$(echo "$GNUDB_RESULT" | head -1 | awk '{print $1}')

        # Códigos de respuesta: 200=exacta  210=múltiple (lista)  211=resultado aproximado
        if [[ "$RESP_CODE" == "200" || "$RESP_CODE" == "210" || "$RESP_CODE" == "211" ]]; then

            if [[ "$RESP_CODE" == "200" ]]; then
                # Coincidencia exacta: leer categoría e ID de la primera línea
                CDDB_CAT=$(echo "$GNUDB_RESULT" | head -1 | awk '{print $2}')
                CDDB_ID=$(echo  "$GNUDB_RESULT" | head -1 | awk '{print $3}')
            else
                # Coincidencias múltiples: tomar el primer resultado (línea 2)
                CDDB_CAT=$(echo "$GNUDB_RESULT" | sed -n '2p' | awk '{print $1}')
                CDDB_ID=$(echo  "$GNUDB_RESULT" | sed -n '2p' | awk '{print $2}')
            fi

            # Obtener la entrada completa del disco
            READ_URL="http://gnudb.gnudb.org/~cddb/cddb.cgi?cmd=cddb+read+${CDDB_CAT}+${CDDB_ID}&${GNUDB_HELLO}&proto=6"
            CDDB_ENTRY=$(curl -sL -A "AudioConverter/1.0" --max-time 10 "$READ_URL" 2>/dev/null)

            # gnudb usa line endings Windows (\r\n); normalizar a Unix (\n)
            CDDB_ENTRY=$(printf '%s' "$CDDB_ENTRY" | tr -d '\r')

            # CDs antiguos pueden tener metadata en ISO-8859-1; convertir si no es UTF-8 válido
            if ! printf '%s' "$CDDB_ENTRY" | iconv -f utf-8 -t utf-8 >/dev/null 2>&1; then
                CDDB_ENTRY=$(printf '%s' "$CDDB_ENTRY" \
                    | iconv -f iso-8859-1 -t utf-8 2>/dev/null \
                    || printf '%s' "$CDDB_ENTRY")
            fi

            if [[ -n "$CDDB_ENTRY" ]]; then
                DTITLE=$(echo "$CDDB_ENTRY" | grep "^DTITLE=" | head -1 | cut -d= -f2-)
                DYEAR=$(echo  "$CDDB_ENTRY" | grep "^DYEAR="  | head -1 | cut -d= -f2-)

                # DTITLE puede venir como "Artista / Álbum" o solo "Álbum"
                if [[ "$DTITLE" == *" / "* ]]; then
                    ARTIST=$(echo "$DTITLE" | sed 's/ \/ .*//')
                    ALBUM=$(echo  "$DTITLE" | sed 's/.*\/ //')
                else
                    ALBUM="$DTITLE"
                fi
                [[ -n "$DYEAR" ]] && YEAR="$DYEAR"

                # Extraer nombres de pistas (TTITLEn está indexado desde 0)
                while IFS= read -r line; do
                    if [[ "$line" =~ ^TTITLE([0-9]+)=(.+)$ ]]; then
                        IDX="${BASH_REMATCH[1]}"
                        NAME="${BASH_REMATCH[2]}"
                        TRACK_NAMES[$(( IDX + 1 ))]="$NAME"
                    fi
                done <<< "$CDDB_ENTRY"

                META_SOURCE="<span foreground='#4CAF50'>✔ Metadata encontrada en gnudb</span>"
            fi
        fi
    fi

    kill "$PULSE_PID" 2>/dev/null
    wait "$PULSE_PID" 2>/dev/null

    # ── Construir lista de pistas para el checklist ───────────────────────────
    declare -a TRACKS_LIST
    for (( i = 0; i < ${#TRACKS_DATA[@]}; i += 2 )); do
        TNUM="${TRACKS_DATA[$i]}"
        T_DUR="${TRACKS_DATA[$(( i + 1 ))]}"
        TNAME="${TRACK_NAMES[$TNUM]:-Pista $TNUM}"
        TRACKS_LIST+=("TRUE" "$TNUM" "$TNAME" "$T_DUR")
    done

    YEAR_STR=""
    [[ -n "$YEAR" ]] && YEAR_STR=" ($YEAR)"

    # ── Funciones auxiliares para el modo de ripeado ──────────────────────────

    # Muestra el diálogo de selección de velocidad/modo de ripeado
    _show_speed_dialog() {
        RIP_SPEED_RAW=$(yad --list \
            --title="💿 CD de Audio — Modo de Ripeado" \
            --text="<b>Selecciona cómo deseas ripear el CD:</b>\n<i>«Solo WAV» guarda las pistas tal cual, sin convertir ni recodificar.</i>" \
            --column="Modo" \
            --column="Velocidad estimada" \
            --column="Descripción" \
            "Rápido"    "5–10x más rápido"  "Conversión al formato elegido — recomendado para CDs limpios  ✦" \
            "Normal"    "2–3x más rápido"   "Conversión al formato elegido — con corrección básica de errores" \
            "Paranoid"  "Tiempo real"       "Conversión al formato elegido — para CDs rayados o dañados" \
            "Solo WAV"  "5–10x más rápido"  "Copia WAV sin convertir — máxima fidelidad, sin recodificación" \
            --width=660 --height=310 \
            --print-column=1 \
            --button="gtk-cancel:1" \
            --button="◀ Atrás:2" \
            --button="Siguiente ▶:0" 2>/dev/null)
        return $?
    }

    # Aplica los flags de cdparanoia según el modo seleccionado
    _apply_speed() {
        RIP_SPEED=$(echo "$RIP_SPEED_RAW" | tr -d '|' | xargs)
        case "$RIP_SPEED" in
            "Rápido")   CDPARA_FLAGS="-Z"; WAV_ONLY=false ;;
            "Normal")   CDPARA_FLAGS="-z"; WAV_ONLY=false ;;
            "Paranoid") CDPARA_FLAGS="";   WAV_ONLY=false ;;
            "Solo WAV") CDPARA_FLAGS="-Z"; WAV_ONLY=true  ;;
            *)          CDPARA_FLAGS="-Z"; WAV_ONLY=false ;;
        esac
    }

    # ── Bucle principal: Selección de pistas → Modo de ripeado → Formato/Carpeta ──
    WAV_ONLY=false
    FORMAT="wav"       # valor por defecto; se sobreescribe si el usuario elige conversión
    CDPARA_FLAGS="-Z"
    SEL_TRACKS=()

    while true; do

        # ── Selección de pistas a ripear ──────────────────────────────────────
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
        [[ $BTN_TRACKS -ne 0 && $BTN_TRACKS -ne 2 ]] && exit 0   # Cancelar o cierre de ventana

        if [[ $BTN_TRACKS -eq 2 ]]; then
            # Seleccionar todas las pistas detectadas
            SEL_TRACKS=()
            for (( i = 0; i < ${#TRACKS_DATA[@]}; i += 2 )); do
                SEL_TRACKS+=("${TRACKS_DATA[$i]}")
            done
        else
            # Parsear los números de pista seleccionados del output de YAD
            SEL_TRACKS=()
            while IFS= read -r t; do
                t="${t//|/}"
                t="${t#"${t%%[![:space:]]*}"}"
                [[ -n "$t" ]] && SEL_TRACKS+=("$t")
            done <<< "$SELECTED_RAW"
        fi

        if [[ ${#SEL_TRACKS[@]} -eq 0 ]]; then
            yad --warning \
                --title="Sin selección" \
                --text="No seleccionaste ninguna pista." \
                --width=360 \
                --button="OK:0" 2>/dev/null
            continue   # Volver a mostrar el checklist de pistas
        fi

        # ── Modo de ripeado ───────────────────────────────────────────────────
        _show_speed_dialog
        RC=$?
        [[ $RC -ne 0 && $RC -ne 2 ]] && exit 0   # Cancelar o cierre de ventana
        if [[ $RC -eq 2 ]]; then
            continue   # Atrás → volver al checklist de pistas
        fi
        [[ -z "$RIP_SPEED_RAW" ]] && continue
        _apply_speed

        # ── Formato/Carpeta de destino ────────────────────────────────────────
        if [[ "$WAV_ONLY" == "true" ]]; then
            OUTPUT_DIR=$(yad --file \
                --title="💿 CD de Audio — Carpeta de Destino (WAV)" \
                --text="<b>Selecciona la carpeta donde se guardarán los archivos WAV:</b>\n<i>Se creará una subcarpeta con el nombre del álbum.</i>" \
                --directory \
                --filename="$LAST_DIR/" \
                --width=750 --height=520 \
                --button="gtk-cancel:1" \
                --button="◀ Atrás:2" \
                --button="Confirmar ✔:0" 2>/dev/null)

            RC=$?
            if [[ $RC -eq 2 ]]; then
                continue   # Atrás → volver al checklist de pistas
            fi
            [[ $RC -ne 0 ]] && exit 0             # Cancelar o cierre de ventana
            [[ -z "$OUTPUT_DIR" ]] && continue

            echo "LAST_DIR=\"$OUTPUT_DIR\"" > "$CONFIG_FILE"
            FORMAT="wav"
            IS_LOSSLESS=true
            BITRATE_OPT=""
            break
        else
            select_audio_options 3
            RC=$?
            [[ $RC -ne 0 && $RC -ne 2 ]] && exit 0   # Cancelar o cierre de ventana
            [[ $RC -eq 0 ]] && break
            # RC=2: Atrás desde Formato → volver al checklist de pistas
        fi

    done

    # ── Crear subcarpeta del álbum ────────────────────────────────────────────
    SAFE_ALBUM=$(clean_filename "$ALBUM")
    ALBUM_DIR="$OUTPUT_DIR/$SAFE_ALBUM"
    mkdir -p "$ALBUM_DIR"

    # ── Ripeado y conversión de cada pista seleccionada ───────────────────────
    CONVERTED=0
    FAILED=0
    CONVERTED_FILES=()
    TOTAL_SEL=${#SEL_TRACKS[@]}

    for TNUM in "${SEL_TRACKS[@]}"; do
        TRACK_IDX=$(( CONVERTED + FAILED + 1 ))
        TNAME="${TRACK_NAMES[$TNUM]:-Pista $TNUM}"
        SAFE_TNAME=$(clean_filename "$TNAME")
        TRACK_FILENAME=$(printf "%02d - %s" "$TNUM" "$SAFE_TNAME")
        WAV_FILE="$TEMP_DIR/track${TNUM}.wav"
        OUTPUT_FILE="$ALBUM_DIR/$TRACK_FILENAME.$FORMAT"

        # Resolver conflicto si el archivo ya existe en el destino
        if [[ -f "$OUTPUT_FILE" ]]; then
            resolve_conflict "$OUTPUT_FILE" "$TRACK_FILENAME" "$FORMAT" "$ALBUM_DIR"
            [[ "$SKIP_FILE" == "true" ]] && continue
        fi

        # ── Ripeado con cdparanoia ──────────────────────────────────────────
        RIP_LOG="$TEMP_DIR/rip_${TNUM}.log"
        RIP_PIPE=$(mktemp -u /tmp/audioconv_RIP_XXXXXX)
        mkfifo "$RIP_PIPE"
        trap "rm -f '$RIP_PIPE'" PIPE   # limpiar el pipe ante señal SIGPIPE

        # Iniciar cdparanoia en segundo plano
        cdparanoia ${CDPARA_FLAGS} -d "$CD_DEV" "$TNUM" "$WAV_FILE" \
            > "$RIP_LOG" 2>&1 &
        CDPARA_PID=$!

        # Proceso feeder: envía pulsos de progreso mientras cdparanoia esté activo
        (
            while kill -0 "$CDPARA_PID" 2>/dev/null; do
                echo "1"
                sleep 0.5
            done
            echo "100"   # forzar cierre de la barra al terminar
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

        # Detener el feeder y limpiar el pipe
        kill "$FEEDER_PID" 2>/dev/null
        wait "$FEEDER_PID" 2>/dev/null
        rm -f "$RIP_PIPE"

        if [[ $YAD_RIP -ne 0 ]]; then
            # El usuario canceló el ripeado
            kill "$CDPARA_PID" 2>/dev/null
            wait "$CDPARA_PID" 2>/dev/null
            rm -f "$WAV_FILE" "$RIP_LOG"
            yad --warning \
                --title="Cancelado" \
                --text="<b>⚠ Ripeado cancelado.</b>" \
                --width=380 \
                --button="OK:0" 2>/dev/null
            exit 0
        fi

        wait "$CDPARA_PID"
        RIP_EXIT=$?

        if [[ $RIP_EXIT -ne 0 || ! -f "$WAV_FILE" ]]; then
            yad --error \
                --title="Error al ripear" \
                --text="<b>❌ Error al ripear la pista $TNUM.</b>\n\nRevisa que el CD no esté rayado o dañado." \
                --width=400 \
                --button="OK:0" 2>/dev/null
            (( FAILED++ ))
            continue
        fi

        # ── Conversión WAV → formato destino (o copiar si es Solo WAV) ────────
        if [[ "$WAV_ONLY" == "true" ]]; then
            mv "$WAV_FILE" "$OUTPUT_FILE"
            CONV_RESULT=$?
        else
            convert_file "$WAV_FILE" "$OUTPUT_FILE" \
                "  <b>Álbum:</b>  $ALBUM  —  Pista $TNUM / $TOTAL_SEL"
            CONV_RESULT=$?
            rm -f "$WAV_FILE"
            [[ $CONV_RESULT -eq 2 ]] && exit 0   # Cancelado por el usuario
        fi

        # ── Incrustar metadata con FFmpeg ─────────────────────────────────────
        if [[ $CONV_RESULT -eq 0 ]]; then
            TMP_META="$TEMP_DIR/meta_${TNUM}.$FORMAT"
            META_ARGS=(
                -metadata "title=$TNAME"
                -metadata "artist=$ARTIST"
                -metadata "album=$ALBUM"
                -metadata "track=$TNUM"
            )
            [[ -n "$YEAR" ]] && META_ARGS+=(-metadata "date=$YEAR")

            ffmpeg -hide_banner -loglevel error -y \
                   -i "$OUTPUT_FILE" -vn "${META_ARGS[@]}" -codec copy \
                   "$TMP_META" \
                && mv "$TMP_META" "$OUTPUT_FILE" \
                || rm -f "$TMP_META"

            (( CONVERTED++ ))
            CONVERTED_FILES+=("$OUTPUT_FILE")

            # Registrar en historial
            QLABEL="${WAV_ONLY:+WAV sin convertir}"
            [[ -z "$QLABEL" ]] && QLABEL="${BITRATE_OPT:-lossless}"
            echo "$(date '+%Y-%m-%d %H:%M')  |  CD: $ALBUM — $TNAME  →  $TRACK_FILENAME.$FORMAT  |  $QLABEL  |  $ALBUM_DIR" \
                >> "$HISTORY_FILE"
        else
            (( FAILED++ ))
            rm -f "$OUTPUT_FILE"
        fi
    done

    # ── Resumen final y expulsión del disco ───────────────────────────────────
    OUTPUT_DIR="$ALBUM_DIR"
    show_final_dialog "$CONVERTED" "$FAILED" "$TOTAL_SEL" "${CONVERTED_FILES[@]}"

    # Expulsar el CD; limpiar CD_DEV para que el trap no lo expulse por segunda vez
    eject "$CD_DEV" 2>/dev/null
    CD_DEV=""

fi

exit 0#!/bin/bash
################################################################################
# Audio Converter V2 — YAD + FFmpeg/FFprobe + Ripeador de CD
#
# Convierte archivos de audio locales en lote con interfaz gráfica interactiva.
# También permite ripear y convertir pistas desde un CD de audio.
#
# REQUISITOS: yad, ffmpeg, ffprobe, numfmt (coreutils)
#             cdparanoia, cd-discid, curl, iconv  (solo para modo CD)
# USO: ./audio-converter-v2.sh
################################################################################

################################################################################
# CONFIGURACIÓN GLOBAL
################################################################################
readonly CONFIG_DIR="$HOME/.config/audio_converter"
readonly CONFIG_FILE="$CONFIG_DIR/settings.conf"
readonly HISTORY_FILE="$CONFIG_DIR/history.log"
readonly TEMP_DIR=$(mktemp -d /tmp/audioconv_XXXXXX)
readonly CACHE_DIR="$CONFIG_DIR/cddb_cache"
WAV_ONLY=false
CD_DEV=""

mkdir -p "$CONFIG_DIR" "$CACHE_DIR"

################################################################################
# MANEJO DE LIMPIEZA Y TRAPS
################################################################################
cleanup() {
    [[ -n "$CD_DEV" ]] && eject "$CD_DEV" 2>/dev/null
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}

trap cleanup EXIT HUP INT TERM

################################################################################
# VERIFICACIÓN DE DEPENDENCIAS
################################################################################
verify_dependencies() {
    local missing_deps=()

    for dep in yad ffmpeg ffprobe numfmt; do
        command -v "$dep" &>/dev/null || missing_deps+=("$dep")
    done

    # cd-discid y cdparanoia solo son necesarios en el modo CD
    for dep in cdparanoia cd-discid; do
        command -v "$dep" &>/dev/null || missing_deps+=("$dep (necesario para ripear CDs)")
    done

    if (( ${#missing_deps[@]} > 0 )); then
        local msg="<b>❌ Faltan dependencias necesarias:</b>\n\n"
        for d in "${missing_deps[@]}"; do
            msg+="  • <b>$d</b>\n"
        done
        msg+="\n<i>Instálalas antes de continuar:</i>\n"
        msg+="  <tt>sudo apt install ${missing_deps[*]}</tt>"

        yad --error \
            --title="⚠️  Dependencias faltantes" \
            --text="$msg" \
            --width=480 \
            --button="Salir:0" 2>/dev/null
        exit 1
    fi
}

################################################################################
# CARGA DE CONFIGURACIÓN PERSISTENTE
################################################################################
load_config() {
    local last_dir="$HOME"
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" 2>/dev/null || true
    echo "$last_dir"
}

################################################################################
# FUNCIÓN: Limpiar caracteres inválidos en nombres de archivo
################################################################################
clean_filename() {
    local filename="$1"
    filename=$(echo "$filename" | sed 's/[/:*?"<>|\\]/-/g')
    filename=$(echo "$filename" | sed 's/--*/-/g')
    filename="${filename#-}"
    filename="${filename%-}"
    echo "$filename"
}

################################################################################
# FUNCIÓN: Resolver conflictos de nombre de archivo duplicado
# Exporta: OUTPUT_FILE (ruta final), SKIP_FILE=true si el usuario omite
################################################################################
resolve_conflict() {
    local existing="$1"
    local fname="$2"
    local fmt="$3"
    local dir="$4"
    SKIP_FILE=false

    local fsize fdate bname
    fsize=$(du -sh "$existing" 2>/dev/null | cut -f1)
    fdate=$(stat -c "%y" "$existing" 2>/dev/null | cut -d. -f1)
    bname=$(basename "$existing")

    local action
    action=$(yad --list \
        --title="⚠️  Archivo ya existe" \
        --text="<b>El archivo ya existe en el sistema:</b>\n\n  📄 <b>$bname</b>\n  Tamaño: <i>$fsize</i>  |  Modificado: <i>$fdate</i>\n\n<b>¿Qué deseas hacer?</b>" \
        --column="Acción" \
        --column="Descripción" \
        "Reemplazar" "Sobreescribir el archivo existente" \
        "Renombrar"  "Guardar con un nombre nuevo automáticamente" \
        "Omitir"     "Saltar este archivo y continuar con el siguiente" \
        --print-column=1 \
        --width=520 --height=260 \
        --no-headers \
        --button="Confirmar:0" 2>/dev/null)

    action=$(echo "$action" | tr -d '|' | xargs)

    case "$action" in
        Reemplazar)
            OUTPUT_FILE="$existing"
            ;;
        Renombrar)
            local c=1
            while [[ -f "$dir/${fname}_${c}.$fmt" ]]; do (( c++ )); done
            OUTPUT_FILE="$dir/${fname}_${c}.$fmt"
            ;;
        *)
            SKIP_FILE=true
            ;;
    esac
}

################################################################################
# PASO 1: SELECCIONAR ARCHIVOS DE AUDIO
################################################################################
select_input_files() {
    local input_raw

    input_raw=$(yad --file \
        --title="🎵 Audio Converter — Seleccionar Archivos" \
        --text="<b>Selecciona uno o más archivos de audio:</b>\n<i>Mantén Ctrl o Shift para múltiple selección</i>" \
        --multiple \
        --file-filter="Archivos de Audio|*.mp3 *.aac *.flac *.ogg *.wav *.opus *.wma *.m4a *.aiff *.mp2 *.webm *.mkv" \
        --file-filter="Todos los archivos|*" \
        --width=780 --height=560 \
        --button="gtk-cancel:1" \
        --button="Siguiente ▶:0" 2>/dev/null)

    (( $? != 0 )) && return 1
    [[ -z "$input_raw" ]] && return 1

    IFS='|' read -ra raw_list <<< "$input_raw"
    INPUT_FILES=()
    for f in "${raw_list[@]}"; do
        f="${f#"${f%%[![:space:]]*}"}"
        f="${f%"${f##*[![:space:]]}"}"
        [[ -f "$f" ]] && INPUT_FILES+=("$f")
    done

    if (( ${#INPUT_FILES[@]} == 0 )); then
        yad --error \
            --title="❌ Error" \
            --text="No se encontraron archivos válidos." \
            --width=380 \
            --button="OK:0" 2>/dev/null
        return 1
    fi

    return 0
}

################################################################################
# PASO 2: CONFIRMAR ARCHIVOS CON INFORMACIÓN
################################################################################
confirm_input_files() {
    local file_count=${#INPUT_FILES[@]}
    local -a info_rows=()

    for f in "${INPUT_FILES[@]}"; do
        local bname
        bname=$(basename "$f")

        local raw
        raw=$(ffprobe -v error \
            -show_entries format=duration,size \
            -show_entries stream=codec_name \
            -of default=noprint_wrappers=1 "$f" 2>/dev/null)

        local dur_raw size_bytes codec
        dur_raw=$(echo "$raw"    | grep "^duration="   | head -1 | cut -d= -f2)
        size_bytes=$(echo "$raw" | grep "^size="        | head -1 | cut -d= -f2)
        codec=$(echo "$raw"      | grep "^codec_name="  | head -1 | cut -d= -f2)

        local di=${dur_raw%.*}
        local dur_str
        [[ "$di" =~ ^[0-9]+$ ]] \
            && dur_str="$(( di / 60 ))m $(( di % 60 ))s" \
            || dur_str="N/A"

        if [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
            size_bytes=$(numfmt --to=iec --suffix=B "$size_bytes" 2>/dev/null || echo "N/A")
        else
            size_bytes="N/A"
        fi

        info_rows+=("TRUE" "$bname" "${codec:-N/A}" "$dur_str" "$size_bytes")
    done

    local selected_raw
    selected_raw=$(yad --list \
        --title="🎵 Audio Converter — Confirmar Archivos ($file_count archivos)" \
        --text="<b>Confirma los archivos a convertir:</b>\n<i>Desmarca los que no quieras incluir.</i>" \
        --checklist \
        --column="✔" \
        --column="Nombre" \
        --column="Códec" \
        --column="Duración" \
        --column="Tamaño" \
        "${info_rows[@]}" \
        --print-column=2 \
        --width=820 --height=460 \
        --button="gtk-cancel:1" \
        --button="☑  Todas:2" \
        --button="Continuar ▶:0" 2>/dev/null)

    local btn=$?
    [[ $btn -ne 0 && $btn -ne 2 ]] && return 1

    if [[ $btn -eq 2 ]]; then
        return 0   # Todas seleccionadas; INPUT_FILES no cambia
    fi

    local -a final_files=()
    while IFS= read -r sel_name; do
        sel_name="${sel_name//|/}"
        sel_name="${sel_name#"${sel_name%%[![:space:]]*}"}"
        sel_name="${sel_name%"${sel_name##*[![:space:]]}"}"
        [[ -z "$sel_name" ]] && continue
        for orig in "${INPUT_FILES[@]}"; do
            if [[ "$(basename "$orig")" == "$sel_name" ]]; then
                final_files+=("$orig")
                break
            fi
        done
    done <<< "$selected_raw"

    if (( ${#final_files[@]} == 0 )); then
        yad --warning \
            --title="Sin archivos" \
            --text="No seleccionaste ningún archivo." \
            --width=360 \
            --button="OK:0" 2>/dev/null
        return 1
    fi

    INPUT_FILES=("${final_files[@]}")
    return 0
}

################################################################################
# PASOS 3-7: SELECCIÓN DE OPCIONES DE CONVERSIÓN
# Exporta: FORMAT, BITRATE_OPT, IS_LOSSLESS, SAMPLE_RATE, BIT_DEPTH, OUTPUT_DIR
# Retorna: 0=Confirmar  1=Cancelar  2=Atrás desde Formato (lo gestiona el llamador)
################################################################################
select_audio_options() {
    local start_step="${1:-3}"
    FORMAT=""
    BITRATE_OPT=""
    IS_LOSSLESS=false
    SAMPLE_RATE=""
    BIT_DEPTH=""
    OUTPUT_DIR=""

    local step=$start_step

    while true; do
        case $step in

        ########################################################################
        # PASO 3: FORMATO DE SALIDA
        ########################################################################
        3)
            local format_raw
            format_raw=$(yad --list \
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
                --button="◀ Atrás:2" \
                --button="Siguiente ▶:0" 2>/dev/null)

            local rc=$?
            [[ $rc -eq 2 ]] && return 2   # El llamador decide a dónde retroceder
            [[ $rc -ne 0 ]] && return 1   # Cancelar o cierre de ventana
            [[ -z "$format_raw" ]] && continue

            FORMAT=$(echo "$format_raw" | tr -d '|' | xargs)

            IS_LOSSLESS=false
            case "$FORMAT" in flac|wav|aiff) IS_LOSSLESS=true ;; esac

            BITRATE_OPT=""
            step=4
            ;;

        ########################################################################
        # PASO 4: BITRATE (solo formatos con pérdida)
        ########################################################################
        4)
            # Los formatos sin pérdida no tienen bitrate configurable
            if [[ "$IS_LOSSLESS" == "true" ]]; then
                step=5
                continue
            fi

            local quality_raw
            quality_raw=$(yad --list \
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
                --button="◀ Atrás:2" \
                --button="Siguiente ▶:0" 2>/dev/null)

            local rc=$?
            [[ $rc -eq 2 ]] && { step=3; continue; }
            [[ $rc -ne 0 ]] && return 1   # Cancelar o cierre de ventana
            [[ -z "$quality_raw" ]] && continue

            BITRATE_OPT=$(echo "$quality_raw" | tr -d '|' | xargs)
            step=5
            ;;

        ########################################################################
        # PASO 5: SAMPLE RATE
        ########################################################################
        5)
            local -a sr_options=()
            local sr_hint="<i>44100 Hz es estándar para música. 48000 Hz para video.</i>"

            case "$FORMAT" in
                opus)
                    sr_hint="<b>Opus resamplea internamente a un máximo de 48 kHz.</b>"
                    sr_options=(
                        "48000" "48 kHz (Recomendado ✦)" "Estándar Opus"
                        "44100" "44.1 kHz"    "Estándar CD"
                    ) ;;
                mp3)
                    sr_hint="<b>MP3 no soporta frecuencias superiores a 48 kHz.</b>"
                    sr_options=(
                        "48000" "48 kHz ✦"    "Calidad máxima"
                        "44100" "44.1 kHz"    "Estándar CD"
                    ) ;;
                mp2)
                    sr_hint="<b>MP2 solo soporta valores de sample rate estándar.</b>"
                    sr_options=(
                        "48000" "48 kHz"      "Video"
                        "44100" "44.1 kHz ✦"  "Estándar CD"
                    ) ;;
                aac|m4a)
                    sr_hint="<b>AAC soporta hasta 96 kHz (Hi-Res con soporte limitado).</b>"
                    sr_options=(
                        "orig"   "Sin cambios ✦" "Mantener original"
                        "96000"  "96 kHz"        "Estudio / Hi-Res"
                        "88200"  "88.2 kHz"      "Múltiplo de CD"
                        "48000"  "48 kHz"        "Estándar profesional"
                        "44100"  "44.1 kHz"      "Estándar CD"
                    ) ;;
                flac|wav|aiff)
                    sr_hint="<b>Formatos sin pérdida: soportan alta resolución real.</b>"
                    sr_options=(
                        "orig"   "Sin cambios ✦" "Mantener original"
                        "192000" "192 kHz"       "Mastering / Audiófilo"
                        "96000"  "96 kHz"        "Estudio / Hi-Res"
                        "88200"  "88.2 kHz"      "Múltiplo de CD"
                        "48000"  "48 kHz"        "Estándar profesional"
                        "44100"  "44.1 kHz"      "Estándar CD"
                    ) ;;
                *)
                    sr_options=(
                        "orig"  "Sin cambios ✦" "Mantener original"
                        "48000" "48 kHz"        "Video / Streaming"
                        "44100" "44.1 kHz"      "Estándar CD"
                    ) ;;
            esac

            local sr_raw
            sr_raw=$(yad --list \
                --title="🎵 Audio Converter — Sample Rate" \
                --text="<b>Selecciona el sample rate para $FORMAT:</b>\n$sr_hint" \
                --column="Hz" \
                --column="Nombre" \
                --column="Uso típico" \
                "${sr_options[@]}" \
                --width=540 --height=420 \
                --print-column=1 \
                --button="gtk-cancel:1" \
                --button="◀ Atrás:2" \
                --button="Siguiente ▶:0" 2>/dev/null)

            local rc=$?
            if [[ $rc -eq 2 ]]; then
                # Retroceder a bitrate (con pérdida) o a formato (sin pérdida)
                [[ "$IS_LOSSLESS" == "true" ]] && step=3 || step=4
                continue
            fi
            [[ $rc -ne 0 ]] && return 1   # Cancelar o cierre de ventana
            [[ -z "$sr_raw" ]] && continue

            local sr_val
            sr_val=$(echo "$sr_raw" | tr -d '|' | xargs)
            SAMPLE_RATE=""
            [[ "$sr_val" != "orig" ]] && SAMPLE_RATE="$sr_val"
            step=6
            ;;

        ########################################################################
        # PASO 6: BIT DEPTH (solo formatos sin pérdida)
        ########################################################################
        6)
            # Los formatos con pérdida no exponen control de bit depth
            if [[ "$IS_LOSSLESS" == "false" ]]; then
                step=7
                continue
            fi

            local bd_raw
            bd_raw=$(yad --list \
                --title="🎵 Audio Converter — Bit Depth" \
                --text="<b>Selecciona la profundidad de bits:</b>\n<i>Solo aplica a formatos sin pérdida (FLAC, WAV, AIFF).</i>" \
                --column="Formato ffmpeg" \
                --column="Bit Depth" \
                --column="Descripción" \
                "orig" "Sin cambios ✦" "Mantener la profundidad de bits original" \
                "s16"  "16 bits"       "Estándar CD — compatible con todos los reproductores" \
                "s32"  "24 bits (s32)" "Alta resolución — producción y masterización" \
                "s64"  "32 bits float" "Máxima precisión — edición profesional" \
                --width=540 --height=340 \
                --print-column=1 \
                --button="gtk-cancel:1" \
                --button="◀ Atrás:2" \
                --button="Siguiente ▶:0" 2>/dev/null)

            local rc=$?
            [[ $rc -eq 2 ]] && { step=5; continue; }
            [[ $rc -ne 0 ]] && return 1   # Cancelar o cierre de ventana
            [[ -z "$bd_raw" ]] && continue

            local bd_val
            bd_val=$(echo "$bd_raw" | tr -d '|' | xargs)
            BIT_DEPTH=""
            [[ "$bd_val" != "orig" ]] && BIT_DEPTH="$bd_val"
            step=7
            ;;

        ########################################################################
        # PASO 7: CARPETA DE DESTINO
        ########################################################################
        7)
            OUTPUT_DIR=$(yad --file \
                --title="🎵 Audio Converter — Carpeta de Destino" \
                --text="<b>Selecciona la carpeta donde se guardarán los archivos convertidos:</b>" \
                --directory \
                --filename="$LAST_DIR/" \
                --width=750 --height=520 \
                --button="gtk-cancel:1" \
                --button="◀ Atrás:2" \
                --button="Confirmar ✔:0" 2>/dev/null)

            local rc=$?
            if [[ $rc -eq 2 ]]; then
                # Retroceder a bit depth (sin pérdida) o a sample rate (con pérdida)
                [[ "$IS_LOSSLESS" == "true" ]] && step=6 || step=5
                continue
            fi
            [[ $rc -ne 0 ]] && return 1   # Cancelar o cierre de ventana
            [[ -z "$OUTPUT_DIR" ]] && continue

            # Persistir la última carpeta usada
            echo "LAST_DIR=\"$OUTPUT_DIR\"" > "$CONFIG_FILE"
            break
            ;;
        esac
    done

    return 0
}

################################################################################
# FUNCIÓN: Convertir archivo de audio con barra de progreso
# Uso: convert_file INPUT OUTPUT [LABEL_EXTRA]
# Retorna: 0=OK  2=Cancelado por el usuario  otro=Error de FFmpeg
################################################################################
convert_file() {
    local input_file="$1"
    local output_file="$2"
    local label_extra="${3:-}"

    local base_name
    base_name=$(basename "$input_file")

    # Obtener duración del archivo en segundos para calcular el porcentaje
    local raw_dur
    raw_dur=$(ffprobe -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$input_file" 2>/dev/null)
    local dur_int=${raw_dur%.*}
    [[ -z "$dur_int" || ! "$dur_int" =~ ^[0-9]+$ || "$dur_int" -le 0 ]] && dur_int=0

    # FIFO para recibir el progreso en tiempo real desde FFmpeg
    local pipe
    pipe=$(mktemp -u "$TEMP_DIR/pipe_XXXXXX")
    mkfifo "$pipe"

    # Construir flags opcionales de sample rate y bit depth
    local extra_flags=()
    [[ -n "$SAMPLE_RATE" ]] && extra_flags+=(-ar "$SAMPLE_RATE")
    [[ -n "$BIT_DEPTH" && "$IS_LOSSLESS" == "true" ]] && extra_flags+=(-sample_fmt "$BIT_DEPTH")

    # Lanzar FFmpeg en segundo plano según el tipo de formato
    if [[ "$IS_LOSSLESS" == "true" ]]; then
        ffmpeg -hide_banner -loglevel error -y -threads auto \
               -i "$input_file" -vn "${extra_flags[@]}" \
               -progress "$pipe" -nostats \
               "$output_file" &
    else
        ffmpeg -hide_banner -loglevel error -y -threads auto \
               -i "$input_file" -vn -b:a "$BITRATE_OPT" "${extra_flags[@]}" \
               -progress "$pipe" -nostats \
               "$output_file" &
    fi
    local ffmpeg_pid=$!

    # Construir etiqueta de calidad para mostrar en el diálogo
    local qlabel
    if [[ "${WAV_ONLY:-false}" == "true" ]]; then
        qlabel="WAV sin convertir"
    else
        qlabel="$FORMAT"
        [[ -n "$BITRATE_OPT" ]] && qlabel="$FORMAT @ $BITRATE_OPT"
        [[ -n "$SAMPLE_RATE" ]] && qlabel+="  ${SAMPLE_RATE} Hz"
        [[ -n "$BIT_DEPTH"   ]] && qlabel+="  ${BIT_DEPTH}"
    fi

    local dialog_text="<b>Convirtiendo:</b>  <i>$base_name</i>\n  <b>Calidad:</b>  $qlabel"
    [[ -n "$label_extra" ]] && dialog_text+="\n$label_extra"

    # Leer el pipe de progreso y alimentar la barra de YAD
    (
        local pct=0
        while IFS= read -r line; do
            if [[ "$line" =~ ^out_time_ms=([0-9]+)$ ]]; then
                local t="${BASH_REMATCH[1]}"
                if [[ $dur_int -gt 0 ]]; then
                    pct=$(( t / (dur_int * 10000) ))
                    (( pct >= 100 )) && pct=99
                else
                    # Duración desconocida: avanzar cíclicamente hasta 97 %
                    pct=$(( (pct + 1) % 98 ))
                fi
                echo "$pct"
            fi
            [[ "$line" == "progress=end" ]] && echo "100" && break
        done < "$pipe"
    ) | yad --progress \
        --title="🔄 Convirtiendo..." \
        --text="$dialog_text" \
        --percentage=0 \
        --auto-close \
        --width=560 \
        --button="⛔  Cancelar:1" 2>/dev/null

    local yad_exit=$?
    rm -f "$pipe"

    # El usuario presionó Cancelar
    if [[ $yad_exit -ne 0 ]]; then
        kill "$ffmpeg_pid" 2>/dev/null
        wait "$ffmpeg_pid" 2>/dev/null
        rm -f "$output_file"
        yad --warning \
            --title="Cancelado" \
            --text="<b>⚠ Conversión cancelada.</b>\nEl archivo parcial fue eliminado." \
            --width=400 \
            --button="OK:0" 2>/dev/null
        return 2
    fi

    wait "$ffmpeg_pid"
    return $?
}

################################################################################
# FUNCIÓN: Mostrar historial de conversiones
################################################################################
show_history_dialog() {
    if [[ ! -f "$HISTORY_FILE" ]]; then
        yad --info \
            --title="🕑 Historial de conversiones" \
            --text="<i>No hay historial disponible aún.</i>" \
            --width=400 \
            --button="OK:0" 2>/dev/null
        return
    fi

    yad --text-info \
        --title="🕑 Historial de conversiones" \
        --filename="$HISTORY_FILE" \
        --width=800 --height=460 \
        --tail \
        --button="🗑️  Limpiar historial:2" \
        --button="OK:0" 2>/dev/null

    if (( $? == 2 )); then
        > "$HISTORY_FILE"
        yad --info \
            --title="Historial limpiado" \
            --text="El historial ha sido eliminado." \
            --width=300 \
            --button="OK:0" 2>/dev/null
    fi
}

################################################################################
# FUNCIÓN: Mostrar resumen final de conversión
################################################################################
show_final_dialog() {
    local converted=$1
    local failed=$2
    local total=$3
    shift 3
    local files=("$@")

    # Construir etiqueta de calidad del proceso
    local qlabel
    if [[ "${WAV_ONLY:-false}" == "true" ]]; then
        qlabel="WAV sin convertir"
    else
        qlabel="$FORMAT"
        [[ -n "$BITRATE_OPT" ]] && qlabel="$FORMAT @ $BITRATE_OPT"
        [[ -n "$SAMPLE_RATE" ]] && qlabel+="  ${SAMPLE_RATE} Hz"
        [[ -n "$BIT_DEPTH"   ]] && qlabel+="  ${BIT_DEPTH}"
    fi

    local done_text
    done_text="<b><span foreground='#4CAF50' size='large'>✅  ¡Proceso completado!</span></b>\n\n"
    done_text+="  <b>Convertidos:</b>  $converted de $total\n"
    [[ $failed -gt 0 ]] && \
        done_text+="  <b><span foreground='#F44336'>Fallidos:</span></b>  $failed\n"
    done_text+="  <b>Formato:</b>  $qlabel\n"
    done_text+="  <b>Ubicación:</b>  $OUTPUT_DIR\n\n"

    # Listar hasta 8 archivos generados con su tamaño
    if [[ ${#files[@]} -gt 0 ]]; then
        done_text+="<b>Archivos generados:</b>\n"
        local limit=$(( ${#files[@]} < 8 ? ${#files[@]} : 8 ))
        for (( i = 0; i < limit; i++ )); do
            local cf="${files[$i]}"
            local fsize
            fsize=$(du -sh "$cf" 2>/dev/null | cut -f1)
            done_text+="  📄 $(basename "$cf")  <i>($fsize)</i>\n"
        done
        (( ${#files[@]} > 8 )) && \
            done_text+="  … y $(( ${#files[@]} - 8 )) archivo(s) más\n"
    fi

    yad --info \
        --title="✅ Conversión completada" \
        --text="$done_text" \
        --width=580 --height=360 \
        --button="🕑  Historial:3" \
        --button="📂  Abrir carpeta:2" \
        --button="✔️  Finalizar:0" 2>/dev/null

    local btn=$?
    [[ $btn -eq 2 ]] && xdg-open "$OUTPUT_DIR" &
    [[ $btn -eq 3 ]] && show_history_dialog
}

################################################################################
# FUNCIÓN PRINCIPAL DE CONVERSIÓN DE ARCHIVOS LOCALES
################################################################################
process_conversions() {
    local converted=0
    local failed=0
    local -a converted_files=()
    local file_number=0
    local total_files=${#INPUT_FILES[@]}

    for input_file in "${INPUT_FILES[@]}"; do
        (( file_number++ ))

        local base_name="${input_file##*/}"
        local fname="${base_name%.*}"
        local safe_name
        safe_name=$(clean_filename "$fname")
        local output_file="$OUTPUT_DIR/$safe_name.$FORMAT"

        # Resolver conflicto si el archivo de destino ya existe
        if [[ -f "$output_file" ]]; then
            resolve_conflict "$output_file" "$safe_name" "$FORMAT" "$OUTPUT_DIR"
            [[ "$SKIP_FILE" == "true" ]] && { (( failed++ )); continue; }
            output_file="$OUTPUT_FILE"
        fi

        convert_file "$input_file" "$output_file" \
            "  <b>Archivo</b>  $file_number de $total_files"
        local conv_result=$?

        if (( conv_result == 2 )); then
            return 2
        fi

        if (( conv_result == 0 )); then
            (( converted++ ))
            converted_files+=("$output_file")

            local hist_label="${BITRATE_OPT:-lossless}"
            [[ -n "$SAMPLE_RATE" ]] && hist_label+=" ${SAMPLE_RATE} Hz"
            [[ -n "$BIT_DEPTH"   ]] && hist_label+=" ${BIT_DEPTH}"
            echo "$(date '+%Y-%m-%d %H:%M')  |  $base_name  →  $(basename "$output_file")  |  $hist_label  |  $OUTPUT_DIR" \
                >> "$HISTORY_FILE"
        else
            (( failed++ ))
            rm -f "$output_file"
        fi
    done

    show_final_dialog "$converted" "$failed" "$total_files" "${converted_files[@]}"
}

################################################################################
# FLUJO PRINCIPAL — MODO A: ARCHIVOS LOCALES  /  MODO B: CD DE AUDIO
################################################################################

verify_dependencies
LAST_DIR=$(load_config)

# ── Menú principal: selección de modo ────────────────────────────────────────
MODE=$(yad --list \
    --title="🎵 Audio Converter" \
    --text="<b>¿Qué deseas convertir?</b>" \
    --column="Modo" \
    --column="Descripción" \
    "🗂  Archivos locales" "Convierte archivos de audio desde tu disco" \
    "💿  CD de audio"      "Ripea y convierte pistas desde un CD" \
    --width=480 --height=230 \
    --print-column=1 \
    --no-headers \
    --button="gtk-cancel:1" \
    --button="Continuar ▶:0" 2>/dev/null)

[[ $? -ne 0 || -z "$MODE" ]] && exit 0
MODE=$(echo "$MODE" | tr -d '|' | xargs)

# =============================================================================
#  MODO A — ARCHIVOS LOCALES
# =============================================================================

if [[ "$MODE" == *"Archivos locales"* ]]; then

    # ── Paso 1: Selección de archivos (solo una vez) ──────────────────────────
    if ! select_input_files; then
        exit 0
    fi

    # ── Loop principal: permite volver al paso 2 ──────────────────────────────
    while true; do

        # ── Paso 2: Confirmar archivos ────────────────────────────────────────
        if ! confirm_input_files; then
            if ! select_input_files; then
                exit 0
            fi
            continue
        fi

        # ── Pasos 3-7: Configuración de conversión ────────────────────────────
        select_audio_options 3
        local_rc=$?

        if (( local_rc == 1 )); then
            exit 0
        elif (( local_rc == 2 )); then
            continue
        fi

        # ── Conversión ────────────────────────────────────────────────────────
        process_conversions
        conv_rc=$?

        if (( conv_rc == 2 )); then
            continue
        fi

        exit 0
    done

# =============================================================================
#  MODO B — CD DE AUDIO
# =============================================================================

elif [[ "$MODE" == *"CD de audio"* ]]; then

    # ── Detectar dispositivo de CD ────────────────────────────────────────────
    CD_DEV=""
    for dev in /dev/cdrom /dev/sr0 /dev/sr1 /dev/dvd; do
        [[ -b "$dev" ]] && CD_DEV="$dev" && break
    done

    if [[ -z "$CD_DEV" ]]; then
        yad --error \
            --title="CD no encontrado" \
            --text="<b>❌ No se detectó ningún dispositivo de CD.</b>\n\nVerifica que:\n  • El CD está insertado correctamente\n  • El dispositivo existe en /dev/cdrom o /dev/sr0" \
            --width=440 \
            --button="OK:0" 2>/dev/null
        exit 1
    fi

    # ── Leer tabla de contenidos (TOC) y disc-id ──────────────────────────────
    yad --progress \
        --title="💿 Leyendo CD..." \
        --text="<b>Leyendo tabla de contenidos del disco...</b>" \
        --pulsate --auto-close --no-buttons --width=420 2>/dev/null &
    PULSE_PID=$!

    DISC_ID=$(cd-discid "$CD_DEV" 2>/dev/null)
    CD_INFO=$(cdparanoia -Q -d "$CD_DEV" 2>&1)

    kill "$PULSE_PID" 2>/dev/null
    wait "$PULSE_PID" 2>/dev/null

    if [[ -z "$DISC_ID" ]]; then
        yad --error \
            --title="Error al leer CD" \
            --text="<b>❌ No se pudo leer el CD.</b>\n\nVerifica que es un CD de audio válido y que no está dañado." \
            --width=420 \
            --button="OK:0" 2>/dev/null
        exit 1
    fi

    # ── Parsear pistas del TOC de cdparanoia ─────────────────────────────────
    # Formato de salida de cdparanoia -Q:
    #   N.    SECTORS [MM:SS.FF]    OFFSET [MM:SS.FF]    pre  copy  channels
    # Capturamos: número de pista y duración [MM:SS]
    declare -a TRACKS_DATA
    declare -A TRACK_DUR_STR

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]+([0-9]+)\.[[:space:]]+[0-9]+[[:space:]]+\[([0-9]+):([0-9]+)\.[0-9]+\] ]]; then
            TNUM="${BASH_REMATCH[1]}"
            T_MIN="${BASH_REMATCH[2]}"
            T_SEC="${BASH_REMATCH[3]}"
            TRACK_DUR_STR[$TNUM]="${T_MIN}:${T_SEC}"
            TRACKS_DATA+=("$TNUM" "${T_MIN}:${T_SEC}")
        fi
    done <<< "$CD_INFO"

    if [[ ${#TRACKS_DATA[@]} -eq 0 ]]; then
        yad --error \
            --title="Error al leer pistas" \
            --text="<b>❌ No se pudieron leer las pistas del CD.</b>\n\nIntenta limpiar el disco y vuelve a intentarlo." \
            --width=480 \
            --button="OK:0" 2>/dev/null
        exit 1
    fi

    # ── Consultar metadata en gnudb (protocolo freedb) ───────────────────────
    yad --progress \
        --title="💿 Buscando metadata..." \
        --text="<b>Consultando gnudb.gnudb.org...</b>\n<i>Buscando artista, álbum y nombres de pistas</i>" \
        --pulsate --auto-close --no-buttons --width=440 2>/dev/null &
    PULSE_PID=$!

    # Descomponer el disc-id en sus partes: DISCID TRACKS OFF1 ... TOTAL_SECS
    DISC_ID_PARTS=($DISC_ID)
    DISCID_HEX="${DISC_ID_PARTS[0]}"
    NUM_TRACKS_ID="${DISC_ID_PARTS[1]}"
    OFFSETS=("${DISC_ID_PARTS[@]:2:$NUM_TRACKS_ID}")
    TOTAL_SECS="${DISC_ID_PARTS[-1]}"
    OFFSETS_QUERY=$(IFS=+; echo "${OFFSETS[*]}")

    # Construir URL de consulta al servidor gnudb
    GNUDB_QUERY="cmd=cddb+query+${DISCID_HEX}+${NUM_TRACKS_ID}+${OFFSETS_QUERY}+${TOTAL_SECS}"
    GNUDB_HELLO="hello=$(whoami)+$(hostname)+AudioConverter+1.0"
    GNUDB_URL="http://gnudb.gnudb.org/~cddb/cddb.cgi?${GNUDB_QUERY}&${GNUDB_HELLO}&proto=6"

    # Usar caché local para evitar consultar gnudb en discos ya procesados
    if [[ -f "$CACHE_DIR/$DISCID_HEX" ]]; then
        GNUDB_RESULT=$(cat "$CACHE_DIR/$DISCID_HEX")
    else
        GNUDB_RESULT=$(curl -sL -A "AudioConverter/1.0" --max-time 10 "$GNUDB_URL" 2>/dev/null)
        [[ -n "$GNUDB_RESULT" ]] && echo "$GNUDB_RESULT" > "$CACHE_DIR/$DISCID_HEX"
    fi

    # Valores por defecto si no se encuentra metadata
    ARTIST="Desconocido"
    ALBUM="CD de Audio"
    YEAR=""
    declare -A TRACK_NAMES
    META_SOURCE="<span foreground='#FF9800'>⚠ Metadata no encontrada — usando nombres genéricos</span>"

    if [[ -n "$GNUDB_RESULT" ]]; then
        RESP_CODE=$(echo "$GNUDB_RESULT" | head -1 | awk '{print $1}')

        # Códigos de respuesta: 200=exacta  210=múltiple (lista)  211=resultado aproximado
        if [[ "$RESP_CODE" == "200" || "$RESP_CODE" == "210" || "$RESP_CODE" == "211" ]]; then

            if [[ "$RESP_CODE" == "200" ]]; then
                # Coincidencia exacta: leer categoría e ID de la primera línea
                CDDB_CAT=$(echo "$GNUDB_RESULT" | head -1 | awk '{print $2}')
                CDDB_ID=$(echo  "$GNUDB_RESULT" | head -1 | awk '{print $3}')
            else
                # Coincidencias múltiples: tomar el primer resultado (línea 2)
                CDDB_CAT=$(echo "$GNUDB_RESULT" | sed -n '2p' | awk '{print $1}')
                CDDB_ID=$(echo  "$GNUDB_RESULT" | sed -n '2p' | awk '{print $2}')
            fi

            # Obtener la entrada completa del disco
            READ_URL="http://gnudb.gnudb.org/~cddb/cddb.cgi?cmd=cddb+read+${CDDB_CAT}+${CDDB_ID}&${GNUDB_HELLO}&proto=6"
            CDDB_ENTRY=$(curl -sL -A "AudioConverter/1.0" --max-time 10 "$READ_URL" 2>/dev/null)

            # gnudb usa line endings Windows (\r\n); normalizar a Unix (\n)
            CDDB_ENTRY=$(printf '%s' "$CDDB_ENTRY" | tr -d '\r')

            # CDs antiguos pueden tener metadata en ISO-8859-1; convertir si no es UTF-8 válido
            if ! printf '%s' "$CDDB_ENTRY" | iconv -f utf-8 -t utf-8 >/dev/null 2>&1; then
                CDDB_ENTRY=$(printf '%s' "$CDDB_ENTRY" \
                    | iconv -f iso-8859-1 -t utf-8 2>/dev/null \
                    || printf '%s' "$CDDB_ENTRY")
            fi

            if [[ -n "$CDDB_ENTRY" ]]; then
                DTITLE=$(echo "$CDDB_ENTRY" | grep "^DTITLE=" | head -1 | cut -d= -f2-)
                DYEAR=$(echo  "$CDDB_ENTRY" | grep "^DYEAR="  | head -1 | cut -d= -f2-)

                # DTITLE puede venir como "Artista / Álbum" o solo "Álbum"
                if [[ "$DTITLE" == *" / "* ]]; then
                    ARTIST=$(echo "$DTITLE" | sed 's/ \/ .*//')
                    ALBUM=$(echo  "$DTITLE" | sed 's/.*\/ //')
                else
                    ALBUM="$DTITLE"
                fi
                [[ -n "$DYEAR" ]] && YEAR="$DYEAR"

                # Extraer nombres de pistas (TTITLEn está indexado desde 0)
                while IFS= read -r line; do
                    if [[ "$line" =~ ^TTITLE([0-9]+)=(.+)$ ]]; then
                        IDX="${BASH_REMATCH[1]}"
                        NAME="${BASH_REMATCH[2]}"
                        TRACK_NAMES[$(( IDX + 1 ))]="$NAME"
                    fi
                done <<< "$CDDB_ENTRY"

                META_SOURCE="<span foreground='#4CAF50'>✔ Metadata encontrada en gnudb</span>"
            fi
        fi
    fi

    kill "$PULSE_PID" 2>/dev/null
    wait "$PULSE_PID" 2>/dev/null

    # ── Construir lista de pistas para el checklist ───────────────────────────
    declare -a TRACKS_LIST
    for (( i = 0; i < ${#TRACKS_DATA[@]}; i += 2 )); do
        TNUM="${TRACKS_DATA[$i]}"
        T_DUR="${TRACKS_DATA[$(( i + 1 ))]}"
        TNAME="${TRACK_NAMES[$TNUM]:-Pista $TNUM}"
        TRACKS_LIST+=("TRUE" "$TNUM" "$TNAME" "$T_DUR")
    done

    YEAR_STR=""
    [[ -n "$YEAR" ]] && YEAR_STR=" ($YEAR)"

    # ── Funciones auxiliares para el modo de ripeado ──────────────────────────

    # Muestra el diálogo de selección de velocidad/modo de ripeado
    _show_speed_dialog() {
        RIP_SPEED_RAW=$(yad --list \
            --title="💿 CD de Audio — Modo de Ripeado" \
            --text="<b>Selecciona cómo deseas ripear el CD:</b>\n<i>«Solo WAV» guarda las pistas tal cual, sin convertir ni recodificar.</i>" \
            --column="Modo" \
            --column="Velocidad estimada" \
            --column="Descripción" \
            "Rápido"    "5–10x más rápido"  "Conversión al formato elegido — recomendado para CDs limpios  ✦" \
            "Normal"    "2–3x más rápido"   "Conversión al formato elegido — con corrección básica de errores" \
            "Paranoid"  "Tiempo real"       "Conversión al formato elegido — para CDs rayados o dañados" \
            "Solo WAV"  "5–10x más rápido"  "Copia WAV sin convertir — máxima fidelidad, sin recodificación" \
            --width=660 --height=310 \
            --print-column=1 \
            --button="gtk-cancel:1" \
            --button="◀ Atrás:2" \
            --button="Siguiente ▶:0" 2>/dev/null)
        return $?
    }

    # Aplica los flags de cdparanoia según el modo seleccionado
    _apply_speed() {
        RIP_SPEED=$(echo "$RIP_SPEED_RAW" | tr -d '|' | xargs)
        case "$RIP_SPEED" in
            "Rápido")   CDPARA_FLAGS="-Z"; WAV_ONLY=false ;;
            "Normal")   CDPARA_FLAGS="-z"; WAV_ONLY=false ;;
            "Paranoid") CDPARA_FLAGS="";   WAV_ONLY=false ;;
            "Solo WAV") CDPARA_FLAGS="-Z"; WAV_ONLY=true  ;;
            *)          CDPARA_FLAGS="-Z"; WAV_ONLY=false ;;
        esac
    }

    # ── Bucle principal: Selección de pistas → Modo de ripeado → Formato/Carpeta ──
    WAV_ONLY=false
    FORMAT="wav"       # valor por defecto; se sobreescribe si el usuario elige conversión
    CDPARA_FLAGS="-Z"
    SEL_TRACKS=()

    while true; do

        # ── Selección de pistas a ripear ──────────────────────────────────────
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
        [[ $BTN_TRACKS -ne 0 && $BTN_TRACKS -ne 2 ]] && exit 0   # Cancelar o cierre de ventana

        if [[ $BTN_TRACKS -eq 2 ]]; then
            # Seleccionar todas las pistas detectadas
            SEL_TRACKS=()
            for (( i = 0; i < ${#TRACKS_DATA[@]}; i += 2 )); do
                SEL_TRACKS+=("${TRACKS_DATA[$i]}")
            done
        else
            # Parsear los números de pista seleccionados del output de YAD
            SEL_TRACKS=()
            while IFS= read -r t; do
                t="${t//|/}"
                t="${t#"${t%%[![:space:]]*}"}"
                [[ -n "$t" ]] && SEL_TRACKS+=("$t")
            done <<< "$SELECTED_RAW"
        fi

        if [[ ${#SEL_TRACKS[@]} -eq 0 ]]; then
            yad --warning \
                --title="Sin selección" \
                --text="No seleccionaste ninguna pista." \
                --width=360 \
                --button="OK:0" 2>/dev/null
            continue   # Volver a mostrar el checklist de pistas
        fi

        # ── Modo de ripeado ───────────────────────────────────────────────────
        _show_speed_dialog
        RC=$?
        [[ $RC -ne 0 && $RC -ne 2 ]] && exit 0   # Cancelar o cierre de ventana
        if [[ $RC -eq 2 ]]; then
            continue   # Atrás → volver al checklist de pistas
        fi
        [[ -z "$RIP_SPEED_RAW" ]] && continue
        _apply_speed

        # ── Formato/Carpeta de destino ────────────────────────────────────────
        if [[ "$WAV_ONLY" == "true" ]]; then
            OUTPUT_DIR=$(yad --file \
                --title="💿 CD de Audio — Carpeta de Destino (WAV)" \
                --text="<b>Selecciona la carpeta donde se guardarán los archivos WAV:</b>\n<i>Se creará una subcarpeta con el nombre del álbum.</i>" \
                --directory \
                --filename="$LAST_DIR/" \
                --width=750 --height=520 \
                --button="gtk-cancel:1" \
                --button="◀ Atrás:2" \
                --button="Confirmar ✔:0" 2>/dev/null)

            RC=$?
            if [[ $RC -eq 2 ]]; then
                continue   # Atrás → volver al checklist de pistas
            fi
            [[ $RC -ne 0 ]] && exit 0             # Cancelar o cierre de ventana
            [[ -z "$OUTPUT_DIR" ]] && continue

            echo "LAST_DIR=\"$OUTPUT_DIR\"" > "$CONFIG_FILE"
            FORMAT="wav"
            IS_LOSSLESS=true
            BITRATE_OPT=""
            break
        else
            select_audio_options 3
            RC=$?
            [[ $RC -ne 0 && $RC -ne 2 ]] && exit 0   # Cancelar o cierre de ventana
            [[ $RC -eq 0 ]] && break
            # RC=2: Atrás desde Formato → volver al checklist de pistas
        fi

    done

    # ── Crear subcarpeta del álbum ────────────────────────────────────────────
    SAFE_ALBUM=$(clean_filename "$ALBUM")
    ALBUM_DIR="$OUTPUT_DIR/$SAFE_ALBUM"
    mkdir -p "$ALBUM_DIR"

    # ── Ripeado y conversión de cada pista seleccionada ───────────────────────
    CONVERTED=0
    FAILED=0
    CONVERTED_FILES=()
    TOTAL_SEL=${#SEL_TRACKS[@]}

    for TNUM in "${SEL_TRACKS[@]}"; do
        TRACK_IDX=$(( CONVERTED + FAILED + 1 ))
        TNAME="${TRACK_NAMES[$TNUM]:-Pista $TNUM}"
        SAFE_TNAME=$(clean_filename "$TNAME")
        TRACK_FILENAME=$(printf "%02d - %s" "$TNUM" "$SAFE_TNAME")
        WAV_FILE="$TEMP_DIR/track${TNUM}.wav"
        OUTPUT_FILE="$ALBUM_DIR/$TRACK_FILENAME.$FORMAT"

        # Resolver conflicto si el archivo ya existe en el destino
        if [[ -f "$OUTPUT_FILE" ]]; then
            resolve_conflict "$OUTPUT_FILE" "$TRACK_FILENAME" "$FORMAT" "$ALBUM_DIR"
            [[ "$SKIP_FILE" == "true" ]] && continue
        fi

        # ── Ripeado con cdparanoia ──────────────────────────────────────────
        RIP_LOG="$TEMP_DIR/rip_${TNUM}.log"
        RIP_PIPE=$(mktemp -u /tmp/audioconv_RIP_XXXXXX)
        mkfifo "$RIP_PIPE"
        trap "rm -f '$RIP_PIPE'" PIPE   # limpiar el pipe ante señal SIGPIPE

        # Iniciar cdparanoia en segundo plano
        cdparanoia ${CDPARA_FLAGS} -d "$CD_DEV" "$TNUM" "$WAV_FILE" \
            > "$RIP_LOG" 2>&1 &
        CDPARA_PID=$!

        # Proceso feeder: envía pulsos de progreso mientras cdparanoia esté activo
        (
            while kill -0 "$CDPARA_PID" 2>/dev/null; do
                echo "1"
                sleep 0.5
            done
            echo "100"   # forzar cierre de la barra al terminar
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

        # Detener el feeder y limpiar el pipe
        kill "$FEEDER_PID" 2>/dev/null
        wait "$FEEDER_PID" 2>/dev/null
        rm -f "$RIP_PIPE"

        if [[ $YAD_RIP -ne 0 ]]; then
            # El usuario canceló el ripeado
            kill "$CDPARA_PID" 2>/dev/null
            wait "$CDPARA_PID" 2>/dev/null
            rm -f "$WAV_FILE" "$RIP_LOG"
            yad --warning \
                --title="Cancelado" \
                --text="<b>⚠ Ripeado cancelado.</b>" \
                --width=380 \
                --button="OK:0" 2>/dev/null
            exit 0
        fi

        wait "$CDPARA_PID"
        RIP_EXIT=$?

        if [[ $RIP_EXIT -ne 0 || ! -f "$WAV_FILE" ]]; then
            yad --error \
                --title="Error al ripear" \
                --text="<b>❌ Error al ripear la pista $TNUM.</b>\n\nRevisa que el CD no esté rayado o dañado." \
                --width=400 \
                --button="OK:0" 2>/dev/null
            (( FAILED++ ))
            continue
        fi

        # ── Conversión WAV → formato destino (o copiar si es Solo WAV) ────────
        if [[ "$WAV_ONLY" == "true" ]]; then
            mv "$WAV_FILE" "$OUTPUT_FILE"
            CONV_RESULT=$?
        else
            convert_file "$WAV_FILE" "$OUTPUT_FILE" \
                "  <b>Álbum:</b>  $ALBUM  —  Pista $TNUM / $TOTAL_SEL"
            CONV_RESULT=$?
            rm -f "$WAV_FILE"
            [[ $CONV_RESULT -eq 2 ]] && exit 0   # Cancelado por el usuario
        fi

        # ── Incrustar metadata con FFmpeg ─────────────────────────────────────
        if [[ $CONV_RESULT -eq 0 ]]; then
            TMP_META="$TEMP_DIR/meta_${TNUM}.$FORMAT"
            META_ARGS=(
                -metadata "title=$TNAME"
                -metadata "artist=$ARTIST"
                -metadata "album=$ALBUM"
                -metadata "track=$TNUM"
            )
            [[ -n "$YEAR" ]] && META_ARGS+=(-metadata "date=$YEAR")

            ffmpeg -hide_banner -loglevel error -y \
                   -i "$OUTPUT_FILE" -vn "${META_ARGS[@]}" -codec copy \
                   "$TMP_META" \
                && mv "$TMP_META" "$OUTPUT_FILE" \
                || rm -f "$TMP_META"

            (( CONVERTED++ ))
            CONVERTED_FILES+=("$OUTPUT_FILE")

            # Registrar en historial
            QLABEL="${WAV_ONLY:+WAV sin convertir}"
            [[ -z "$QLABEL" ]] && QLABEL="${BITRATE_OPT:-lossless}"
            echo "$(date '+%Y-%m-%d %H:%M')  |  CD: $ALBUM — $TNAME  →  $TRACK_FILENAME.$FORMAT  |  $QLABEL  |  $ALBUM_DIR" \
                >> "$HISTORY_FILE"
        else
            (( FAILED++ ))
            rm -f "$OUTPUT_FILE"
        fi
    done

    # ── Resumen final y expulsión del disco ───────────────────────────────────
    OUTPUT_DIR="$ALBUM_DIR"
    show_final_dialog "$CONVERTED" "$FAILED" "$TOTAL_SEL" "${CONVERTED_FILES[@]}"

    # Expulsar el CD; limpiar CD_DEV para que el trap no lo expulse por segunda vez
    eject "$CD_DEV" 2>/dev/null
    CD_DEV=""

fi

exit 0
