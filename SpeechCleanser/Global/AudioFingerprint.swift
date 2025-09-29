//
//  AudioFingerprint.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import AVFoundation
import Accelerate

struct AudioFingerprint {
    private static let segmentCount = 64
    
    private static func normalize(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        
        var mean: Float = 0
        vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))
        
        var centered = [Float](repeating: 0, count: values.count)
        var negativeMean = -mean
        vDSP_vsadd(values, 1, &negativeMean, &centered, 1, vDSP_Length(values.count))
        
        var std: Float = 0
        vDSP_measqv(centered, 1, &std, vDSP_Length(values.count))
        std = sqrtf(std)
        
        guard std > .ulpOfOne else { return centered }
        
        var normalized = [Float](repeating: 0, count: values.count)
        var divisor = std
        vDSP_vsdiv(centered, 1, &divisor, &normalized, 1, vDSP_Length(values.count))
        return normalized
    }
    
    static func fromFile(url: URL) -> (fingerprint: [Float], duration: TimeInterval) {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            print("[AudioFingerprint][ERROR] fromFile: AVAudioFile failed with error: \(error.localizedDescription)")
            return ([], 0)
        }
        
        let processingFormat = audioFile.processingFormat
        let frameCapacity = AVAudioFrameCount(audioFile.length)
        
        guard let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: processingFormat.sampleRate, channels: processingFormat.channelCount, interleaved: false) else {
            print("[AudioFingerprint][ERROR] fromFile: Unable to create float format")
            return ([], 0)
        }
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: frameCapacity) else {
            print("[AudioFingerprint][ERROR] fromFile: AudioFingerprint unableToCreateBuffer")
            return ([], 0)
        }
        
        do {
            try audioFile.read(into: buffer)
        } catch {
            print("[AudioFingerprint][ERROR] fromFile: AVAudioFile failed with error: \(error.localizedDescription)")
            return ([], 0)
        }
        
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            print("[AudioFingerprint][ERROR] fromFile: AudioFingerprint emptySignal")
            return ([], 0)
        }
        
        guard let floatPointers = buffer.floatChannelData else {
            print("[AudioFingerprint][ERROR] fromFile: Missing float channel data")
            return ([], 0)
        }
        
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else {
            print("[AudioFingerprint][ERROR] fromFile: AudioFingerprint missingChannels")
            return ([], 0)
        }
        
        let channels = UnsafeBufferPointer(start: floatPointers, count: channelCount)
        var monoSamples: [Float] = []
        if channelCount == 1, let firstPointer = channels.first {
            monoSamples = Array(UnsafeBufferPointer(start: firstPointer, count: frameLength))
        } else {
            monoSamples = [Float](repeating: 0, count: frameLength)
            monoSamples.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                for pointer in channels {
                    vDSP_vadd(pointer, 1, baseAddress, 1, baseAddress, 1, vDSP_Length(frameLength))
                }
                var divisor = Float(channelCount)
                vDSP_vsdiv(baseAddress, 1, &divisor, baseAddress, 1, vDSP_Length(frameLength))
            }
        }
        
        let fingerprint = generateFingerprint(from: monoSamples, segments: segmentCount)
        let duration = TimeInterval(Double(frameLength) / floatFormat.sampleRate)
        
        return (fingerprint, duration)
    }
    
    static func generateFingerprint(from samples: [Float], segments: Int = segmentCount) -> [Float] {
        guard !samples.isEmpty else {
            print("[AudioFingerprint][ERROR] generateFingerprint: Empty samples input")
            return []
        }
        
        let totalSamples = samples.count
        let segmentLength = max(1, totalSamples / segments)
        var fingerprint: [Float] = []
        fingerprint.reserveCapacity(segments)
        
        let normalizedSamples = normalize(samples)
        normalizedSamples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }

            for startIndex in stride(from: 0, to: totalSamples, by: segmentLength) {
                let upperBound = min(startIndex + segmentLength, totalSamples)
                let count = upperBound - startIndex
                var energy: Float = 0
                vDSP_measqv(baseAddress + startIndex, 1, &energy, vDSP_Length(count))
                let rms = sqrtf(energy)
                fingerprint.append(rms)
                if fingerprint.count == segments { break }
            }
        }
        
        if fingerprint.count < segments, let last = fingerprint.last {
            fingerprint.append(contentsOf: Array(repeating: last, count: segments - fingerprint.count))
        }
        
        return normalize(fingerprint)
    }
    
    static func similarity(between lhs: [Float], and rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        
        let normalizedLHS = normalize(lhs)
        let normalizedRHS = normalize(rhs)
        
        var dot: Float = 0
        vDSP_dotpr(normalizedLHS, 1, normalizedRHS, 1, &dot, vDSP_Length(lhs.count))
        
        return max(-1, min(1, dot / Float(lhs.count)))
    }
}
