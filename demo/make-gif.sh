#!/bin/bash
# Convert a screen recording (.mov/.mp4) to an optimized GIF for the README.
# Usage: demo/make-gif.sh recording.mov [out.gif] [width=760] [fps=15]
set -e
in="$1"; out="${2:-$(dirname "$0")/spyglass-demo.gif}"; w="${3:-760}"; fps="${4:-15}"
pal="$(mktemp -t palette).png"
ffmpeg -v error -y -i "$in" -vf "fps=$fps,scale=$w:-1:flags=lanczos,palettegen=stats_mode=diff" "$pal"
ffmpeg -v error -y -i "$in" -i "$pal" -lavfi "fps=$fps,scale=$w:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" "$out"
rm -f "$pal"
echo "Wrote $out ($(du -h "$out" | cut -f1))"
