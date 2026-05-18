#!/usr/bin/env python3
"""Render high-resolution CQT spectrogram of an audio file."""
import argparse, os, numpy as np, librosa, soundfile as sf
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ap = argparse.ArgumentParser()
ap.add_argument("audio")
ap.add_argument("--fmin", type=float, default=20.0)
ap.add_argument("--bins-per-octave", type=int, default=96)
ap.add_argument("--n-octaves", type=int, default=10)
ap.add_argument("--hop", type=int, default=2048)
ap.add_argument("--out", default=None)
args = ap.parse_args()

y, sr = sf.read(args.audio)
print(f"audio {len(y)} samples @ {sr} Hz")

n_bins = args.bins_per_octave * args.n_octaves
C = np.abs(librosa.cqt(
    y.astype(np.float32),
    sr=sr, hop_length=args.hop, fmin=args.fmin,
    n_bins=n_bins, bins_per_octave=args.bins_per_octave,
))
print(f"CQT shape {C.shape}")

C_db = librosa.amplitude_to_db(C, ref=np.max)

out = args.out or os.path.splitext(args.audio)[0] + "_cqt_view.png"
fig, ax = plt.subplots(figsize=(19.2, 10.8), dpi=100)
img = librosa.display.specshow(
    C_db, sr=sr, hop_length=args.hop, fmin=args.fmin,
    bins_per_octave=args.bins_per_octave,
    x_axis="time", y_axis="cqt_hz", ax=ax, cmap="magma",
)
ax.set_facecolor("black")
plt.tight_layout()
plt.savefig(out, facecolor="black")
print(f"wrote {out}")

# Also a high-res STFT view for comparison
n_fft = 32768
S = np.abs(librosa.stft(y.astype(np.float32), n_fft=n_fft, hop_length=2048))
S_db = librosa.amplitude_to_db(S, ref=np.max)
out2 = os.path.splitext(args.audio)[0] + f"_stft{n_fft}_view.png"
fig, ax = plt.subplots(figsize=(19.2, 10.8), dpi=100)
librosa.display.specshow(
    S_db, sr=sr, hop_length=2048,
    x_axis="time", y_axis="log", ax=ax, cmap="magma",
)
plt.tight_layout()
plt.savefig(out2, facecolor="black")
print(f"wrote {out2}")
