//
//  AudioTimestampEstimator.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 4.10.25.
//

import AVFoundation
import Darwin

class AudioTimestampEstimator {
    private let sourceSampleRate: Double
    private var referenceSampleTime: AVAudioFramePosition?
    private var referenceDate: Date?
    
    init(sourceSampleRate: Double) {
        self.sourceSampleRate = sourceSampleRate
    }
    
    private static func date(fromHostTime hostTime: UInt64) -> Date? {
        guard hostTime != 0 else { return nil }
        let hostSeconds = AVAudioTime.seconds(forHostTime: hostTime)
        let nowHostSeconds = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let delta = nowHostSeconds - hostSeconds
        return Date().addingTimeInterval(-delta)
    }
    
    func bufferStartDate(for time: AVAudioTime, frameLength: AVAudioFrameCount) -> Date {
        if time.isHostTimeValid, let hostDate = AudioTimestampEstimator.date(fromHostTime: time.hostTime) {
            return hostDate
        }
        
        if time.isSampleTimeValid {
            let sampleTime = time.sampleTime
            if let referenceSampleTime, let referenceDate {
                let deltaSamples = Double(sampleTime - referenceSampleTime)
                let offset = deltaSamples / sourceSampleRate
                return referenceDate.addingTimeInterval(offset)
            } else {
                referenceSampleTime = sampleTime
                referenceDate = Date()
                return referenceDate ?? Date()
            }
        }
        
        return Date()
    }
    
    func reset() {
        referenceSampleTime = nil
        referenceDate = nil
    }
}
