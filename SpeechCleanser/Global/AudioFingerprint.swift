//
//  AudioFingerprint.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import AVFoundation
import Accelerate

struct AudioFingerprint {
    static let defaultSampleRate: Double = 16_000
    static let defaultWindowDuration: TimeInterval = 0.08
    static let defaultHopDuration: TimeInterval = 0.04
    
    let fingerprint: [Float]
    let duration: TimeInterval
    let rms: Float
    let sampleRate: Double
    let windowSize: Int
    let hopSize: Int
    
    private static func emptyResult() -> AudioFingerprint {
        let window = max(1, Int(defaultSampleRate * defaultWindowDuration))
        let hop = max(1, Int(defaultSampleRate * defaultHopDuration))
        return AudioFingerprint(fingerprint: [], duration: 0, rms: 0, sampleRate: defaultSampleRate, windowSize: window, hopSize: hop)
    }
    
    private static func resampleIfNeeded(samples: [Float], sourceRate: Double, targetRate: Double) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let rateDifference = abs(sourceRate - targetRate)
        if rateDifference < 1 { return samples }
        
        let ratio = targetRate / sourceRate
        let estimatedCount = max(1, Int(round(Double(samples.count) * ratio)))
        var output = [Float](repeating: 0, count: estimatedCount)
        let step = sourceRate / targetRate
        var position = 0.0
        
        for index in 0..<estimatedCount {
            let lowerIndex = min(Int(position), max(samples.count - 1, 0))
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(position - Double(lowerIndex))
            let lower = samples[lowerIndex]
            let upper = samples[upperIndex]
            output[index] = lower + (upper - lower) * fraction
            position += step
        }
        
        return output
    }
    
    static func fromFile(url: URL) -> AudioFingerprint {
        let fallback = emptyResult()
        
        do {
            let file = try AVAudioFile(forReading: url)
            let processingFormat = file.processingFormat
            let frameCapacity = AVAudioFrameCount(file.length)
            
            guard frameCapacity > 0 else {
                print("[AudioFingerprint][ERROR] fromFile: File has zero frames at \(url.lastPathComponent)")
                return fallback
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCapacity) else {
                print("[AudioFingerprint][ERROR] fromFile: Unable to allocate buffer for \(url.lastPathComponent)")
                return fallback
            }
            
            try file.read(into: buffer)
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else {
                print("[AudioFingerprint][ERROR] fromFile: Buffer has zero length for \(url.lastPathComponent)")
                return fallback
            }
            guard let channelData = buffer.floatChannelData else {
                print("[AudioFingerprint][ERROR] fromFile: Missing channel data for \(url.lastPathComponent)")
                return fallback
            }
            
            let channelCount = Int(processingFormat.channelCount)
            var monoSamples = [Float](repeating: 0, count: frameLength)
            
            if channelCount == 1 {
                let channelPointer = channelData[0]
                let pointer = UnsafeBufferPointer(start: UnsafePointer(channelPointer), count: frameLength)
                monoSamples = Array(pointer)
            } else {
                for frame in 0..<frameLength {
                    var sum: Float = 0
                    for channel in 0..<channelCount {
                        let channelPointer = channelData[channel]
                        sum += channelPointer[frame]
                    }
                    monoSamples[frame] = sum / Float(max(channelCount, 1))
                }
            }
            
            let sourceSampleRate = processingFormat.sampleRate
            let resampled = resampleIfNeeded(samples: monoSamples, sourceRate: sourceSampleRate, targetRate: defaultSampleRate)
            let totalSamples = resampled.count
            guard totalSamples > 0 else {
                print("[AudioFingerprint][ERROR] fromFile: Resampling yielded zero samples for \(url.lastPathComponent)")
                return fallback
            }
            
            var meanSquare: Float = 0
            resampled.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                vDSP_measqv(base, 1, &meanSquare, vDSP_Length(totalSamples))
            }
            
            let overallRMS = sqrtf(meanSquare)
            let windowSamples = max(1, Int(defaultSampleRate * defaultWindowDuration))
            let hopSamples = max(1, Int(defaultSampleRate * defaultHopDuration))
            
            var features: [Float] = []
            features.reserveCapacity(totalSamples / hopSamples)
            resampled.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                var index = 0
                while index + windowSamples <= totalSamples {
                    let segment = base.advanced(by: index)
                    var segmentPower: Float = 0
                    vDSP_measqv(segment, 1, &segmentPower, vDSP_Length(windowSamples))
                    let value = sqrtf(segmentPower)
                    features.append(value)
                    index += hopSamples
                }
            }
            
            if features.isEmpty {
                var fallbackPower: Float = 0
                resampled.withUnsafeBufferPointer { pointer in
                    guard let base = pointer.baseAddress else { return }
                    vDSP_measqv(base, 1, &fallbackPower, vDSP_Length(totalSamples))
                }
                let fallbackRMS = sqrtf(fallbackPower)
                features = [fallbackRMS]
            }
            
            var mean: Float = 0
            features.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                vDSP_meanv(base, 1, &mean, vDSP_Length(features.count))
            }
            
            features.withUnsafeMutableBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                
                let count = pointer.count
                var negativeMean = -mean
                vDSP_vsadd(base, 1, &negativeMean, base, 1, vDSP_Length(count))
                
                var magnitude: Float = 0
                vDSP_dotpr(base, 1, base, 1, &magnitude, vDSP_Length(count))
                let norm = sqrtf(magnitude)
                
                if norm > 1e-5 {
                    var inverse = 1 / norm
                    vDSP_vsmul(base, 1, &inverse, base, 1, vDSP_Length(count))
                } else {
                    for index in 0..<count {
                        base[index] = 0
                    }
                }
            }
            
            let seconds = Double(totalSamples) / defaultSampleRate
            let result = AudioFingerprint(
                fingerprint: features,
                duration: seconds,
                rms: overallRMS,
                sampleRate: defaultSampleRate,
                windowSize: windowSamples,
                hopSize: hopSamples
            )
            
            print("[AudioFingerprint] fromFile: Generated fingerprint with \(features.count) windows for \(url.lastPathComponent) duration=\(String(format: "%.2f", seconds))s")
            return result
        } catch {
            print("[AudioFingerprint][ERROR] fromFile: Failed to analyse \(url.lastPathComponent) with error: \(error.localizedDescription)")
            return fallback
        }
    }
}
