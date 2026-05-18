#!/usr/bin/env python3
"""High-resolution spectrogram verification for image-to-sound output.

Produces three PNGs alongside the input WAV:
  - <base>_spectrum_lin_precise.png  : large-FFT STFT, linear freq axis
  - <base>_spectrum_log_precise.png  : large-FFT STFT, log freq axis
  - <base>_spectrum_cqt.png          : Constant-Q transform view (true log)

These are produced with sufficient frequency resolution to resolve detail
that ffmpeg's default win_size=4096 cannot show (sub-100 Hz line spacing).
"""

import os
import subprocess
import sys

import numpy as np
import soundfile as sf
import librosa
import librosa.display
import matplotlib
matplotlib.use("Agg")
import matplotlib.cm as cm
import matplotlib.pyplot as plt
from PIL import Image as PILImage


def render(spec_db, kwargs, out_path, title):
    fig, ax = plt.subplots(figsize=(19.2, 10.8), dpi=100)
    librosa.display.specshow(spec_db, ax=ax, cmap="inferno", vmin=-80, vmax=0, **kwargs)
    ax.set_title(title, color="white")
    ax.tick_params(colors="white")
    for spine in ax.spines.values():
        spine.set_color("white")
    plt.tight_layout()
    plt.savefig(out_path, facecolor="black")
    plt.close()
    print(f"wrote {out_path}")


def main():
    if len(sys.argv) < 2:
        print("usage: check_precise.py <wav>", file=sys.stderr)
        sys.exit(1)

    wav = sys.argv[1]
    y, sr = sf.read(wav)
    if y.ndim > 1:
        y = y.mean(axis=1)
    y = y.astype(np.float32)

    base = wav  # keep the .wav suffix to match check.sh convention

    n_fft = 32768
    hop = 2048
    S = np.abs(librosa.stft(y, n_fft=n_fft, hop_length=hop))
    S_db = librosa.amplitude_to_db(S, ref=np.max)
    bin_hz = sr / n_fft
    title_stub = f"STFT n_fft={n_fft} ({bin_hz:.2f} Hz/bin), hop={hop}"

    render(S_db,
           dict(sr=sr, hop_length=hop, x_axis="time", y_axis="linear"),
           f"{base}_spectrum_lin_precise.png",
           f"{title_stub} | linear")

    render(S_db,
           dict(sr=sr, hop_length=hop, x_axis="time", y_axis="log"),
           f"{base}_spectrum_log_precise.png",
           f"{title_stub} | log")

    bins_per_octave = 96
    n_octaves = 10
    n_bins = bins_per_octave * n_octaves
    fmin = 20.0
    C = np.abs(librosa.cqt(
        y, sr=sr, hop_length=hop, fmin=fmin,
        n_bins=n_bins, bins_per_octave=bins_per_octave,
    ))
    C_db = librosa.amplitude_to_db(C, ref=np.max)

    cqt_png = f"{base}_spectrum_cqt.png"
    render(C_db,
           dict(sr=sr, hop_length=hop, fmin=fmin,
                bins_per_octave=bins_per_octave,
                x_axis="time", y_axis="cqt_hz"),
           cqt_png,
           f"CQT {n_bins} bins, {bins_per_octave}/octave, fmin={fmin} Hz")

    duration = len(y) / sr
    cqt_mkv = f"{base}_spectrum_cqt.mkv"
    cmd = [
        "ffmpeg", "-y", "-loop", "1", "-framerate", "30",
        "-i", cqt_png, "-i", wav,
        "-filter_complex",
        f"[0:v]drawbox=x='iw*t/{duration}':y=0:w=5:h=ih:color=cyan@0.9:t=fill,format=yuv420p[v]",
        "-map", "[v]", "-map", "1:a",
        "-c:v", "libx264", "-c:a", "aac",
        "-t", f"{duration:.3f}",
        "-shortest",
        cqt_mkv,
    ]
    res = subprocess.run(cmd, capture_output=True)
    if res.returncode == 0:
        print(f"wrote {cqt_mkv}")
    else:
        sys.stderr.write(res.stderr.decode(errors="ignore")[-800:])

    # Scrolling CQT video: right edge = current playback time, content scrolls R→L.
    # Build a wide PNG of the whole CQT, then ffmpeg pad-and-crop with time-based x.
    pps = 64  # pixels per second of audio
    wide_w = max(1920, int(pps * duration))
    wide_h = 1080
    arr = (np.clip(C_db, -80, 0) + 80) / 80.0      # normalize to 0..1
    arr = arr[::-1]                                # low-freq bin → bottom of image
    pim = PILImage.fromarray((arr * 255).astype(np.uint8), mode="L")
    pim = pim.resize((wide_w, wide_h), PILImage.LANCZOS)
    cmap = cm.get_cmap("inferno")
    colored = (cmap(np.asarray(pim) / 255.0)[:, :, :3] * 255).astype(np.uint8)
    wide_png = f"{base}_spectrum_cqt_wide.png"
    PILImage.fromarray(colored).save(wide_png)

    scroll_mkv = f"{base}_spectrum_cqt_scroll.mkv"
    cmd = [
        "ffmpeg", "-y", "-loop", "1", "-framerate", "30",
        "-i", wide_png, "-i", wav,
        "-filter_complex",
        f"[0:v]pad=iw+1920:ih:1920:0:color=black,crop=1920:1080:{pps}*t:0,format=yuv420p[v]",
        "-map", "[v]", "-map", "1:a",
        "-c:v", "libx264", "-c:a", "aac",
        "-t", f"{duration:.3f}",
        "-shortest",
        scroll_mkv,
    ]
    res = subprocess.run(cmd, capture_output=True)
    if res.returncode == 0:
        print(f"wrote {scroll_mkv}")
    else:
        sys.stderr.write(res.stderr.decode(errors="ignore")[-800:])
    os.remove(wide_png)  # ~30MB intermediate, not needed after encode


if __name__ == "__main__":
    main()
