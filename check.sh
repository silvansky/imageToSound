#!/bin/bash

FILE="$1"

sox "${FILE}" -n spectrogram -o "${FILE}_spectrum.png"
ffmpeg -y -i "${FILE}" -filter_complex "[0:a]showspectrum=s=1280x720:mode=combined:win_func=hann:color=fiery:slide=scroll:legend=0:scale=sqrt:saturation=5:gain=2:fscale=lin,format=yuv420p[v]" -map "[v]" -map 0:a -b:v 700k "${FILE}_spectrum.mkv"
