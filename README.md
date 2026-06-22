# imageToSound

Encode images into audio whose spectrogram reconstructs the image.

Two synthesis pipelines:

- **Swift `imageToSound`** — iSTFT + Fast Griffin-Lim (or narrow-band noise via `--noise`). Linear or log frequency axis, auto-derived or explicit FFT size, optional multiresolution STFT (3 bands with different FFT sizes).
- **Python `cqt_synth.py`** — Constant-Q Transform + Griffin-Lim. Log-frequency only, with adaptive time-frequency resolution.

Plus `spectrogram.py` for high-resolution verification (images + videos).

## Build (Swift tool)

```sh
swift build -c release
```

Binary lands at `.build/release/imageToSound`. Requires macOS 13+ and Swift 5.9+.

## Python setup

```sh
python3 -m venv .venv_cqt
.venv_cqt/bin/pip install librosa soundfile Pillow numpy matplotlib
```

## Workflow

```sh
# Image → audio (Swift, linear scale)
imageToSound input.png --output-dir out

# Image → audio (Swift, log scale, multiresolution)
imageToSound input.png --output-dir out --log-scale --multiresolution

# Image → audio (Swift, narrow-band noise, limited to a frequency range)
imageToSound input.png --output-dir out --noise --min-frequency 98 --max-frequency 1175

# Image → audio (Python, CQT)
.venv_cqt/bin/python cqt_synth.py input.png --output-dir out

# Verify: render spectrograms of the produced WAV
bash check.sh out/input.wav
```

## Demo

```sh
bash demo_alphabet.sh
```

Renders an A–Z alphabet image and runs both synthesis pipelines on it,
producing a linear precise STFT spectrogram + scroll video for the Swift
(linear) output, and a CQT spectrogram + scroll video for the Python (log)
output. Tune via env vars `FRAMES_PER_PIXEL=200 PPS=256`.

---

## `imageToSound` (Swift CLI)

Reads an image, builds a magnitude spectrogram from its pixels, reconstructs
phase (Fast Griffin-Lim, or independent random phase per bin with `--noise` for
narrow-band-noise synthesis), writes a WAV.

```
imageToSound <image-path> [options]
```

| Option | Default | Notes |
|--------|---------|-------|
| `<image-path>` | required | source image |
| `--samplerate <int>` | `44100` | output sample rate |
| `--min-frequency <int>` | `20` | lowest mapped frequency (Hz) |
| `--max-frequency <int>` | `samplerate/2` | highest mapped frequency (Hz); honored in both linear and log scale |
| `--frames-per-pixel <int>` | `2000` | audio samples per image column (controls duration) |
| `--fft-size <int\|auto>` | `auto` | STFT window size (single-band mode); `auto` derives a power-of-two giving ~one bin per image row across the frequency range, clamped to `[1024, 16384]` |
| `--hop-size <int>` | `fft-size/4` | STFT hop |
| `--gl-iterations <int>` | `60` | Griffin-Lim iterations (ignored with `--noise`) |
| `--gl-momentum <float>` | `0.99` | Fast Griffin-Lim momentum (`0` = classic GL) |
| `--mag-curve <float>` | `2.0` | brightness → magnitude power-law (>1 emphasizes bright pixels) |
| `--noise` | off | synthesize with narrow-band white noise (random phase per bin, no Griffin-Lim) instead of sines |
| `--invert` | off | invert image brightness |
| `--log-scale` | off | logarithmic frequency mapping |
| `--multiresolution` | off | 3-band STFT (16384/4096/1024 at low/mid/high freq with cosine crossfades) |
| `--output-dir <path>` | `.` | output directory |

Writes `<output-dir>/<image-basename>.wav`.

---

## `cqt_synth.py` (Python, CQT synthesis)

Image → WAV via Constant-Q Transform magnitudes and CQT Griffin-Lim. CQT is
log-frequency-spaced, so an image row maps to a CQT bin and renders with proper
adaptive time-frequency resolution (long analysis at low freq, short at high).

```
python cqt_synth.py <image> [options]
```

| Option | Default | Notes |
|--------|---------|-------|
| `<image>` | required | source image |
| `--output-dir <path>` | `.` | output directory |
| `--sr <int>` | `44100` | sample rate |
| `--fmin <float>` | `20.0` | lowest CQT frequency (Hz) |
| `--bins-per-octave <int>` | `48` | CQT density |
| `--n-octaves <int>` | `10` | CQT octave count (total bins = bins-per-octave × n-octaves) |
| `--frames-per-pixel <int>` | `2000` | audio samples per image column |
| `--hop-length <int>` | `2048` | CQT hop (rounded up to a multiple of `2^(n-octaves-1)`) |
| `--gl-iters <int>` | `64` | Griffin-Lim iterations |
| `--mag-curve <float>` | `2.0` | brightness power-law |
| `--invert` | off | invert image brightness |

Writes `<output-dir>/<image-basename>.wav`.

---

## `spectrogram.py` (Python, WAV → spectrograms)

Renders precise spectrogram images and videos from a WAV. Uses large-FFT STFT
and CQT analyses; no ffmpeg spectrum filters involved (ffmpeg is used only as
the video encoder).

```
python spectrogram.py <wav> [options]
```

| Option | Default | Notes |
|--------|---------|-------|
| `<wav>` | required | input audio |
| `--cmap <name>` | `inferno` | matplotlib colormap |
| `--db-floor <float>` | `-80.0` | dynamic-range floor in dB |
| `--pps <int>` | `22` | scroll rate (pixels per second of audio); see [Preserving aspect ratio](#preserving-aspect-ratio) |
| `--video-size <WxH>` | `1920x1080` | output video size |
| `--n-log-rows <int>` | `1080` | row resolution for log-axis video (linear STFT remapped to log) |
| `--fmin <float>` | `20.0` | lowest frequency for CQT and log remap; also sets the lower axis bound of lin/log renders when `--fmax` is given |
| `--fmax <float>` | `samplerate/2` | highest frequency rendered; crops the lin/log axes (static + video) to `[fmin, fmax]` |
| `--n-fft <int>` | `32768` | STFT window size (1.35 Hz/bin at sr=44100) |
| `--hop <int>` | `2048` | STFT/CQT hop |
| `--bins-per-octave <int>` | `96` | CQT density |
| `--n-octaves <int>` | `10` | CQT octave count |
| `--no-static` | off | skip static PNGs |
| `--no-video` | off | skip videos |
| `--mode <lin\|log\|cqt\|all>` | `all` | which analyses to render |

Outputs (per input WAV named `foo.wav`):

| File | Type |
|------|------|
| `foo.wav_spectrum_lin_precise.png` | static, large-FFT STFT, linear axis |
| `foo.wav_spectrum_log_precise.png` | static, large-FFT STFT, log axis |
| `foo.wav_spectrum_cqt.png` | static, true CQT |
| `foo.wav_spectrum_lin.mkv` | scrolling video, linear axis |
| `foo.wav_spectrum_log.mkv` | scrolling video, log axis |
| `foo.wav_spectrum_cqt_scroll.mkv` | scrolling video, CQT |

---

## `check.sh` (wrapper)

```
bash check.sh <wav>
```

Produces a SoX baseline (`_spectrum_sox.png`) and runs `spectrogram.py` if the
local `.venv_cqt` is available. All outputs land next to the input WAV.

---

## Preserving aspect ratio

The scrolling video should reproduce the source image undistorted — a circle
drawn in the image must render as a circle, not an ellipse. This is the
preferred (default) behaviour.

The synthesis spreads the full image **height** across the full frequency axis,
which the video draws in `video_height` pixels. Each image **column** becomes
`frames-per-pixel` audio samples, which scroll past at `pps` pixels per second.
For square pixels the two scales must match:

```
pps = video_height / image_height × samplerate / frames-per-pixel
```

When the **video height equals the image height** this reduces to the matched
default pair:

```
pps = samplerate / frames-per-pixel          # 44100 / 2000 = 22  (the default)
```

So the defaults align out of the box: synthesis `--frames-per-pixel 2000`,
`--samplerate 44100`, and spectrogram `--pps 22` give an undistorted image when
the source is as tall as the video frame (default `--video-size 1920x1080`).

For a source of a different height, either set the video height to match the
image and keep `pps = samplerate / frames-per-pixel`, or scale `pps`:

| Image height | frames-per-pixel | video-size | pps |
|--------------|------------------|------------|-----|
| 1080 | 2000 | 1920x1080 | 22 (default) |
| 768  | 2000 | 1920x1080 | 31 |
| 768  | 1000 | 1920x1080 | 62 (audio plays 2× faster) |
| any H | F | 1920xH | 44100 / F |

Halving `frames-per-pixel` halves the audio duration (plays 2× faster) and
doubles the required `pps`.

## Pipeline cheat sheet

| Need | Tool |
|------|------|
| Image looks correct on **linear** spectrogram | Swift `imageToSound` (default) |
| Image looks correct on **log** spectrogram | Swift `--log-scale` or Python `cqt_synth.py` |
| Noisy / textured timbre instead of tonal sines | Swift `--noise` |
| Restrict image to a frequency band (e.g. piano range) | Swift `--min-frequency`/`--max-frequency` + `spectrogram.py --fmin`/`--fmax` |
| Linear axis + adaptive resolution | Swift `--multiresolution` |
| Log axis + adaptive resolution (best low-freq detail) | Python `cqt_synth.py` (CQT) |
| Verify output against source | `bash check.sh out/foo.wav` |
| Undistorted (round) image in video | match `pps` to the wav — see [Preserving aspect ratio](#preserving-aspect-ratio) |
