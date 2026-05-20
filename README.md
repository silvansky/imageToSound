# imageToSound

Encode images into audio whose spectrogram reconstructs the image.

Two synthesis pipelines:

- **Swift `imageToSound`** — iSTFT + Fast Griffin-Lim. Linear or log frequency axis, optional multiresolution STFT (3 bands with different FFT sizes).
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

# Image → audio (Python, CQT)
.venv_cqt/bin/python cqt_synth.py input.png --output-dir out

# Verify: render spectrograms of the produced WAV
bash check.sh out/input.wav
```

---

## `imageToSound` (Swift CLI)

Reads an image, builds a magnitude spectrogram from its pixels, runs Griffin-Lim
phase reconstruction, writes a WAV.

```
imageToSound <image-path> [options]
```

| Option | Default | Notes |
|--------|---------|-------|
| `<image-path>` | required | source image |
| `--samplerate <int>` | `44100` | output sample rate |
| `--min-frequency <int>` | `20` | lowest mapped frequency (Hz) |
| `--max-frequency <int>` | `samplerate/2` | highest mapped frequency (Hz) |
| `--frames-per-pixel <int>` | `2000` | audio samples per image column (controls duration) |
| `--fft-size <int>` | `2048` | STFT window size (single-band mode) |
| `--hop-size <int>` | `fft-size/4` | STFT hop |
| `--gl-iterations <int>` | `60` | Griffin-Lim iterations |
| `--gl-momentum <float>` | `0.99` | Fast Griffin-Lim momentum (`0` = classic GL) |
| `--mag-curve <float>` | `2.0` | brightness → magnitude power-law (>1 emphasizes bright pixels) |
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
| `--pps <int>` | `64` | scroll rate (pixels per second of audio) |
| `--video-size <WxH>` | `1920x1080` | output video size |
| `--n-log-rows <int>` | `1080` | row resolution for log-axis video (linear STFT remapped to log) |
| `--fmin <float>` | `20.0` | lowest frequency for CQT and log remap |
| `--n-fft <int>` | `32768` | STFT window size (1.35 Hz/bin at sr=44100) |
| `--hop <int>` | `2048` | STFT/CQT hop |
| `--bins-per-octave <int>` | `96` | CQT density |
| `--n-octaves <int>` | `10` | CQT octave count |
| `--playhead-color <expr>` | `cyan@0.9` | ffmpeg color expr for static-video playhead |
| `--no-static` | off | skip static PNGs |
| `--no-video` | off | skip videos |

Outputs (per input WAV named `foo.wav`):

| File | Type |
|------|------|
| `foo.wav_spectrum_lin_precise.png` | static, large-FFT STFT, linear axis |
| `foo.wav_spectrum_log_precise.png` | static, large-FFT STFT, log axis |
| `foo.wav_spectrum_cqt.png` | static, true CQT |
| `foo.wav_spectrum_lin.mkv` | scrolling video, linear axis |
| `foo.wav_spectrum_log.mkv` | scrolling video, log axis |
| `foo.wav_spectrum_cqt_scroll.mkv` | scrolling video, CQT |
| `foo.wav_spectrum_cqt.mkv` | static CQT image + moving playhead overlay |

---

## `check.sh` (wrapper)

```
bash check.sh <wav>
```

Produces a SoX baseline (`_spectrum_sox.png`) and runs `spectrogram.py` if the
local `.venv_cqt` is available. All outputs land next to the input WAV.

---

## Pipeline cheat sheet

| Need | Tool |
|------|------|
| Image looks correct on **linear** spectrogram | Swift `imageToSound` (default) |
| Image looks correct on **log** spectrogram | Swift `--log-scale` or Python `cqt_synth.py` |
| Linear axis + adaptive resolution | Swift `--multiresolution` |
| Log axis + adaptive resolution (best low-freq detail) | Python `cqt_synth.py` (CQT) |
| Verify output against source | `bash check.sh out/foo.wav` |
