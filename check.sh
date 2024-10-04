#!/bin/bash

FILE="$1"

sox "${FILE}" -n spectrogram -o "${FILE}_spectrum_sox.png"

ffmpeg -y -i "${FILE}" -lavfi "showspectrumpic=s=1920x1080:mode=combined:win_func=hann:color=fiery:legend=1:scale=sqrt:saturation=5:fscale=lin" "${FILE}_spectrum_lin_ffmpeg.png"
ffmpeg -y -i "${FILE}" -lavfi "showspectrumpic=s=1920x1080:mode=combined:win_func=hann:color=fiery:legend=1:scale=sqrt:saturation=5:fscale=log" "${FILE}_spectrum_log_ffmpeg.png"

ffmpeg -y -i "${FILE}" -filter_complex "[0:a]showspectrum=s=1920x1080:mode=combined:win_func=hann:color=fiery:slide=scroll:legend=1:scale=sqrt:saturation=5:fscale=lin,format=yuv420p[v]" -map "[v]" -map 0:a -b:v 700k "${FILE}_spectrum_lin.mkv"
ffmpeg -y -i "${FILE}" -filter_complex "[0:a]showspectrum=s=1920x1080:mode=combined:win_func=hann:color=fiery:slide=scroll:legend=1:scale=sqrt:saturation=5:fscale=log,format=yuv420p[v]" -map "[v]" -map 0:a -b:v 700k "${FILE}_spectrum_log.mkv"
