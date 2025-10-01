//
//  KeywordDetector.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import Accelerate
import os

final class KeywordDetector {
    private struct VariationModel {
        let keywordID: UUID
        let keywordName: String
        let fingerprint: [Float]
        let featureCount: Int
        let minimumLevel: Float
        let maximumLevel: Float
        let matchThreshold: Float
    }
    
    private struct DetectionResult {
        let keywordID: UUID
        let name: String
        let score: Float
        let averageLevel: Float
    }
    
    private var lock = os_unfair_lock_s()
    private var models: [VariationModel] = []
    private var sampleBuffer: [Float] = []
    private var processedOffset = 0
    private var featureBuffer: [Float] = []
    private var candidateBuffer: [Float] = []
    private var cooldowns: [UUID: Int] = [:]
    private var globalCooldown = 0
    private var windowSamples = max(1, Int(AudioFingerprint.defaultSampleRate * AudioFingerprint.defaultWindowDuration))
    private var hopSamples = max(1, Int(AudioFingerprint.defaultSampleRate * AudioFingerprint.defaultHopDuration))
    private var featuresPerSecond = max(1, Int(round(1.0 / AudioFingerprint.defaultHopDuration)))
    private var maxFeatureHistory = 0
    
    var onDetection: ((UUID, String) -> Void)?
    
    private func appendFeatureLocked(rms: Float) -> DetectionResult? {
        featureBuffer.append(rms)
        if featureBuffer.count > maxFeatureHistory {
            let overflow = featureBuffer.count - maxFeatureHistory
            featureBuffer.removeFirst(overflow)
        }
        
        if globalCooldown > 0 {
            globalCooldown -= 1
        }
        
        if !cooldowns.isEmpty {
            var updated: [UUID: Int] = [:]
            for (key, value) in cooldowns {
                let newValue = max(value - 1, 0)
                if newValue > 0 {
                    updated[key] = newValue
                }
            }
            cooldowns = updated
        }
        guard globalCooldown == 0 else { return nil }
        
        var bestMatch: DetectionResult?
        var bestScore: Float = 0
        for model in models {
            if cooldowns[model.keywordID] != nil { continue }
            if featureBuffer.count < model.featureCount { continue }
            
            let startIndex = featureBuffer.count - model.featureCount
            candidateBuffer.removeAll(keepingCapacity: true)
            candidateBuffer.append(contentsOf: featureBuffer[startIndex..<featureBuffer.count])
            
            var mean: Float = 0
            candidateBuffer.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                vDSP_meanv(base, 1, &mean, vDSP_Length(model.featureCount))
            }
            
            if mean < model.minimumLevel || mean > model.maximumLevel {
                continue
            }
            
            var magnitude: Float = 0
            candidateBuffer.withUnsafeMutableBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                var negativeMean = -mean
                vDSP_vsadd(base, 1, &negativeMean, base, 1, vDSP_Length(model.featureCount))
                vDSP_dotpr(base, 1, base, 1, &magnitude, vDSP_Length(model.featureCount))
                let norm = sqrtf(magnitude)
                
                if norm > 1e-5 {
                    var inverse = 1 / norm
                    vDSP_vsmul(base, 1, &inverse, base, 1, vDSP_Length(model.featureCount))
                } else {
                    magnitude = 0
                }
            }
            if magnitude <= 0 { continue }
            
            var score: Float = 0
            candidateBuffer.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                vDSP_dotpr(base, 1, model.fingerprint, 1, &score, vDSP_Length(model.featureCount))
            }
            
            if score >= model.matchThreshold {
                if bestMatch == nil || score > bestScore {
                    bestMatch = DetectionResult(keywordID: model.keywordID, name: model.keywordName, score: score, averageLevel: mean)
                    bestScore = score
                }
            }
        }
        guard let detection = bestMatch else { return nil }
        
        if let model = models.first(where: { $0.keywordID == detection.keywordID }) {
            let cooldownFrames = max(model.featureCount, featuresPerSecond * 2)
            cooldowns[model.keywordID] = cooldownFrames
            globalCooldown = max(globalCooldown, featuresPerSecond)
            let scoreString = String(format: "%.3f", Double(detection.score))
            let levelString = String(format: "%.5f", Double(detection.averageLevel))
            print("[KeywordDetector] appendFeatureLocked: Detected keyword \(model.keywordName) score=\(scoreString) level=\(levelString)")
        } else {
            print("[KeywordDetector][ERROR] appendFeatureLocked: Missing model for detection keywordID \(detection.keywordID.uuidString)")
        }
        
        return detection
    }
    
    private func normalizeVector(_ vector: inout [Float]) -> Bool {
        guard !vector.isEmpty else { return false }
        
        var mean: Float = 0
        vector.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            vDSP_meanv(base, 1, &mean, vDSP_Length(vector.count))
        }
        
        var magnitude: Float = 0
        vector.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            
            var negativeMean = -mean
            vDSP_vsadd(base, 1, &negativeMean, base, 1, vDSP_Length(vector.count))
            vDSP_dotpr(base, 1, base, 1, &magnitude, vDSP_Length(vector.count))
            let norm = sqrtf(magnitude)
            
            if norm > 1e-5 {
                var inverse = 1 / norm
                vDSP_vsmul(base, 1, &inverse, base, 1, vDSP_Length(vector.count))
            }
        }
        
        if magnitude <= 1e-5 {
            return false
        }
        
        return true
    }
    
    private func thresholdForFeatureCount(_ count: Int) -> Float {
        if count < 10 { return 0.92 }
        if count < 20 { return 0.88 }
        if count < 35 { return 0.85 }
        return 0.82
    }
    
    private func withLock(_ block: () -> Void) {
        os_unfair_lock_lock(&lock)
        block()
        os_unfair_lock_unlock(&lock)
    }
    
    func configure(keywords: [Keyword], sampleRate: Double) {
        var newModels: [VariationModel] = []
        var longest = 0
        var keywordNames: [String] = []
        var derivedFeaturesPerSecond = featuresPerSecond
        var didAssignHopConfiguration = false
        
        for keyword in keywords where keyword.isEnabled {
            var enabledVariationCount = 0
            for variation in keyword.variations where !variation.fingerprint.isEmpty {
                var normalized = variation.fingerprint
                if !normalizeVector(&normalized) {
                    print("[KeywordDetector][ERROR] configure: Skipping variation \(variation.id.uuidString) for keyword \(keyword.name) due to invalid fingerprint")
                    continue
                }
                
                let featureCount = normalized.count
                let expected = max(variation.rms, 0.0001)
                let minimum = max(expected * 0.35, 0.00005)
                let maximum = max(expected * 2.8, minimum * 2)
                let threshold = thresholdForFeatureCount(featureCount)
                
                let model = VariationModel(
                    keywordID: keyword.id,
                    keywordName: keyword.name,
                    fingerprint: normalized,
                    featureCount: featureCount,
                    minimumLevel: minimum,
                    maximumLevel: maximum,
                    matchThreshold: threshold
                )
                
                newModels.append(model)
                enabledVariationCount += 1
                longest = max(longest, featureCount)
                
                if !didAssignHopConfiguration {
                    let hopDuration = Double(max(variation.analysisHopSize, 1)) / max(variation.analysisSampleRate, 1)
                    let computedFeaturesPerSecond = max(1, Int(round(1.0 / hopDuration)))
                    derivedFeaturesPerSecond = computedFeaturesPerSecond
                    didAssignHopConfiguration = true
                }
            }
            
            if enabledVariationCount > 0 {
                keywordNames.append("\(keyword.name) (\(enabledVariationCount))")
            }
        }
        
        let resolvedWindowSamples = max(1, Int(sampleRate * AudioFingerprint.defaultWindowDuration))
        let resolvedHopSamples = max(1, Int(sampleRate * AudioFingerprint.defaultHopDuration))
        let resolvedFeaturesPerSecond = max(derivedFeaturesPerSecond, 1)
        let history = longest + resolvedFeaturesPerSecond * 3
        
        withLock {
            models = newModels
            sampleBuffer.removeAll(keepingCapacity: true)
            featureBuffer.removeAll(keepingCapacity: true)
            candidateBuffer.removeAll(keepingCapacity: true)
            cooldowns.removeAll(keepingCapacity: true)
            globalCooldown = 0
            processedOffset = 0
            windowSamples = resolvedWindowSamples
            hopSamples = resolvedHopSamples
            maxFeatureHistory = max(history, longest)
            featuresPerSecond = resolvedFeaturesPerSecond
        }
        
        let keywordSummary = keywordNames.joined(separator: ", ")
        let summaryText = keywordSummary.isEmpty ? "none" : keywordSummary
        print("[KeywordDetector] configure: Loaded \(newModels.count) variations across \(keywordNames.count) keywords at rate \(String(format: "%.0f", sampleRate))Hz -> [\(summaryText)]")
    }
    
    func process(samples: [Float], level _: Float) {
        guard !samples.isEmpty else { return }
        
        var detection: DetectionResult?
        withLock {
            guard !models.isEmpty else { return }
            
            sampleBuffer.append(contentsOf: samples)
            let totalSamples = sampleBuffer.count
            while processedOffset + windowSamples <= totalSamples {
                let start = processedOffset
                var power: Float = 0
                sampleBuffer.withUnsafeBufferPointer { pointer in
                    guard let base = pointer.baseAddress else { return }
                    let segment = base.advanced(by: start)
                    vDSP_measqv(segment, 1, &power, vDSP_Length(windowSamples))
                }
                
                let rms = sqrtf(power)
                if detection == nil {
                    detection = appendFeatureLocked(rms: rms)
                } else {
                    _ = appendFeatureLocked(rms: rms)
                }
                
                processedOffset += hopSamples
            }
            
            if processedOffset > 0 {
                if processedOffset >= sampleBuffer.count {
                    sampleBuffer.removeAll(keepingCapacity: true)
                    processedOffset = 0
                } else if processedOffset > windowSamples * 3 {
                    sampleBuffer.removeFirst(processedOffset)
                    processedOffset = 0
                }
            }
        }
        guard let detection else { return }
        
        DispatchQueue.main.async { [weak self] in
            self?.onDetection?(detection.keywordID, detection.name)
        }
    }
}
