//
//  main.swift
//  imageToSound
//
//  Created by Valentine Gorshkov on 17.04.2023.
//

import Foundation
import AppKit
import ArgumentParser
import AVFoundation
import Progress

struct FrameData {
    var frequency: Float32
    var strength: Float32
}

struct ImageToSound: ParsableCommand {
    @Argument(help: "Source image file path")
    var imagePath: String

    @Option(help: "Output sample rate")
    var samplerate: Int = 22050

    @Option(help: "Output frames per pixel")
    var framesPerPixel: Int = 1000

    @Flag(help: "Invert image")
    var invert: Bool = false

    func run() throws {
        print("Image path: \(imagePath), sample rate: \(samplerate)")

        guard let image = NSImage(contentsOf: URL(filePath: imagePath)) else {
            print("Can't read image: \(imagePath)")
            return
        }

        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let pixelData = cgImage.dataProvider?.data
        let data: UnsafePointer<UInt8> = CFDataGetBytePtr(pixelData)

        print("Image loaded! \(image)")
        let totalSamples = framesPerPixel * Int(image.size.width)
        let height = Float32(image.size.height)

        var samples: [Float32] = []
        let scale: Float32 = 1.5
        var startTime: Int = 0

        print("Amplitude scale: \(scale)")

        let alpha: Float32 = 4.25
        let maxFrequency = Float32(samplerate / 2)

        for i in Progress(0..<Int(image.size.width)) {
            var framesForColumn: [FrameData] = []

            for j in 0..<Int(image.size.height) {
                let color = getPixelColor(data: data, width: cgImage.width, pos: CGPoint(x: Double(i), y: Double(image.size.height - CGFloat(j))))!
                let frequency = Float32(j + 1) / (height + 1) * maxFrequency
                var brightness = Float32(color.brightnessComponent)//Float32(color.redComponent + color.greenComponent + color.blueComponent) / 3
                if invert {
                    brightness = 1 - brightness
                }
                var strength = scale * 10 / pow(10, Float32(alpha - alpha * brightness))
                if strength < scale * 0.01 {
                    strength = 0
                }
                let frameData: FrameData = FrameData(frequency: frequency, strength: strength)
                framesForColumn.append(frameData)
            }
            samples.append(contentsOf: generateSineWaveAudio(startTime: startTime, frames: framesForColumn))
            startTime = startTime + framesPerPixel
        }

        dumpSamples(samples: samples, start: 0, count: framesPerPixel * 2, suffix: "_raw")

        samples = normalizeSamples(samples)

        dumpSamples(samples: samples, start: 0, count: framesPerPixel * 2, suffix: "_norm")

//        samples = compressSamples(samples)
//
//        dumpSamples(samples: samples, start: 0, count: framesPerPixel * 2, suffix: "_compressed")
//
//        samples = normalizeSamples(samples)
//
//        dumpSamples(samples: samples, start: 0, count: framesPerPixel * 2, suffix: "_norm2")

        // Write out data
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(samplerate), channels: 1, interleaved: false)!
        let url = URL(fileURLWithPath: "\(imagePath).wav")
        let audioFile = try! AVAudioFile(forWriting: url, settings: format.settings)

        print("Writing audio to \(url)")

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalSamples))!
        _ = buffer.floatChannelData?.pointee.withMemoryRebound(to: Float.self, capacity: totalSamples) {
            memcpy($0, samples, totalSamples * MemoryLayout<Float>.size)
        }
        buffer.frameLength = AVAudioFrameCount(totalSamples)

        try! audioFile.write(from: buffer)
    }

    func generateSineWaveAudio(startTime: Int, frames: [FrameData]) -> [Float32] {
        let sampleRate = Float32(samplerate)

        let times = (startTime..<(startTime + framesPerPixel)).map { Float32($0) / sampleRate }

        var outputSamples: [Float32] = []
        outputSamples.reserveCapacity(times.count)

        let samples = times.map { time in
            var result: Float32 = 0

            for (index, f) in frames.enumerated() {
                let k = f.strength
                let frequency = f.frequency
                let h = index % 2 == 0
                let shift = Float32(index) / frequency

                if k > .ulpOfOne {
                    let arg = 2.0 * .pi * frequency * time + shift
                    let sine = k * (h ? sin(arg) : cos(arg))
                    result += sine
                }
            }

            return result
        }

        return samples
    }

    func compressSamples(_ samples: [Float32]) -> [Float32] {
        let thr: Float32 = 0.1
        let ratio: Float32 = 10.0
        return samples.map { abs($0) > thr ? $0 / ratio : $0 }
    }

    func normalizeSamples(_ samples: [Float32]) -> [Float32] {
        var absMax: Float32 = 0
        let finalX: Float32 = 0.8
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

    func dumpSamples(samples: [Float32], start: Int, count: Int, suffix: String = "") {
        let url = URL(fileURLWithPath: "\(imagePath)\(suffix).csv")
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
