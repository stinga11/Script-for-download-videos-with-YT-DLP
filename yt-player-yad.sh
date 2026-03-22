#!/bin/bash

# ---------------------------------------------------------
# Obtener URL desde clipboard o input manual
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
    URL=$(yad --entry --title="Reproducir video" --text="Pega el link del video:")
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
# Parseo de formatos (igual al script original)
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

[ -z "$VIDEO_OPTIONS" ] && yad --error --text="No se encontraron formatos de video válidos." && exit 1

declare -A VIDEO_MAP
YAD_LIST=()

while IFS="|" read -r ID DESC; do
    VIDEO_MAP["$DESC"]="$ID"
    YAD_LIST+=("$DESC")
done <<< "$VIDEO_OPTIONS"

# ---------------------------------------------------------
# Selección de resolución
# ---------------------------------------------------------

SELECTED=$(yad --list \
    --title="Reproducir: $TITLE" \
    --text="Selecciona la resolución:" \
    --column="Formato" \
    --separator="" \
    --width=350 --height=400 --center \
    "${YAD_LIST[@]}")

[ $? -ne 0 ] && exit 0
[ -z "$SELECTED" ] && exit 0

VIDEO_ID="${VIDEO_MAP[$SELECTED]}"

# ---------------------------------------------------------
# Reproducir con MPV
# ---------------------------------------------------------

mpv --ytdl-format="$VIDEO_ID+bestaudio/best" "$URL"
