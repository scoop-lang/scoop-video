#!/bin/sh
set -eu
mkdir -p artifacts
"${FFMPEG:-ffmpeg}" -hide_banner -loglevel warning -n \
  -f lavfi -i 'testsrc2=size=3840x2160:rate=60' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 10 \
  -c:v libx264 -preset veryfast -crf 20 -threads 6 -g 60 -bf 2 \
  -vf 'setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709' \
  -x264-params 'colorprim=bt709:transfer=bt709:colormatrix=bt709' \
  -pix_fmt yuv420p -color_range tv -colorspace bt709 -color_trc bt709 -color_primaries bt709 \
  -c:a aac -b:a 96k -movflags +faststart artifacts/source-4k60.mp4
