//
//  AudioEnergyNormalizer.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 4.10.25.
//

import Foundation

struct AudioEnergyNormalizer {
    private let targetRMS: Float
    private let maximumGain: Float
    private let maximumOutputPeak: Float
    private let minimumPeakForNormalization: Float
    
    init(targetRMS: Float = 0.11, maximumGain: Float = 18.0, maximumOutputPeak: Float = 0.92, minimumPeakForNormalization: Float = 0.0003) {
        self.targetRMS = targetRMS
        self.maximumGain = maximumGain
        self.maximumOutputPeak = maximumOutputPeak
        self.minimumPeakForNormalization = minimumPeakForNormalization
    }
    
    func normalize(samples: [Float], amplitude: (rms: Float, peak: Float)) -> Result? {
        guard samples.isEmpty == false else { return nil }
        guard amplitude.peak >= minimumPeakForNormalization else { return nil }
        
        let currentRMS = max(amplitude.rms, 1e-7)
        var desiredGain = targetRMS / currentRMS
        desiredGain = min(desiredGain, maximumGain)
        
        if amplitude.peak > 0 {
            let peakLimitedGain = maximumOutputPeak / amplitude.peak
            desiredGain = min(desiredGain, peakLimitedGain)
        }
        
        if desiredGain <= 1.05 {
            return nil
        }
        
        var normalized = samples
        var accumulatedSquare: Float = 0
        var peak: Float = 0
        
        for index in 0..<normalized.count {
            let scaled = max(min(normalized[index] * desiredGain, 1.0), -1.0)
            normalized[index] = scaled
            let absolute = abs(scaled)
            peak = max(peak, absolute)
            accumulatedSquare += absolute * absolute
        }
        
        let divisor = Float(max(normalized.count, 1))
        let rms = sqrt(accumulatedSquare / divisor)
        
        return Result(
            samples: normalized,
            appliedGain: desiredGain,
            beforeRMS: amplitude.rms,
            beforePeak: amplitude.peak,
            afterRMS: rms,
            afterPeak: peak
        )
    }
}
