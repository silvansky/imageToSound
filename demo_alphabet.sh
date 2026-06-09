#!/bin/bash
# End-to-end demo: render an alphabet image, synthesize audio in both
# linear (Swift iSTFT+Griffin-Lim) and log (Python CQT+Griffin-Lim) modes,
# render matching spectrograms and scrolling videos for each.
#
# Outputs structure:
#   <OUT>/alphabet.png                          source image
#   <OUT>/lin/alphabet.wav                      Swift linear synthesis
#   <OUT>/lin/alphabet.wav_spectrum_lin_precise.png   linear STFT spectrogram
#   <OUT>/lin/alphabet.wav_spectrum_lin.mkv     linear scrolling video
#   <OUT>/log/alphabet.wav                      Python CQT synthesis
#   <OUT>/log/alphabet.wav_spectrum_cqt.png     CQT spectrogram
#   <OUT>/log/alphabet.wav_spectrum_cqt_scroll.mkv    CQT scrolling video

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-alphabet_demo}"
FPP="${FRAMES_PER_PIXEL:-200}"
PPS="${PPS:-256}"

VENV="$DIR/.venv_cqt"
BIN="$DIR/.build/release/imageToSound"

if [ ! -x "$VENV/bin/python" ]; then
    echo "ERROR: $VENV not found. Set up with:" >&2
    echo "  python3 -m venv .venv_cqt && .venv_cqt/bin/pip install librosa soundfile Pillow numpy matplotlib" >&2
    exit 1
fi

if [ ! -x "$BIN" ]; then
    echo "Building Swift binary..."
    (cd "$DIR" && swift build -c release)
fi

mkdir -p "$OUT/lin" "$OUT/log"

echo "=== 1/5 Alphabet image ==="
"$VENV/bin/python" "$DIR/make_alphabet.py" "$OUT/alphabet.png"

echo "=== 2/5 Linear synthesis (Swift iSTFT+GL) ==="
"$BIN" "$OUT/alphabet.png" --output-dir "$OUT/lin" --frames-per-pixel "$FPP"

echo "=== 3/5 Log synthesis (Python CQT+GL) ==="
"$VENV/bin/python" "$DIR/cqt_synth.py" "$OUT/alphabet.png" --output-dir "$OUT/log" --frames-per-pixel "$FPP"

echo "=== 4/5 Linear spectrogram + scroll video ==="
"$VENV/bin/python" "$DIR/spectrogram.py" "$OUT/lin/alphabet.wav" --mode lin --pps "$PPS"

echo "=== 5/5 CQT spectrogram + scroll video ==="
"$VENV/bin/python" "$DIR/spectrogram.py" "$OUT/log/alphabet.wav" --mode cqt --pps "$PPS"

echo ""
echo "Done. Outputs in $OUT/"
ls -1 "$OUT" "$OUT/lin" "$OUT/log"
