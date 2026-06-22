#!/usr/bin/env python3
"""High-resolution spectrogram rendering for image-to-sound output.

Python-rendered images and videos with full control over FFT size, log/linear
axis remapping, colormap, scroll rate. Replaces ffmpeg's spectrum filters.

Per WAV file, produces:
  <base>_spectrum_lin_precise.png       large-FFT STFT, linear freq axis
  <base>_spectrum_log_precise.png       large-FFT STFT, log freq axis
  <base>_spectrum_cqt.png               Constant-Q transform (true log)
  <base>_spectrum_lin.mkv               scrolling video, linear freq axis
  <base>_spectrum_log.mkv               scrolling video, log freq axis
  <base>_spectrum_cqt_scroll.mkv        scrolling CQT video
"""

import argparse
import os
import subprocess
import sys

import numpy as np
import soundfile as sf
import librosa
import librosa.display
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from PIL import Image as PILImage


def render_static(spec_db, kwargs, out_path, title, cmap, db_floor, ymin=None, ymax=None):
    fig, ax = plt.subplots(figsize=(19.2, 10.8), dpi=100)
    librosa.display.specshow(spec_db, ax=ax, cmap=cmap, vmin=db_floor, vmax=0, **kwargs)
    if ymax is not None:
        ax.set_ylim(ymin if ymin is not None else 0, ymax)
    ax.set_title(title, color="white")
    ax.tick_params(colors="white")
    for spine in ax.spines.values():
        spine.set_color("white")
    plt.tight_layout()
    plt.savefig(out_path, facecolor="black")
    plt.close()
    print(f"wrote {out_path}")


def log_remap(spec_lin_db, sr, n_fft, n_rows, fmin, fmax=None):
    """Remap STFT (linear-binned) onto a log-frequency row grid."""
    n_bins = spec_lin_db.shape[0]
    bin_hz = np.arange(n_bins) * sr / n_fft
    target = np.geomspace(fmin, fmax if fmax is not None else sr / 2, n_rows)
    out = np.empty((n_rows, spec_lin_db.shape[1]), dtype=spec_lin_db.dtype)
    for col in range(spec_lin_db.shape[1]):
        out[:, col] = np.interp(target, bin_hz, spec_lin_db[:, col])
    return out


def encode_scroll_video(wide_png, wav, out_path, duration, wide_w, video_w, video_h):
    # Scroll at the wide image's actual pixel density so the playhead stays in
    # sync with the audio even when wide_w was clamped up to video_w.
    rate = wide_w / duration
    cmd = [
        "ffmpeg", "-y", "-loop", "1", "-framerate", "30",
        "-i", wide_png, "-i", wav,
        "-filter_complex",
        f"[0:v]pad=iw+{video_w}:ih:{video_w}:0:color=black,"
        f"crop={video_w}:{video_h}:{rate}*t:0,format=yuv420p[v]",
        "-map", "[v]", "-map", "1:a",
        "-c:v", "libx264", "-c:a", "aac",
        "-t", f"{duration:.3f}", "-shortest", out_path,
    ]
    res = subprocess.run(cmd, capture_output=True)
    if res.returncode == 0:
        print(f"wrote {out_path}")
    else:
        sys.stderr.write(res.stderr.decode(errors="ignore")[-800:])


def make_scroll(spec_db, wav, base, suffix, duration, pps, video_w, video_h, cmap_name, db_floor):
    wide_w = max(video_w, int(pps * duration))
    arr = (np.clip(spec_db, db_floor, 0) - db_floor) / (-db_floor)
    arr = arr[::-1]
    pim = PILImage.fromarray((arr * 255).astype(np.uint8), mode="L")
    pim = pim.resize((wide_w, video_h), PILImage.LANCZOS)
    cmap = matplotlib.colormaps[cmap_name]
    colored = (cmap(np.asarray(pim) / 255.0)[:, :, :3] * 255).astype(np.uint8)

    wide_png = f"{base}_spectrum_{suffix}_wide.png"
    PILImage.fromarray(colored).save(wide_png)
    out_mkv = f"{base}_spectrum_{suffix}.mkv"
    encode_scroll_video(wide_png, wav, out_mkv, duration, wide_w, video_w, video_h)
    os.remove(wide_png)


def parse_size(s):
    w, h = s.lower().split("x")
    # libx264 + yuv420p require even dimensions; odd values yield a 0-byte video.
    return int(w) // 2 * 2, int(h) // 2 * 2


def main():
    ap = argparse.ArgumentParser(description="Render spectrograms (images + videos) for a WAV file.")
    ap.add_argument("wav", help="input WAV file")
    ap.add_argument("--cmap", default="inferno", help="matplotlib colormap name")
    ap.add_argument("--db-floor", type=float, default=-80.0, help="dynamic range floor in dB")
    ap.add_argument("--pps", type=int, default=22,
                    help="scroll rate (px/sec of audio). For a round/undistorted image, "
                         "pps = video_height / image_height * samplerate / frames_per_pixel. "
                         "Default 22 = 44100/2000 (square when video height = image height).")
    ap.add_argument("--video-size", type=parse_size, default=(1920, 1080), help="video frame size WxH")
    ap.add_argument("--n-log-rows", type=int, default=1080, help="row resolution for log-remapped video")
    ap.add_argument("--fmin", type=float, default=20.0, help="lowest frequency (Hz) for CQT and log remapping")
    ap.add_argument("--fmax", type=float, default=None,
                    help="upper frequency (Hz) for the linear view/video; crops the linear "
                         "axis so a band-limited image fills the frame (default: samplerate/2)")
    ap.add_argument("--n-fft", type=int, default=32768, help="STFT window size")
    ap.add_argument("--hop", type=int, default=2048, help="STFT/CQT hop length")
    ap.add_argument("--bins-per-octave", type=int, default=96, help="CQT bins per octave")
    ap.add_argument("--n-octaves", type=int, default=10, help="CQT octave count")
    ap.add_argument("--no-static", action="store_true", help="skip static PNGs")
    ap.add_argument("--no-video", action="store_true", help="skip videos")
    ap.add_argument("--mode", choices=["lin", "log", "cqt", "all"], default="all",
                    help="which analyses to render: 'lin'/'log' use STFT, 'cqt' uses Constant-Q, 'all' = everything")
    args = ap.parse_args()

    video_w, video_h = args.video_size

    y, sr = sf.read(args.wav)
    if y.ndim > 1:
        y = y.mean(axis=1)
    y = y.astype(np.float32)
    duration = len(y) / sr
    base = args.wav

    want_stft = args.mode in ("lin", "log", "all")
    want_cqt = args.mode in ("cqt", "all")
    want_lin = args.mode in ("lin", "all")
    want_log = args.mode in ("log", "all")

    S_db = None
    if want_stft:
        S = np.abs(librosa.stft(y, n_fft=args.n_fft, hop_length=args.hop))
        S_db = librosa.amplitude_to_db(S, ref=np.max)
        bin_hz = sr / args.n_fft
        stft_title = f"STFT n_fft={args.n_fft} ({bin_hz:.2f} Hz/bin), hop={args.hop}"

    C_db = None
    n_bins_cqt = args.bins_per_octave * args.n_octaves
    if want_cqt:
        C = np.abs(librosa.cqt(
            y, sr=sr, hop_length=args.hop, fmin=args.fmin,
            n_bins=n_bins_cqt, bins_per_octave=args.bins_per_octave,
        ))
        C_db = librosa.amplitude_to_db(C, ref=np.max)

    cqt_png = f"{base}_spectrum_cqt.png"

    if not args.no_static:
        if want_lin:
            render_static(S_db,
                dict(sr=sr, hop_length=args.hop, x_axis="time", y_axis="linear"),
                f"{base}_spectrum_lin_precise.png", f"{stft_title} | linear",
                args.cmap, args.db_floor, ymax=args.fmax)
        if want_log:
            render_static(S_db,
                dict(sr=sr, hop_length=args.hop, x_axis="time", y_axis="log"),
                f"{base}_spectrum_log_precise.png", f"{stft_title} | log",
                args.cmap, args.db_floor, ymin=args.fmin, ymax=args.fmax)
        if want_cqt:
            render_static(C_db,
                dict(sr=sr, hop_length=args.hop, fmin=args.fmin,
                     bins_per_octave=args.bins_per_octave,
                     x_axis="time", y_axis="cqt_hz"),
                cqt_png,
                f"CQT {n_bins_cqt} bins, {args.bins_per_octave}/octave, fmin={args.fmin} Hz",
                args.cmap, args.db_floor)

    if not args.no_video:
        if want_lin:
            S_vid = S_db
            if args.fmax is not None:
                max_bin = int(args.fmax * args.n_fft / sr) + 1
                S_vid = S_db[:max_bin]
            make_scroll(S_vid, args.wav, base, "lin", duration,
                        args.pps, video_w, video_h, args.cmap, args.db_floor)
        if want_log:
            make_scroll(log_remap(S_db, sr, args.n_fft, args.n_log_rows, args.fmin, args.fmax),
                        args.wav, base, "log", duration,
                        args.pps, video_w, video_h, args.cmap, args.db_floor)
        if want_cqt:
            make_scroll(C_db, args.wav, base, "cqt_scroll", duration,
                        args.pps, video_w, video_h, args.cmap, args.db_floor)


if __name__ == "__main__":
    main()
