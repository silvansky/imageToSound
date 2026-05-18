#!/bin/bash

FILE="$1"
DIR="$(cd "$(dirname "$0")" && pwd)"

sox "${FILE}" -n spectrogram -o "${FILE}_spectrum_sox.png"
scale="cbrt" # sqrt and cbrt works best
legend="0" # 1 / 0
color="fiery"

ffmpeg -y -i "${FILE}" -lavfi "showspectrumpic=s=1920x4096:mode=combined:win_func=hann:color=${color}:legend=${legend}:scale=${scale}:saturation=5:fscale=lin,scale=1920:1080" "${FILE}_spectrum_lin_ffmpeg.png"
ffmpeg -y -i "${FILE}" -lavfi "showspectrumpic=s=1920x4096:mode=combined:win_func=hann:color=${color}:legend=${legend}:scale=${scale}:saturation=5:fscale=log,scale=1920:1080" "${FILE}_spectrum_log_ffmpeg.png"

# Render showspectrum at 4× height internally (forces larger FFT → finer freq resolution),
# then downscale to 1080 for display. Improves sub-100 Hz line resolution ~4-5×.
ffmpeg -y -i "${FILE}" -filter_complex "[0:a]showspectrum=s=1920x4096:mode=combined:win_func=hann:color=${color}:slide=scroll:legend=${legend}:scale=${scale}:saturation=5:fscale=lin,scale=1920:1080,format=yuv420p[v]" -map "[v]" -map 0:a -b:v 1500k "${FILE}_spectrum_lin.mkv" &
ffmpeg -y -i "${FILE}" -filter_complex "[0:a]showspectrum=s=1920x4096:mode=combined:win_func=hann:color=${color}:slide=scroll:legend=${legend}:scale=${scale}:saturation=5:fscale=log,scale=1920:1080,format=yuv420p[v]" -map "[v]" -map 0:a -b:v 1500k "${FILE}_spectrum_log.mkv" &

if [ -x "${DIR}/.venv_cqt/bin/python" ]; then
    "${DIR}/.venv_cqt/bin/python" "${DIR}/check_precise.py" "${FILE}" &
fi

wait
