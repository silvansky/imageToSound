#!/bin/bash

FILE="$1"
DIR="$(cd "$(dirname "$0")" && pwd)"

sox "${FILE}" -n spectrogram -o "${FILE}_spectrum_sox.png"

if [ -x "${DIR}/.venv_cqt/bin/python" ]; then
    "${DIR}/.venv_cqt/bin/python" "${DIR}/spectrogram.py" "${FILE}"
else
    echo "warning: ${DIR}/.venv_cqt not found; only sox spectrogram produced" >&2
fi
