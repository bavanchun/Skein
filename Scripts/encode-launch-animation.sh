#!/bin/bash
# Encode the Blender render for native AVFoundation playback (macOS 14+).
set -euo pipefail
skein_root="$(cd "$(dirname "$0")/.." && pwd)"
frames="$skein_root/.ci-output/launch-animation"
resources="$skein_root/Skein/Resources"
mkdir -p "$resources"
ffmpeg -hide_banner -loglevel error -y -framerate 60 \
    -start_number 1 -i "$frames/frame-%04d.png" -frames:v 150 \
    -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p \
    -movflags +faststart -an "$resources/skein-launch.mp4"
cp "$frames/frame-0150.png" "$resources/skein-launch-poster.png"
ffprobe -v error -show_entries stream=codec_name,width,height,nb_frames,duration \
    -of default=noprint_wrappers=1 "$resources/skein-launch.mp4"
