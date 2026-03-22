#!/bin/bash

clip=$(wl-paste 2>/dev/null || xclip -selection clipboard -o 2>/dev/null)

media_regex="(youtube\.com|youtu\.be|youtube-nocookie\.com|twitch\.tv|vimeo\.com|tiktok\.com|twitter\.com|x\.com|dailymotion\.com|instagram\.com)"

if [[ "$clip" =~ $media_regex ]]; then
    notify-send "Reproduciendo desde portapapeles..."
    mpv "$clip"
    exit 0
fi

url=$(kdialog --title "Reproducir en MPV" --inputbox "Pega el link del video:")

if [[ -n "$url" ]]; then
    notify-send "MPV" "Reproduciendo enlace manual..."
    mpv "$url"
fi
