#!/usr/bin/env bash
set -euo pipefail

demo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$demo_dir"
mkdir -p renders ../images

npm run render -- --quality delivery --fps 30 --crf 16 --format mp4 --workers 4 \
  --output renders/myclip-demo-master.mp4
ffmpeg -hide_banner -loglevel error -y -i renders/myclip-demo-master.mp4 \
  -map 0:v:0 -c copy -movflags +faststart ../images/myclip-demo.mp4
ffmpeg -hide_banner -loglevel error -y -i renders/myclip-demo-master.mp4 \
  -filter_complex 'fps=15,scale=1200:-1:flags=lanczos,format=rgb24,setparams=color_trc=iec61966-2-1,split[a][b];[a]palettegen=stats_mode=diff:reserve_transparent=1[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle' \
  -an -loop 0 renders/myclip-demo.gif
gifsicle -O3 renders/myclip-demo.gif -o ../images/myclip-demo.gif
ffmpeg -hide_banner -loglevel error -y -ss 8.5 -i renders/myclip-demo-master.mp4 \
  -frames:v 1 -q:v 2 ../images/myclip-demo-poster.jpg
