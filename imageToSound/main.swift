
import Foundation
import AppKit
import ArgumentParser
import AVFoundation
import Progress

struct FrameData {
    var frequency: Float32
    var strength: Float32
}

/*
 TODO:
 - Parallel computation of frequencies
 */

struct ImageToSound: ParsableCommand {
    @Argument(help: "Source image file path")
    var imagePath: String

    @Option(help: "Output sample rate")
    var samplerate: Int = 44100

    @Option(help: "Frequency lower limit")
    var minFrequency: Int = 0

    @Option(help: "Frequency upper limit. By default is sample rate / 2")
    var maxFrequency: Int = -1

    @Option(help: "Output frames per pixel")
    var framesPerPixel: Int = 2000

    @Option(help: "Ramp frames. By default is frame per pixel / 2")
    var rampFrames: Int = -1

    @Flag(help: "Invert image")
    var invert: Bool = false

    var imageBasename: String {
        let url = URL(filePath: imagePath) as NSURL
        return url.deletingPathExtension!.lastPathComponent
    }

    var realRampFrames: Int = 0

    func run() throws {
        guard let image = NSImage(contentsOf: URL(filePath: imagePath)) else {
            print("Can't read image: \(imagePath)")
            return
        }

        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let pixelData = cgImage.dataProvider?.data
        let data: UnsafePointer<UInt8> = CFDataGetBytePtr(pixelData)

        let totalSamples = framesPerPixel * Int(image.size.width)
        let height = Float32(image.size.height)

        var samples: [Float32] = []
        let scale: Float32 = 1.5
        var currentFrame: Int = 0

        let alpha: Float32 = 4.25
        let maxFrequency: Float32 = maxFrequency < 0 ? Float32(samplerate / 2) : Float32(maxFrequency)
        let minFrequency: Float32 = Float32(minFrequency)
        let freqSpread: Float32 = maxFrequency - minFrequency
        var previousFrames: [FrameData] = []

        for i in Progress(0..<Int(image.size.width)) {
            var framesForColumn: [FrameData] = []

            for j in 0..<Int(image.size.height) {
                let color = getPixelColor(data: data, width: cgImage.width, pos: CGPoint(x: Double(i), y: Double(image.size.height - CGFloat(j))))!
                let frequency = minFrequency + Float32(j + 1) / (height + 1) * freqSpread
                var brightness = Float32(color.brightnessComponent)
                if invert {
                    brightness = 1 - brightness
                }
                let strength = scale * 10 / pow(10, Float32(alpha - alpha * brightness))
                let frameData: FrameData = FrameData(frequency: frequency, strength: strength)
                framesForColumn.append(frameData)
            }
            samples.append(contentsOf: generateSineWave(startFrame: currentFrame, frames: framesForColumn, previousFrames: previousFrames))
            currentFrame = currentFrame + framesPerPixel
            previousFrames = framesForColumn
        }

        samples = normalizeSamples(samples)

        // Write out data
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(samplerate), channels: 1, interleaved: false)!
        let url = URL(fileURLWithPath: "\(imageBasename).wav")
        let audioFile = try! AVAudioFile(forWriting: url, settings: format.settings)

        print("Writing audio to \(url.absoluteString)")

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalSamples))!
        _ = buffer.floatChannelData?.pointee.withMemoryRebound(to: Float.self, capacity: totalSamples) {
            memcpy($0, samples, totalSamples * MemoryLayout<Float>.size)
        }
        buffer.frameLength = AVAudioFrameCount(totalSamples)

        do {
            try audioFile.write(from: buffer)
        } catch {
            print("Failed to save results to file \(url.absoluteString): \(error)")
        }
    }

    func generateSineWave(startFrame: Int, frames: [FrameData], previousFrames: [FrameData]) -> [Float32] {
        let sampleRate = Float32(samplerate)

        let times = (startFrame..<(startFrame + framesPerPixel)).map { Float32($0) / sampleRate }

        var outputSamples: [Float32] = []
        outputSamples.reserveCapacity(times.count)
        let count: Float32 = Float32(times.count)
        let rampNeeded = previousFrames.count > 0
        let realRampFrames: Int = rampFrames < 0 ? framesPerPixel / 2 : rampFrames

        let samples = times.enumerated().map { frameNumber, time in
            var result: Float32 = 0

            for (index, f) in frames.enumerated() {
                var k = f.strength
                let frequency: Float32 = f.frequency
                if rampNeeded && (frameNumber < realRampFrames) {
                    let rampValue: Float32 = Float32(frameNumber) / Float32(realRampFrames)
                    k = (1 - rampValue) * previousFrames[index].strength + rampValue * f.strength
                }
                let h = index % 2 == 0
                let shift: Float32 = 3 * .pi * Float32(index) / count

                if k > .ulpOfOne {
                    let arg = 2.0 * .pi * frequency * (time + shift)
                    let sine = k * (h ? sin(arg) : cos(arg))
                    result += sine
                }
            }

            return result
        }

        return samples
    }

    func normalizeSamples(_ samples: [Float32]) -> [Float32] {
        var absMax: Float32 = 0
        let finalX: Float32 = 0.5
        for s in samples {
            if abs(s) > absMax {
                absMax = abs(s)
            }
        }

        return samples.map { finalX * $0 / absMax }
    }

    func getPixelColor(data: UnsafePointer<UInt8>, width: Int, pos: CGPoint) -> NSColor? {
        let pixelInfo: Int = ((width * Int(pos.y)) + Int(pos.x)) * 4
        let r = CGFloat(data[pixelInfo]) / CGFloat(255.0)
        let g = CGFloat(data[pixelInfo + 1]) / CGFloat(255.0)
        let b = CGFloat(data[pixelInfo + 2]) / CGFloat(255.0)
        let a = CGFloat(data[pixelInfo + 3]) / CGFloat(255.0)

        return NSColor(red: r, green: g, blue: b, alpha: a)
    }

    // Debug only
    func dumpSamples(samples: [Float32], start: Int, count: Int, suffix: String = "") {
        let url = URL(fileURLWithPath: "\(imageBasename)\(suffix).csv")
        var csvData = ""
        for i in start..<(start + count) {
            let sample = samples[i]
            let line = "\(i), \(sample)\n"
            csvData.append(line)
        }
        try! csvData.data(using: .utf8)?.write(to: url)
    }
}

ImageToSound.main()
