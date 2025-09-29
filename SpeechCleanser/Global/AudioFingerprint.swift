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
        vDSP_vsb(values, 1, &mean, &centered, 1, vDSP_Length(values.count))
        
        var std: Float = 0
        vDSP_measqv(centered, 1, &std, vDSP_Length(values.count))
        std = sqrtf(std / Float(values.count))
        
        guard std > .ulpOfOne else { return centered }
        
        var normalized = [Float](repeating: 0, count: values.count)
        var divisor = std
        vDSP_vsdiv(centered, 1, &divisor, &normalized, 1, vDSP_Length(values.count))
        return normalized
    }
    
    static func fromFile(url: URL) -> (fingerprint: [Float], duration: TimeInterval) {
        var audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            print("AVAudioFile failed with error: \(error.localizedDescription)")
        }
        
        let processingFormat = audioFile.processingFormat
        let frameCapacity = AVAudioFrameCount(audioFile.length)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCapacity) else {
            print("AudioFingerprint unableToCreateBuffer")
            return
        }
        
        do {
            try audioFile.read(into: buffer)
        } catch {
            print("AVAudioFile failed with error: \(error.localizedDescription)")
        }
        
        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            print("AudioFingerprint emptySignal")
            return
        }
        
        let frameLength = Int(buffer.frameLength)
        let data = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
        
        let fingerprint = generateFingerprint(from: data, segments: segmentCount)
        let duration = TimeInterval(Double(frameLength) / processingFormat.sampleRate)
        
        return (fingerprint, duration)
    }
    
    static func generateFingerprint(from samples: [Float], segments: Int = segmentCount) -> [Float] {
        guard !samples.isEmpty else { return [] }
        
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
                let rms = sqrtf(energy / Float(max(count, 1)))
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
