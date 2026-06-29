import Foundation
import AppKit
import ArgumentParser
import AVFoundation
import Accelerate
import Progress

struct Band {
    let fftSize: Int
    let hopSize: Int
    let freqLow: Float       // ramp-in starts here (silent below)
    let freqLowFull: Float   // full magnitude from here
    let freqHighFull: Float  // full magnitude up to here
    let freqHigh: Float      // ramp-out ends here (silent above)

    func weight(_ f: Float) -> Float {
        if f <= freqLow || f >= freqHigh { return 0 }
        if f < freqLowFull && freqLowFull > freqLow {
            let r = (f - freqLow) / (freqLowFull - freqLow)
            return 0.5 * (1 - cos(.pi * r))
        }
        if f > freqHighFull && freqHigh > freqHighFull {
            let r = (f - freqHighFull) / (freqHigh - freqHighFull)
            return 0.5 * (1 + cos(.pi * r))
        }
        return 1
    }
}

struct ImageToSound: ParsableCommand {
    @Argument(help: "Source image file path")
    var imagePath: String

    @Option(help: "Output sample rate")
    var samplerate: Int = 44100

    @Option(help: "Frequency lower limit (Hz)")
    var minFrequency: Int = 20

    @Option(help: "Frequency upper limit (Hz, default: samplerate/2)")
    var maxFrequency: Int = -1

    @Option(help: "Output frames per pixel")
    var framesPerPixel: Int = 2000

    @Option(help: "FFT size (power of 2, or 'auto' to derive from image height and frequency range)")
    var fftSize: String = "auto"

    @Option(help: "Hop size in samples (0 = fftSize/4)")
    var hopSize: Int = 0

    @Option(help: "Griffin-Lim iterations")
    var glIterations: Int = 60

    @Option(help: "Fast Griffin-Lim momentum (0 = classic GL, 0.99 recommended)")
    var glMomentum: Float = 0.99

    @Option(help: "Magnitude curve exponent (>1 emphasizes bright pixels)")
    var magCurve: Float = 2.0

    @Flag(help: "Invert image brightness")
    var invert: Bool = false

    @Flag(help: "Use logarithmic frequency scale")
    var logScale: Bool = false

    @Flag(help: "Multiresolution STFT (3 bands: large FFT at low freq, small at high)")
    var multiresolution: Bool = false

    @Flag(help: "Synthesize with narrow-band white noise instead of sines (random phase, no Griffin-Lim)")
    var noise: Bool = false

    @Flag(help: "Virtual ANS additive synth: a wavetable sine bank, one oscillator per pixel row (log scale only). Bypasses STFT/Griffin-Lim.")
    var vans: Bool = false

    @Option(help: "Oscillators per row in --vans mode (≥1; multiple detuned voices decorrelate low-freq partials)")
    var vansVoices: Int = 2

    @Option(help: "Detune spread for --vans voices, as a fraction of one row's log-frequency spacing (0..1)")
    var vansSpread: Float = 0.5

    @Option(help: "Output directory")
    var outputDir: String = "."

    func validate() throws {
        if vans && !logScale {
            throw ValidationError("--vans requires --log-scale")
        }
        if vans && multiresolution {
            throw ValidationError("--vans is incompatible with --multiresolution")
        }
        if vans && noise {
            throw ValidationError("--vans is incompatible with --noise")
        }
        if vansVoices < 1 {
            throw ValidationError("--vans-voices must be ≥ 1")
        }
    }

    var imageBasename: String {
        let url = URL(filePath: imagePath) as NSURL
        return url.deletingPathExtension!.lastPathComponent
    }

    func run() throws {
        guard let image = NSImage(contentsOf: URL(filePath: imagePath)),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("Can't read image: \(imagePath)")
            return
        }
        let pixelData = cgImage.dataProvider!.data!
        let data = CFDataGetBytePtr(pixelData)!

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        let audioLength = framesPerPixel * width
        let sampleRate = Float(samplerate)
        let nyq = sampleRate / 2

        print("Image \(width)×\(height) → \(audioLength) samples (\(String(format: "%.2f", Float(audioLength)/sampleRate))s), logScale=\(logScale), multires=\(multiresolution), vans=\(vans)")

        var combined = [Float](repeating: 0, count: audioLength)
        if vans {
            let signal = synthesizeVANS(
                data: data,
                width: width, height: height,
                bytesPerPixel: bytesPerPixel, bytesPerRow: bytesPerRow,
                audioLength: audioLength
            )
            combined = signal
        } else {
            let bands: [Band]
            if multiresolution {
                bands = [
                    Band(fftSize: 16384, hopSize: 4096, freqLow: 0,    freqLowFull: 0,    freqHighFull: 250,  freqHigh: 500),
                    Band(fftSize: 4096,  hopSize: 1024, freqLow: 250,  freqLowFull: 500,  freqHighFull: 2500, freqHigh: 5000),
                    Band(fftSize: 1024,  hopSize: 256,  freqLow: 2500, freqLowFull: 5000, freqHighFull: nyq,  freqHigh: nyq),
                ]
            } else {
                let maxFreq = maxFrequency < 0 ? nyq : Float(maxFrequency)
                let minFreq = max(1, Float(minFrequency))
                let fft = try resolveFFTSize(height: height, sampleRate: sampleRate, minFreq: minFreq, maxFreq: maxFreq)
                let hop = hopSize > 0 ? hopSize : fft / 4
                bands = [Band(fftSize: fft, hopSize: hop, freqLow: -1, freqLowFull: -1, freqHighFull: nyq + 1, freqHigh: nyq + 1)]
            }

            for (i, band) in bands.enumerated() {
                print("Band \(i+1)/\(bands.count): FFT=\(band.fftSize), hop=\(band.hopSize), \(Int(band.freqLow))..\(Int(band.freqHigh)) Hz")
                let signal = synthesize(
                    band: band,
                    data: data,
                    width: width, height: height,
                    bytesPerPixel: bytesPerPixel, bytesPerRow: bytesPerRow,
                    audioLength: audioLength
                )
                for j in 0..<audioLength {
                    combined[j] += signal[j]
                }
            }
        }

        let normalized = normalize(combined, peak: 0.5)

        let fm = FileManager.default
        if !fm.fileExists(atPath: outputDir) {
            try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        }
        let url = URL(fileURLWithPath: "\(outputDir)/\(imageBasename).wav")
        try writeWAV(samples: normalized, url: url, sampleRate: samplerate)
        print("Wrote \(url.path)")
    }

    // Pick an FFT size giving ~one bin per image row inside the active band,
    // rounded to the nearest power of two and clamped to a sane range.
    func resolveFFTSize(height: Int, sampleRate: Float, minFreq: Float, maxFreq: Float) throws -> Int {
        if fftSize == "auto" {
            let target = Float(height) * sampleRate / max(1, maxFreq - minFreq)
            let exp = log2(target).rounded()
            let p = Int(pow(2, exp))
            let fft = min(max(p, 1024), 65536)
            print("Auto FFT size: \(fft) (\(String(format: "%.2f", sampleRate / Float(fft))) Hz/bin)")
            return fft
        }
        guard let n = Int(fftSize), n > 0, (n & (n - 1)) == 0 else {
            throw ValidationError("--fft-size must be 'auto' or a positive power of two, got '\(fftSize)'")
        }
        return n
    }

    func synthesizeVANS(data: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerPixel: Int, bytesPerRow: Int, audioLength: Int) -> [Float] {
        let sampleRate = Float(samplerate)
        let nyq = sampleRate / 2
        let maxFreq = min(nyq, maxFrequency < 0 ? nyq : Float(maxFrequency))
        let minFreq = max(1, Float(minFrequency))
        precondition(maxFreq > minFreq, "VANS: max-frequency must exceed min-frequency")

        let tableSize = 32768
        let tableSizeF = Float(tableSize)
        let tableMask = tableSize - 1
        var sineTable = [Float](repeating: 0, count: tableSize)
        for i in 0..<tableSize {
            sineTable[i] = sin(2 * .pi * Float(i) / tableSizeF)
        }

        let voices = max(1, vansVoices)
        let totalOscs = height * voices
        let voiceScale: Float = 1.0 / Float(voices)

        let logMin = log(minFreq)
        let logMax = log(maxFreq)
        let rowLogStep = (logMax - logMin) / Float(max(1, height - 1))

        var phaseInc = [Float](repeating: 0, count: totalOscs)
        var phase = [Float](repeating: 0, count: totalOscs)
        for row in 0..<height {
            let logF = logMin + rowLogStep * Float(height - 1 - row)
            for v in 0..<voices {
                let voiceOff: Float = voices == 1 ? 0 :
                    (Float(v) / Float(voices - 1) - 0.5) * vansSpread * rowLogStep
                let f = exp(logF + voiceOff)
                let idx = row * voices + v
                phaseInc[idx] = f * tableSizeF / sampleRate
                phase[idx] = Float.random(in: 0..<tableSizeF)
            }
        }

        var colAmps = [Float](repeating: 0, count: width * height)
        for col in 0..<width {
            for row in 0..<height {
                let pi = row * bytesPerRow + col * bytesPerPixel
                let r = Float(data[pi]) / 255.0
                let g = Float(data[pi + 1]) / 255.0
                let b = Float(data[pi + 2]) / 255.0
                var br = 0.299 * r + 0.587 * g + 0.114 * b
                if invert { br = 1 - br }
                colAmps[col * height + row] = pow(br, magCurve)
            }
        }

        print("VANS: \(totalOscs) oscillators (\(height) rows × \(voices) voices), log \(Int(minFreq))..\(Int(maxFreq)) Hz, spread=\(vansSpread)")

        var output = [Float](repeating: 0, count: audioLength)
        var amp = [Float](repeating: 0, count: height)
        var ampDelta = [Float](repeating: 0, count: height)
        let fpp = framesPerPixel

        sineTable.withUnsafeBufferPointer { tablePtr in
            phase.withUnsafeMutableBufferPointer { phasePtr in
                phaseInc.withUnsafeBufferPointer { incPtr in
                    amp.withUnsafeMutableBufferPointer { ampPtr in
                        ampDelta.withUnsafeMutableBufferPointer { dPtr in
                            output.withUnsafeMutableBufferPointer { outPtr in
                                colAmps.withUnsafeBufferPointer { caPtr in
                                    for col in Progress(0..<width) {
                                        let startSample = col * fpp
                                        let endSample = min(startSample + fpp, audioLength)
                                        let span = endSample - startSample
                                        if span <= 0 { continue }
                                        let spanF = Float(span)
                                        let colBase = col * height
                                        for row in 0..<height {
                                            dPtr[row] = (caPtr[colBase + row] - ampPtr[row]) / spanF
                                        }
                                        for s in startSample..<endSample {
                                            var val: Float = 0
                                            for row in 0..<height {
                                                let a = ampPtr[row]
                                                let base = row * voices
                                                let active = a > 1e-6
                                                var acc: Float = 0
                                                for v in 0..<voices {
                                                    let idx = base + v
                                                    var p = phasePtr[idx]
                                                    if active {
                                                        acc += tablePtr[Int(p) & tableMask]
                                                    }
                                                    p += incPtr[idx]
                                                    if p >= tableSizeF { p -= tableSizeF }
                                                    phasePtr[idx] = p
                                                }
                                                if active { val += acc * a * voiceScale }
                                                ampPtr[row] += dPtr[row]
                                            }
                                            outPtr[s] = val
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return output
    }

    func synthesize(band: Band, data: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerPixel: Int, bytesPerRow: Int, audioLength: Int) -> [Float] {
        let halfFFT = band.fftSize / 2
        let signalLength = audioLength + 2 * halfFFT
        let numFrames = (signalLength - band.fftSize) / band.hopSize + 1
        let numBins = halfFFT + 1
        let sampleRate = Float(samplerate)
        let maxFreq: Float = maxFrequency < 0 ? sampleRate / 2 : Float(maxFrequency)
        let minFreq: Float = max(1, Float(minFrequency))

        var magnitudes = [Float](repeating: 0, count: numFrames * numBins)
        for f in 0..<numFrames {
            let audioPos = f * band.hopSize
            let col = min(width - 1, max(0, audioPos / framesPerPixel))

            for k in 0..<numBins {
                let freq = Float(k) * sampleRate / Float(band.fftSize)
                let w = band.weight(freq)
                if w <= 0 { continue }
                if freq < minFreq || freq > maxFreq { continue }

                let yNorm: Float
                if logScale {
                    yNorm = log2(freq / minFreq) / log2(maxFreq / minFreq)
                } else {
                    yNorm = (freq - minFreq) / (maxFreq - minFreq)
                }
                if yNorm < 0 || yNorm > 1 { continue }

                let imageY = min(height - 1, max(0, height - 1 - Int(yNorm * Float(height))))

                let pixelInfo = imageY * bytesPerRow + col * bytesPerPixel
                let r = Float(data[pixelInfo]) / 255.0
                let g = Float(data[pixelInfo + 1]) / 255.0
                let b = Float(data[pixelInfo + 2]) / 255.0
                var brightness = 0.299 * r + 0.587 * g + 0.114 * b
                if invert { brightness = 1 - brightness }

                magnitudes[f * numBins + k] = pow(brightness, magCurve) * w
            }
        }

        let proc = STFTProcessor(fftSize: band.fftSize, hopSize: band.hopSize)
        let signal: [Float]
        if noise {
            signal = proc.noiseSynth(
                magnitude: magnitudes,
                numFrames: numFrames,
                numBins: numBins,
                signalLength: signalLength
            )
        } else {
            signal = proc.griffinLim(
                magnitude: magnitudes,
                numFrames: numFrames,
                numBins: numBins,
                iterations: glIterations,
                momentum: glMomentum,
                signalLength: signalLength
            )
        }
        return Array(signal[halfFFT..<(halfFFT + audioLength)])
    }

    func normalize(_ samples: [Float], peak: Float) -> [Float] {
        var maxAbs: Float = 0
        vDSP_maxmgv(samples, 1, &maxAbs, vDSP_Length(samples.count))
        if maxAbs < 1e-8 { return samples }
        var scale = peak / maxAbs
        var result = [Float](repeating: 0, count: samples.count)
        vDSP_vsmul(samples, 1, &scale, &result, 1, vDSP_Length(samples.count))
        return result
    }

    func writeWAV(samples: [Float], url: URL, sampleRate: Int) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData!.pointee.update(from: src.baseAddress!, count: samples.count)
        }
        try audioFile.write(from: buffer)
    }
}

final class STFTProcessor {
    let fftSize: Int
    let hopSize: Int
    let window: [Float]
    private let forwardSetup: OpaquePointer
    private let inverseSetup: OpaquePointer

    init(fftSize: Int, hopSize: Int) {
        self.fftSize = fftSize
        self.hopSize = hopSize
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), 0)
        self.window = w
        self.forwardSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)!
        self.inverseSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .INVERSE)!
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    func stft(signal: [Float], real: inout [Float], imag: inout [Float], numFrames: Int, numBins: Int) {
        var inReal = [Float](repeating: 0, count: fftSize)
        let inImag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)

        for f in 0..<numFrames {
            let start = f * hopSize
            for n in 0..<fftSize {
                inReal[n] = signal[start + n] * window[n]
            }
            vDSP_DFT_Execute(forwardSetup, inReal, inImag, &outReal, &outImag)
            for k in 0..<numBins {
                real[f * numBins + k] = outReal[k]
                imag[f * numBins + k] = outImag[k]
            }
        }
    }

    func istft(real: [Float], imag: [Float], numFrames: Int, numBins: Int, signalLength: Int) -> [Float] {
        var signal = [Float](repeating: 0, count: signalLength)
        var winSum = [Float](repeating: 0, count: signalLength)
        var inReal = [Float](repeating: 0, count: fftSize)
        var inImag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)
        let norm: Float = 1.0 / Float(fftSize)
        let halfFFT = fftSize / 2

        for f in 0..<numFrames {
            let start = f * hopSize
            for k in 0..<fftSize {
                inReal[k] = 0
                inImag[k] = 0
            }
            for k in 0..<numBins {
                inReal[k] = real[f * numBins + k]
                inImag[k] = imag[f * numBins + k]
            }
            for k in 1..<halfFFT {
                inReal[fftSize - k] = real[f * numBins + k]
                inImag[fftSize - k] = -imag[f * numBins + k]
            }
            vDSP_DFT_Execute(inverseSetup, inReal, inImag, &outReal, &outImag)
            for n in 0..<fftSize {
                let i = start + n
                if i < signalLength {
                    signal[i] += outReal[n] * window[n] * norm
                    winSum[i] += window[n] * window[n]
                }
            }
        }
        for i in 0..<signalLength {
            if winSum[i] > 1e-8 {
                signal[i] /= winSum[i]
            }
        }
        return signal
    }

    func noiseSynth(magnitude: [Float], numFrames: Int, numBins: Int, signalLength: Int) -> [Float] {
        let total = numFrames * numBins
        var real = [Float](repeating: 0, count: total)
        var imag = [Float](repeating: 0, count: total)
        for i in 0..<total {
            let phase = Float.random(in: 0..<(2 * .pi))
            real[i] = magnitude[i] * cos(phase)
            imag[i] = magnitude[i] * sin(phase)
        }
        return istft(real: real, imag: imag, numFrames: numFrames, numBins: numBins, signalLength: signalLength)
    }

    func griffinLim(magnitude: [Float], numFrames: Int, numBins: Int, iterations: Int, momentum: Float, signalLength: Int) -> [Float] {
        let total = numFrames * numBins
        var tReal = [Float](repeating: 0, count: total)
        var tImag = [Float](repeating: 0, count: total)
        var cPrevReal = [Float](repeating: 0, count: total)
        var cPrevImag = [Float](repeating: 0, count: total)
        var consistentReal = [Float](repeating: 0, count: total)
        var consistentImag = [Float](repeating: 0, count: total)

        for i in 0..<total {
            let phase = Float.random(in: 0..<(2 * .pi))
            tReal[i] = magnitude[i] * cos(phase)
            tImag[i] = magnitude[i] * sin(phase)
        }

        for iter in Progress(0..<iterations) {
            let signal = istft(real: tReal, imag: tImag, numFrames: numFrames, numBins: numBins, signalLength: signalLength)
            stft(signal: signal, real: &consistentReal, imag: &consistentImag, numFrames: numFrames, numBins: numBins)

            var cReal = [Float](repeating: 0, count: total)
            var cImag = [Float](repeating: 0, count: total)
            for i in 0..<total {
                let mag = sqrt(consistentReal[i] * consistentReal[i] + consistentImag[i] * consistentImag[i])
                if mag > 1e-10 {
                    cReal[i] = magnitude[i] * consistentReal[i] / mag
                    cImag[i] = magnitude[i] * consistentImag[i] / mag
                } else {
                    cReal[i] = magnitude[i]
                    cImag[i] = 0
                }
            }

            if iter > 0 && momentum > 0 {
                for i in 0..<total {
                    tReal[i] = cReal[i] + momentum * (cReal[i] - cPrevReal[i])
                    tImag[i] = cImag[i] + momentum * (cImag[i] - cPrevImag[i])
                }
            } else {
                tReal = cReal
                tImag = cImag
            }
            cPrevReal = cReal
            cPrevImag = cImag
        }

        return istft(real: tReal, imag: tImag, numFrames: numFrames, numBins: numBins, signalLength: signalLength)
    }
}

ImageToSound.main()
