#!/bin/bash
################################################################################
# Audio Converter V1 — YAD + FFmpeg/FFprobe
#
# Convierte archivos de audio locales en lote con interfaz gráfica interactiva.
# Permite seleccionar formato, bitrate, sample rate y opciones de calidad.
#
# REQUISITOS: yad, ffmpeg, ffprobe, numfmt (coreutils)
# USO: ./audio_converter.sh
################################################################################

################################################################################
# CONFIGURACIÓN GLOBAL
################################################################################
readonly CONFIG_DIR="$HOME/.config/audio_converter"
readonly CONFIG_FILE="$CONFIG_DIR/settings.conf"
readonly HISTORY_FILE="$CONFIG_DIR/history.log"
readonly TEMP_DIR=$(mktemp -d /tmp/audioconv_XXXXXX)
WAV_ONLY=false

mkdir -p "$CONFIG_DIR"

################################################################################
# MANEJO DE LIMPIEZA Y TRAPS
################################################################################
cleanup() {
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
            # Opus siempre resamplea internamente a 48000 Hz — saltar el diálogo
            if [[ "$FORMAT" == "opus" ]]; then
                SAMPLE_RATE="48000"
                step=6
                continue
            fi

            local -a sr_options=()
            local sr_hint="<i>44100 Hz es estándar para música. 48000 Hz para video.</i>"

            case "$FORMAT" in
                opus)
                    sr_hint="<b>Opus resamplea internamente a un máximo de 48 kHz.</b>"
                    sr_options=(
                        "48000" "48 kHz (Recomendado ✦)" "Estándar Opus"
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
# FLUJO PRINCIPAL
################################################################################
main() {
    verify_dependencies
    LAST_DIR=$(load_config)

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
        local config_result=$?

        if (( config_result == 1 )); then
            exit 0
        elif (( config_result == 2 )); then
            continue
        fi

        # ── Conversión ────────────────────────────────────────────────────────
        process_conversions
        local conv_result=$?

        if (( conv_result == 2 )); then
            continue
        fi

        exit 0
    done
}

main "$@"
exit 0
