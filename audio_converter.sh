#!/bin/bash
################################################################################
# Audio Converter v2 — YAD + FFmpeg/FFprobe
# 
# Convierte archivos de audio locales en lote con interfaz gráfica interactiva.
# Permite seleccionar formato, bitrate, sample rate y opciones de calidad.
#
# REQUISITOS: yad, ffmpeg, ffprobe, numfmt (coreutils)
# USO: ./audio_converter_fixed.sh
################################################################################

################################################################################
# CONFIGURACIÓN GLOBAL
################################################################################
readonly CONFIG_DIR="$HOME/.config/audio_converter"
readonly CONFIG_FILE="$CONFIG_DIR/settings.conf"
readonly HISTORY_FILE="$CONFIG_DIR/history.log"
readonly TEMP_DIR=$(mktemp -d /tmp/audioconv_XXXXXX)

# Crear directorio de configuración si no existe
mkdir -p "$CONFIG_DIR"

################################################################################
# MANEJO DE LIMPIEZA Y TRAPS
################################################################################
cleanup() {
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}

trap cleanup EXIT HUP INT TERM

################################################################################
# VERIFICACIÓN DE DEPENDENCIAS REQUERIDAS
################################################################################
verify_dependencies() {
    local missing_deps=()
    local required_commands=("yad" "ffmpeg" "ffprobe" "numfmt")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if (( ${#missing_deps[@]} > 0 )); then
        local msg="<b>❌ Faltan dependencias necesarias:</b>\n\n"
        for dep in "${missing_deps[@]}"; do
            msg+="  • <b>$dep</b>\n"
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
    
    if [[ -f "$CONFIG_FILE" ]]; then
        # Sourcing seguro con validación
        source "$CONFIG_FILE" 2>/dev/null || true
    fi
    
    echo "$last_dir"
}

################################################################################
# FUNCIÓN: Limpiar caracteres inválidos en nombres de archivo
################################################################################
clean_filename() {
    local filename="$1"
    
    # Reemplazar caracteres especiales por guiones
    filename=$(echo "$filename" | sed 's/[/:*?"<>|\\]/-/g')
    
    # Eliminar espacios múltiples
    filename=$(echo "$filename" | sed 's/--*/-/g')
    
    # Eliminar guiones al inicio/final
    filename="${filename#-}"
    filename="${filename%-}"
    
    echo "$filename"
}

################################################################################
# FUNCIÓN: Resolver conflictos de nombre de archivo duplicado
################################################################################
resolve_conflict() {
    local existing_file="$1"
    local filename="$2"
    local format="$3"
    local output_dir="$4"
    
    local file_size
    local file_date
    local base_name
    
    # Obtener información del archivo existente
    file_size=$(du -sh "$existing_file" 2>/dev/null | cut -f1)
    file_date=$(stat -c "%y" "$existing_file" 2>/dev/null | cut -d. -f1)
    base_name=$(basename "$existing_file")
    
    # Mostrar diálogo de conflicto
    local action
    action=$(yad --list \
        --title="⚠️  Archivo ya existe" \
        --text="<b>El archivo ya existe en el sistema:</b>\n\n  📄 <b>$base_name</b>\n  Tamaño: <i>$file_size</i> | Modificado: <i>$file_date</i>\n\n<b>¿Qué deseas hacer?</b>" \
        --column="Acción" \
        --column="Descripción" \
        "Reemplazar"  "Sobreescribir completamente" \
        "Renombrar"   "Guardar con número secuencial" \
        "Omitir"      "Saltar este archivo" \
        --print-column=1 \
        --width=520 \
        --height=260 \
        --button="Confirmar:0" 2>/dev/null)
    
    # Limpiar salida
    action=$(echo "$action" | tr -d '|' | xargs)
    
    case "$action" in
        Reemplazar)
            echo "$existing_file"
            return 0
            ;;
        Renombrar)
            local counter=1
            while [[ -f "$output_dir/${filename}_${counter}.$format" ]]; do
                ((counter++))
            done
            echo "$output_dir/${filename}_${counter}.$format"
            return 0
            ;;
        *)
            # Omitir
            return 1
            ;;
    esac
}

################################################################################
# FUNCIÓN: Convertir archivo de audio con progreso real
################################################################################
convert_file() {
    local input_file="$1"
    local output_file="$2"
    local file_num="$3"
    local total_files="$4"
    
    local base_name
    local duration_seconds
    local pipe_file
    local extra_flags=()
    local ffmpeg_pid
    local quality_label
    local dialog_text
    
    base_name=$(basename "$input_file")
    
    # Obtener duración del archivo para calcular porcentaje
    duration_seconds=$(ffprobe -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$input_file" 2>/dev/null)
    
    # Validar duración
    if [[ ! "$duration_seconds" =~ ^[0-9]+\.?[0-9]*$ ]] || (( $(echo "$duration_seconds <= 0" | bc -l) )); then
        duration_seconds=0
    else
        duration_seconds="${duration_seconds%.*}"
    fi
    
    # Crear archivo de tubería para progreso
    pipe_file=$(mktemp -u "$TEMP_DIR/pipe_XXXXXX")
    mkfifo "$pipe_file" 2>/dev/null || return 1
    
    # Construir flags opcionales
    [[ -n "$SAMPLE_RATE" ]] && extra_flags+=(-ar "$SAMPLE_RATE")
    [[ "$IS_LOSSLESS" == "true" && -n "$BIT_DEPTH" ]] && \
        extra_flags+=(-sample_fmt "$BIT_DEPTH")
    
    # Ejecutar ffmpeg con barra de progreso
    if [[ "$IS_LOSSLESS" == "true" ]]; then
        ffmpeg -hide_banner -loglevel error -y -threads auto \
            -i "$input_file" "${extra_flags[@]}" \
            -progress "$pipe_file" -nostats \
            "$output_file" &>/dev/null &
    else
        ffmpeg -hide_banner -loglevel error -y -threads auto \
            -i "$input_file" -b:a "$BITRATE_OPT" "${extra_flags[@]}" \
            -progress "$pipe_file" -nostats \
            "$output_file" &>/dev/null &
    fi
    ffmpeg_pid=$!
    
    # Construir etiqueta de calidad
    quality_label="$FORMAT"
    [[ -n "$BITRATE_OPT" ]] && quality_label="$FORMAT @ $BITRATE_OPT"
    [[ -n "$SAMPLE_RATE" ]] && quality_label+=" @ ${SAMPLE_RATE}Hz"
    [[ "$IS_LOSSLESS" == "true" && -n "$BIT_DEPTH" ]] && \
        quality_label+=" (${BIT_DEPTH})"
    
    # Construir texto del diálogo
    dialog_text="<b>Archivo $file_num de $total_files</b>\n\n"
    dialog_text+="  📄 <b>Origen:</b>  <i>$base_name</i>\n"
    dialog_text+="  🎚️  <b>Calidad:</b>  <i>$quality_label</i>\n"
    dialog_text+="  💾 <b>Destino:</b>  <i>$OUTPUT_DIR</i>"
    
    # Procesar barra de progreso
    (
        local percentage=0
        while IFS= read -r line; do
            if [[ "$line" =~ ^out_time_ms=([0-9]+)$ ]]; then
                local time_ms="${BASH_REMATCH[1]}"
                
                if (( duration_seconds > 0 )); then
                    percentage=$(( time_ms / (duration_seconds * 10000) ))
                    (( percentage >= 100 )) && percentage=99
                else
                    percentage=$(( (percentage + 1) % 98 ))
                fi
                echo "$percentage"
            fi
            
            [[ "$line" == "progress=end" ]] && { echo "100"; break; }
        done < "$pipe_file"
    ) | yad --progress \
        --title="🔄 Convirtiendo ($file_num / $total_files)..." \
        --text="$dialog_text" \
        --percentage=0 \
        --auto-close \
        --width=580 \
        --no-buttons \
        --button="⛔ Cancelar:1" 2>/dev/null
    
    local dialog_exit=$?
    
    # Limpiar archivo de tubería
    rm -f "$pipe_file" 2>/dev/null
    
    # Manejar cancelación
    if (( dialog_exit != 0 )); then
        kill "$ffmpeg_pid" 2>/dev/null
        wait "$ffmpeg_pid" 2>/dev/null
        rm -f "$output_file" 2>/dev/null
        
        yad --warning \
            --title="⛔ Conversión cancelada" \
            --text="<b>La conversión fue cancelada por el usuario.</b>\n\nArchivo parcial eliminado." \
            --width=420 \
            --button="OK:0" 2>/dev/null
        
        return 2
    fi
    
    # Esperar a que termine ffmpeg
    wait "$ffmpeg_pid"
    return $?
}

################################################################################
# FUNCIÓN: Mostrar diálogo final con resumen de conversión
################################################################################
show_final_dialog() {
    local converted_count="$1"
    local failed_count="$2"
    local total_count="$3"
    shift 3
    local converted_files=("$@")
    
    local quality_label="$FORMAT"
    [[ -n "$BITRATE_OPT" ]] && quality_label="$FORMAT @ $BITRATE_OPT"
    [[ -n "$SAMPLE_RATE" ]] && quality_label+=" @ ${SAMPLE_RATE}Hz"
    [[ "$IS_LOSSLESS" == "true" && -n "$BIT_DEPTH" ]] && \
        quality_label+=" (${BIT_DEPTH})"
    
    # Construir texto del resultado
    local result_text="<b><span foreground='#4CAF50' size='large'>✅ ¡Proceso completado!</span></b>\n\n"
    result_text+="<b>Estadísticas de conversión:</b>\n"
    result_text+="  ✔️  <b>Convertidos:</b>  <b>$converted_count / $total_count</b>\n"
    
    if (( failed_count > 0 )); then
        result_text+="  ❌ <b>Omitidos/Fallidos:</b>  <b><span foreground='#F44336'>$failed_count</span></b>\n"
    fi
    
    result_text+="\n<b>Configuración final:</b>\n"
    result_text+="  🎵 <b>Formato:</b>  <i>$quality_label</i>\n"
    result_text+="  📂 <b>Ubicación:</b>  <i>$OUTPUT_DIR</i>\n"
    
    # Agregar listado de archivos generados
    if (( ${#converted_files[@]} > 0 )); then
        result_text+="\n<b>Archivos generados:</b>\n"
        local limit=$(( ${#converted_files[@]} < 8 ? ${#converted_files[@]} : 8 ))
        
        for (( i=0; i<limit; i++ )); do
            local file_path="${converted_files[$i]}"
            local file_size
            file_size=$(du -sh "$file_path" 2>/dev/null | cut -f1)
            result_text+="  📄 <i>$(basename "$file_path")</i>  <span foreground='#888888'>($file_size)</span>\n"
        done
        
        if (( ${#converted_files[@]} > 8 )); then
            result_text+="  … y $((${#converted_files[@]} - 8)) archivo(s) más\n"
        fi
    fi
    
    # Mostrar diálogo final
    yad --info \
        --title="✅ Conversión completada" \
        --text="$result_text" \
        --width=600 \
        --height=420 \
        --button="🕑 Historial:3" \
        --button="📂 Abrir carpeta:2" \
        --button="✔️  Finalizar:0" 2>/dev/null
    
    local button_pressed=$?
    
    # Manejar acciones del botón
    case $button_pressed in
        2)
            # Abrir carpeta de destino
            xdg-open "$OUTPUT_DIR" 2>/dev/null &
            ;;
        3)
            # Ver historial
            show_history_dialog
            ;;
    esac
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
        --width=800 \
        --height=480 \
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
        --width=780 \
        --height=560 \
        --button="gtk-cancel:1" \
        --button="Siguiente ▶:0" 2>/dev/null)
    
    (( $? != 0 )) && return 1
    [[ -z "$input_raw" ]] && return 1
    
    # Parsear archivos separados por |
    local -a files=()
    local IFS='|'
    for file in $input_raw; do
        # Limpiar espacios
        file="${file#"${file%%[![:space:]]*}"}"
        file="${file%"${file##*[![:space:]]}"}"
        
        [[ -f "$file" ]] && files+=("$file")
    done
    
    if (( ${#files[@]} == 0 )); then
        yad --error \
            --title="❌ Error" \
            --text="No se encontraron archivos válidos." \
            --width=380 \
            --button="OK:0" 2>/dev/null
        return 1
    fi
    
    # Guardar archivos en variable global
    INPUT_FILES=("${files[@]}")
    return 0
}

################################################################################
# PASO 2: CONFIRMAR ARCHIVOS CON INFORMACIÓN
################################################################################
confirm_input_files() {
    local -a info_rows=()
    local -a all_files=()
    
    # Recopilar información de cada archivo
    for file in "${INPUT_FILES[@]}"; do
        local base_name
        local duration
        local size_bytes
        local codec
        
        base_name=$(basename "$file")
        
        # Extraer información con ffprobe
        local ffprobe_out
        ffprobe_out=$(ffprobe -v error \
            -show_entries format=duration,size \
            -show_entries stream=codec_name \
            -of default=noprint_wrappers=1 "$file" 2>/dev/null)
        
        # Procesar duración
        duration=$(echo "$ffprobe_out" | grep "^duration=" | head -1 | cut -d= -f2)
        if [[ "$duration" =~ ^[0-9] ]]; then
            local duration_int="${duration%.*}"
            duration="$((duration_int / 60))m $((duration_int % 60))s"
        else
            duration="N/A"
        fi
        
        # Procesar tamaño
        size_bytes=$(echo "$ffprobe_out" | grep "^size=" | head -1 | cut -d= -f2)
        if [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
            size_bytes=$(numfmt --to=iec --suffix=B "$size_bytes" 2>/dev/null || echo "N/A")
        else
            size_bytes="N/A"
        fi
        
        # Procesar códec
        codec=$(echo "$ffprobe_out" | grep "^codec_name=" | head -1 | cut -d= -f2)
        codec="${codec:-N/A}"
        
        # Agregar fila a la lista
        info_rows+=("TRUE" "$base_name" "$codec" "$duration" "$size_bytes")
    done
    
    # Mostrar checklist
    local checklist_output
    checklist_output=$(yad --list \
        --title="🎵 Audio Converter — Confirmar Archivos" \
        --text="<b>Confirma los archivos a convertir:</b>\n<i>Desmarca los que quieras excluir de la conversión</i>" \
        --checklist \
        --column="✔️" \
        --column="Archivo" \
        --column="Códec" \
        --column="Duración" \
        --column="Tamaño" \
        "${info_rows[@]}" \
        --print-column=2 \
        --separator="|" \
        --width=760 \
        --height=480 \
        --button="gtk-cancel:1" \
        --button="☑️  Todas:2" \
        --button="Continuar ▶:0" 2>/dev/null)
    
    local button=$?
    
    case $button in
        1)
            return 1
            ;;
        2)
            # Todas seleccionadas
            return 0
            ;;
        0)
            # Procesar selección
            local -a selected_files=()
            local IFS=$'\n'
            
            for line in $checklist_output; do
                local file_name
                file_name=$(echo "$line" | tr -d '|' | xargs)
                [[ -z "$file_name" ]] && continue
                
                # Encontrar archivo original por nombre
                for orig_file in "${INPUT_FILES[@]}"; do
                    if [[ "$(basename "$orig_file")" == "$file_name" ]]; then
                        selected_files+=("$orig_file")
                        break
                    fi
                done
            done
            
            if (( ${#selected_files[@]} == 0 )); then
                yad --info \
                    --title="ℹ️  Sin archivos" \
                    --text="No se seleccionó ningún archivo para convertir." \
                    --width=380 \
                    --button="OK:0" 2>/dev/null
                return 1
            fi
            
            INPUT_FILES=("${selected_files[@]}")
            return 0
            ;;
    esac
}

################################################################################
# PASOS 3-7: CONFIGURACIÓN CON NAVEGACIÓN ATRÁS/SIGUIENTE
################################################################################
select_audio_options() {
    local step="${1:-3}"
    FORMAT=""
    BITRATE_OPT=""
    IS_LOSSLESS=false
    SAMPLE_RATE=""
    BIT_DEPTH=""
    OUTPUT_DIR=""
    
    while true; do
        case $step in
        
        ################################
        # PASO 3: SELECCIONAR FORMATO
        ################################
        3)
            FORMAT=$(yad --list \
                --title="🎵 Audio Converter — Paso 3: Formato de Salida" \
                --text="<b>Selecciona el formato de conversión:</b>" \
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
                --width=540 \
                --height=480 \
                --print-column=1 \
                --button="gtk-cancel:1" \
                --button="◀ Atrás:2" \
                --button="Siguiente ▶:0" 2>/dev/null)
            
            case $? in
                1) return 1 ;;
                2) return 2 ;;
            esac
            
            [[ -z "$FORMAT" ]] && continue
            
            # Limpiar FORMAT
            FORMAT=$(echo "$FORMAT" | tr -d '|' | xargs)
            
            # Determinar si es lossless
            IS_LOSSLESS=false
            case "$FORMAT" in
                flac|wav|aiff) IS_LOSSLESS=true ;;
            esac
            
            BITRATE_OPT=""
            step=4
            ;;
        
        ################################
        # PASO 4: SELECCIONAR BITRATE
        ################################
        4)
            # Saltar para formatos sin pérdida
            if [[ "$IS_LOSSLESS" == "true" ]]; then
                step=5
                continue
            fi
            
            BITRATE_OPT=$(yad --list \
                --title="🎵 Audio Converter — Paso 4: Calidad de Audio (Bitrate)" \
                --text="<b>Selecciona el bitrate de salida:</b>\n<i>Mayor bitrate = Mejor calidad (pero archivo más grande)</i>" \
                --column="Bitrate" \
                --column="Calidad" \
                --column="Uso recomendado" \
                "64k"  "Baja"       "Voz, podcasts, audiolibros" \
                "96k"  "Media-baja" "Radio online, streaming básico" \
                "128k" "Media"      "Música casual, streaming general" \
                "192k" "Alta"       "Música de buena calidad ✦" \
                "256k" "Muy alta"   "Música de alta fidelidad" \
                "320k" "Máxima"     "Audiófilos, archivos maestros" \
                --width=560 \
                --height=400 \
                --print-column=1 \
                --button="gtk-cancel:1" \
                --button="◀ Atrás:2" \
                --button="Siguiente ▶:0" 2>/dev/null)
            
            case $? in
                1) return 1 ;;
                2) step=3; continue ;;
            esac
            
            [[ -z "$BITRATE_OPT" ]] && continue
            
            # Limpiar BITRATE_OPT
            BITRATE_OPT=$(echo "$BITRATE_OPT" | tr -d '|' | xargs)
            step=5
            ;;
        
        ################################
        # PASO 5: SELECCIONAR SAMPLE RATE
        ################################
        5)
            local sr_hint=""
            local -a sr_options=()
            
            case "$FORMAT" in
                opus)
                    sr_hint="<b>Opus resampled automáticamente máx 48 kHz.</b>"
                    sr_options=(
                        "48000" "48 kHz (Recomendado ✦)" "Estándar Opus"
                        "24000" "24 kHz" "Optimizado voz"
                        "16000" "16 kHz" "Baja calidad"
                        "12000" "12 kHz" "Muy baja"
                        "8000"  "8 kHz"  "Telefonía"
                    )
                    ;;
                mp3)
                    sr_hint="<b>MP3 máx 48 kHz (rango válido).</b>"
                    sr_options=(
                        "48000" "48 kHz ✦" "Calidad Máxima"
                        "44100" "44.1 kHz" "CD Estándar"
                        "32000" "32 kHz" "Radio FM"
                        "24000" "24 kHz" "Voz clara"
                        "22050" "22.05 kHz" "Calidad media"
                    )
                    ;;
                mp2)
                    sr_hint="<b>MP2 solo soporta valores estándar específicos.</b>"
                    sr_options=(
                        "48000" "48 kHz" "Video"
                        "44100" "44.1 kHz ✦" "CD"
                        "32000" "32 kHz" "Broadcast"
                        "24000" "24 kHz" "Baja"
                    )
                    ;;
                aac|m4a)
                    sr_hint="<b>AAC soporta hasta 96 kHz (Hi-Res limitado).</b>"
                    sr_options=(
                        "orig"   "Sin cambios ✦" "Mantener original"
                        "96000"  "96 kHz" "Hi-Res AAC"
                        "48000"  "48 kHz" "Video HD"
                        "44100"  "44.1 kHz" "CD estándar"
                    )
                    ;;
                flac|wav|aiff)
                    sr_hint="<b>Formatos sin pérdida: Soportan alta resolución profesional.</b>"
                    sr_options=(
                        "orig"   "Sin cambios ✦" "Mantener original"
                        "192000" "192 kHz" "Mastering / Audiófilo"
                        "96000"  "96 kHz" "Estudio / Hi-Res"
                        "88200"  "88.2 kHz" "Múltiplo CD"
                        "48000"  "48 kHz" "Estándar Pro"
                        "44100"  "44.1 kHz" "Estándar CD"
                    )
                    ;;
                *)
                    sr_hint="<i>Selecciona la frecuencia de muestreo deseada.</i>"
                    sr_options=(
                        "orig"   "Sin cambios ✦" "Mantener original"
                        "48000"  "48 kHz" "Video / Streaming"
                        "44100"  "44.1 kHz" "CD estándar"
                    )
                    ;;
            esac
            
            SAMPLE_RATE=$(yad --list \
                --title="🎵 Audio Converter — Paso 5: Sample Rate" \
                --text="<b>Selecciona el sample rate para $FORMAT:</b>\n$sr_hint" \
                --column="Hz" \
                --column="Nombre" \
                --column="Uso típico" \
                "${sr_options[@]}" \
                --width=560 \
                --height=420 \
                --print-column=1 \
                --button="gtk-cancel:1" \
                --button="◀ Atrás:2" \
                --button="Siguiente ▶:0" 2>/dev/null)
            
            case $? in
                1) return 1 ;;
                2) 
                    [[ "$IS_LOSSLESS" == "true" ]] && step=3 || step=4
                    continue
                    ;;
            esac
            
            [[ -z "$SAMPLE_RATE" ]] && continue
            
            # Limpiar y procesar SAMPLE_RATE
            local sr_val
            sr_val=$(echo "$SAMPLE_RATE" | tr -d '|' | xargs)
            SAMPLE_RATE=""
            [[ "$sr_val" != "orig" ]] && SAMPLE_RATE="$sr_val"
            
            step=6
            ;;
        
        ################################
        # PASO 6: SELECCIONAR BIT DEPTH
        ################################
        6)
            # Saltar para formatos con pérdida
            if [[ "$IS_LOSSLESS" == "false" ]]; then
                step=7
                continue
            fi
            
            BIT_DEPTH=$(yad --list \
                --title="🎵 Audio Converter — Paso 6: Bit Depth (Profundidad de Bits)" \
                --text="<b>Selecciona la profundidad de bits:</b>\n<i>Solo para formatos sin pérdida (FLAC, WAV, AIFF).</i>" \
                --column="Formato ffmpeg" \
                --column="Bit Depth" \
                --column="Descripción" \
                "orig" "Sin cambios ✦"   "Mantener profundidad original" \
                "s16"  "16-bit (CD)"     "Estándar CD — compatible universal" \
                "s32"  "24/32-bit"       "Alta resolución — producción" \
                "s64"  "32-bit float"    "Máxima precisión — edición profesional" \
                --width=560 \
                --height=360 \
                --print-column=1 \
                --button="gtk-cancel:1" \
                --button="◀ Atrás:2" \
                --button="Siguiente ▶:0" 2>/dev/null)
            
            case $? in
                1) return 1 ;;
                2) step=5; continue ;;
            esac
            
            [[ -z "$BIT_DEPTH" ]] && continue
            
            # Limpiar y procesar BIT_DEPTH
            local bd_val
            bd_val=$(echo "$BIT_DEPTH" | tr -d '|' | xargs)
            BIT_DEPTH=""
            [[ "$bd_val" != "orig" ]] && BIT_DEPTH="$bd_val"
            
            step=7
            ;;
        
        ################################
        # PASO 7: SELECCIONAR CARPETA DESTINO
        ################################
        7)
            OUTPUT_DIR=$(yad --file \
                --title="🎵 Audio Converter — Paso 7: Carpeta de Destino" \
                --text="<b>Selecciona dónde guardar los archivos convertidos:</b>" \
                --directory \
                --filename="$LAST_DIR/" \
                --width=780 \
                --height=560 \
                --button="gtk-cancel:1" \
                --button="◀ Atrás:2" \
                --button="Confirmar ✔:0" 2>/dev/null)
            
            case $? in
                1) return 1 ;;
                2)
                    [[ "$IS_LOSSLESS" == "true" ]] && step=6 || step=5
                    continue
                    ;;
            esac
            
            [[ -z "$OUTPUT_DIR" ]] && continue
            
            # Guardar directorio en configuración
            echo "LAST_DIR=\"$OUTPUT_DIR\"" > "$CONFIG_FILE"
            break
            ;;
        esac
    done
    
    return 0
}

################################################################################
# FUNCIÓN PRINCIPAL DE CONVERSIÓN
################################################################################
process_conversions() {
    local converted_count=0
    local failed_count=0
    local -a converted_files=()
    local file_number=0
    local total_files=${#INPUT_FILES[@]}
    
    for input_file in "${INPUT_FILES[@]}"; do
        ((file_number++))
        
        local base_name="${input_file##*/}"
        local filename="${base_name%.*}"
        local safe_name
        safe_name=$(clean_filename "$filename")
        local output_file="$OUTPUT_DIR/$safe_name.$FORMAT"
        
        # Resolver conflicto si archivo ya existe
        if [[ -f "$output_file" ]]; then
            output_file=$(resolve_conflict "$output_file" "$safe_name" "$FORMAT" "$OUTPUT_DIR")
            if (( $? != 0 )); then
                ((failed_count++))
                continue
            fi
        fi
        
        # Convertir archivo
        convert_file "$input_file" "$output_file" "$file_number" "$total_files"
        local conversion_result=$?
        
        # Manejar cancelación
        if (( conversion_result == 2 )); then
            return 2
        fi
        
        # Registrar resultado
        if (( conversion_result == 0 )); then
            ((converted_count++))
            converted_files+=("$output_file")
            
            # Agregar a historial
            local quality_log="$FORMAT"
            [[ -n "$BITRATE_OPT" ]] && quality_log+=" @ $BITRATE_OPT"
            [[ -n "$SAMPLE_RATE" ]] && quality_log+=" (${SAMPLE_RATE}Hz)"
            [[ -n "$BIT_DEPTH" ]] && quality_log+=" [${BIT_DEPTH}]"
            
            echo "$(date '+%Y-%m-%d %H:%M:%S') | $base_name → $(basename "$output_file") | $quality_log | $OUTPUT_DIR" \
                >> "$HISTORY_FILE"
        else
            ((failed_count++))
            rm -f "$output_file" 2>/dev/null
        fi
    done
    
    # Mostrar diálogo final
    show_final_dialog "$converted_count" "$failed_count" "$total_files" "${converted_files[@]}"
}

################################################################################
# FLUJO PRINCIPAL DEL PROGRAMA
################################################################################
main() {
    # Verificar dependencias
    verify_dependencies
    
    # Cargar configuración
    LAST_DIR=$(load_config)
    
    # Paso 1: Seleccionar archivos
    if ! select_input_files; then
        exit 0
    fi
    
    # Paso 2: Confirmar archivos
    while ! confirm_input_files; do
        if ! select_input_files; then
            exit 0
        fi
    done
    
    # Pasos 3-7: Configuración de opciones
    while ! select_audio_options 3; do
        :
    done
    
    # Conversión
    process_conversions
}

# Ejecutar programa principal
main "$@"
exit 0
