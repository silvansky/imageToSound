#!/usr/bin/env python3
"""Image-to-sound via Constant-Q Transform + Griffin-Lim CQT inversion."""

import argparse
import os
import sys
import numpy as np
import librosa
import soundfile as sf
from PIL import Image


def build_cqt_magnitude(img, n_bins, n_time_frames, mag_curve=2.0, invert=False):
    """Map image to CQT magnitude matrix [n_bins, n_time_frames].

    Image rows → CQT bins (low row = high freq = top of image).
    Image columns → time frames (linearly stretched).
    """
    H, W = img.shape

    # Time-axis: stretch image columns to time frames
    col_idx = np.linspace(0, W - 1, n_time_frames).astype(int)

    # Freq-axis: stretch image rows to CQT bins.
    # CQT bin 0 is lowest freq → bottom of image (high y_image).
    # CQT bin n_bins-1 is highest freq → top of image (low y_image).
    row_idx = np.linspace(H - 1, 0, n_bins).astype(int)

    mag = img[np.ix_(row_idx, col_idx)].astype(np.float32) / 255.0
    if invert:
        mag = 1.0 - mag
    mag = np.power(mag, mag_curve)
    return mag


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--output-dir", default=".")
    ap.add_argument("--sr", type=int, default=44100)
    ap.add_argument("--fmin", type=float, default=20.0)
    ap.add_argument("--bins-per-octave", type=int, default=48)
    ap.add_argument("--n-octaves", type=int, default=10)
    ap.add_argument("--frames-per-pixel", type=int, default=2000)
    ap.add_argument("--hop-length", type=int, default=2048)
    ap.add_argument("--gl-iters", type=int, default=64)
    ap.add_argument("--mag-curve", type=float, default=2.0)
    ap.add_argument("--invert", action="store_true")
    args = ap.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    pil = Image.open(args.image).convert("L")
    img = np.array(pil)
    H, W = img.shape
    print(f"Image {W}x{H}")

    n_bins = args.bins_per_octave * args.n_octaves

    fmax = args.fmin * (2 ** args.n_octaves)
    print(f"CQT: {n_bins} bins, fmin={args.fmin} Hz, fmax={fmax:.1f} Hz, bins/octave={args.bins_per_octave}")

    audio_length = args.frames_per_pixel * W
    # Hop must align with octave decimation (2^(n_octaves-1) divides hop)
    base = 2 ** (args.n_octaves - 1)
    hop = (args.hop_length // base) * base
    if hop == 0:
        hop = base
    print(f"Hop {hop} samples (rounded to multiple of {base})")
    n_frames = audio_length // hop
    print(f"Audio {audio_length} samples ({audio_length/args.sr:.1f}s), {n_frames} CQT frames")

    mag = build_cqt_magnitude(img, n_bins, n_frames,
                              mag_curve=args.mag_curve, invert=args.invert)

    print(f"Running CQT Griffin-Lim ({args.gl_iters} iters)…")
    y = librosa.griffinlim_cqt(
        mag,
        n_iter=args.gl_iters,
        sr=args.sr,
        hop_length=hop,
        fmin=args.fmin,
        bins_per_octave=args.bins_per_octave,
        random_state=0,
    )
    print(f"Reconstructed signal: {len(y)} samples")

    # Trim/pad to expected length
    if len(y) > audio_length:
        y = y[:audio_length]
    else:
        y = np.pad(y, (0, audio_length - len(y)))

    peak = np.max(np.abs(y))
    if peak > 1e-8:
        y = 0.5 * y / peak

    base_name = os.path.splitext(os.path.basename(args.image))[0]
    out_path = os.path.join(args.output_dir, f"{base_name}.wav")
    sf.write(out_path, y.astype(np.float32), args.sr)
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
