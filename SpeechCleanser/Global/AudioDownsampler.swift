//
//  AudioDownsampler.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import AVFoundation

struct AudioDownsampler {
    let targetSampleRate: Double
    
    func convert(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            print("[AudioDownsampler][ERROR] convert: Missing channel data")
            return []
        }
        
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return [] }
        
        var mono = [Float](repeating: 0, count: frameLength)
        for channelIndex in 0..<channelCount {
            let channel = channelData[channelIndex]
            for frame in 0..<frameLength {
                mono[frame] += channel[frame]
            }
        }
        
        if channelCount > 1 {
            let divisor = Float(channelCount)
            for index in 0..<frameLength {
                mono[index] /= divisor
            }
        }
        
        let sampleRate = buffer.format.sampleRate
        if sampleRate == targetSampleRate {
            return mono
        }
        
        if sampleRate <= 0 {
            print("[AudioDownsampler][ERROR] convert: Invalid sample rate \(sampleRate)")
            return []
        }
        
        let ratio = sampleRate / targetSampleRate
        if ratio <= 0 {
            print("[AudioDownsampler][ERROR] convert: Invalid ratio computed")
            return []
        }
        
        var result: [Float] = []
        var position: Double = 0
        let upperBound = Double(mono.count)
        
        while position < upperBound {
            let lowerIndex = Int(position)
            if lowerIndex >= mono.count { break }

            let nextIndex = min(lowerIndex + 1, mono.count - 1)
            let fraction = Float(position - Double(lowerIndex))
            let interpolated = mono[lowerIndex] + (mono[nextIndex] - mono[lowerIndex]) * fraction
            result.append(interpolated)
            position += ratio
        }
        
        return result
    }
}
