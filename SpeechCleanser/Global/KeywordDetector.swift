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
        let scale: Float
    }
    
    private struct DetectionResult {
        let keywordID: UUID
        let name: String
        let score: Float
        let averageLevel: Float
        let featureCount: Int
        let scale: Float
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
        var nearMiss: (keywordName: String, score: Float, threshold: Float, scale: Float)?
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
                    bestMatch = DetectionResult(keywordID: model.keywordID, name: model.keywordName, score: score, averageLevel: mean, featureCount: model.featureCount, scale: model.scale)
                    bestScore = score
                }
            } else if score >= model.matchThreshold - 0.05 {
                if nearMiss == nil || score > nearMiss!.score {
                    nearMiss = (model.keywordName, score, model.matchThreshold, model.scale)
                }
            }
        }
        if bestMatch == nil, let info = nearMiss {
            let scoreString = String(format: "%.3f", Double(info.score))
            let thresholdString = String(format: "%.3f", Double(info.threshold))
            let scaleString = String(format: "%.2fx", Double(info.scale))
            print("[KeywordDetector] appendFeatureLocked: Near miss for keyword \(info.keywordName) score=\(scoreString) threshold=\(thresholdString) scale=\(scaleString)")
        }
        guard let detection = bestMatch else { return nil }
        
        let cooldownFrames = max(detection.featureCount, featuresPerSecond * 2)
        cooldowns[detection.keywordID] = cooldownFrames
        globalCooldown = max(globalCooldown, featuresPerSecond)
        let scoreString = String(format: "%.3f", Double(detection.score))
        let levelString = String(format: "%.5f", Double(detection.averageLevel))
        let scaleString = String(format: "%.2fx", Double(detection.scale))
        print("[KeywordDetector] appendFeatureLocked: Detected keyword \(detection.name) score=\(scoreString) level=\(levelString) scale=\(scaleString)")
        
        return detection
    }
    
    private func normalizeVector(_ vector: inout [Float]) -> Bool {
        guard !vector.isEmpty else { return false }
        
        let count = vector.count
        var mean: Float = 0
        vector.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            vDSP_meanv(base, 1, &mean, vDSP_Length(count))
        }
        
        var magnitude: Float = 0
        vector.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            
            var negativeMean = -mean
            vDSP_vsadd(base, 1, &negativeMean, base, 1, vDSP_Length(count))
            vDSP_dotpr(base, 1, base, 1, &magnitude, vDSP_Length(count))
            let norm = sqrtf(magnitude)
            
            if norm > 1e-5 {
                var inverse = 1 / norm
                vDSP_vsmul(base, 1, &inverse, base, 1, vDSP_Length(count))
            }
        }
        
        if magnitude <= 1e-5 {
            return false
        }
        
        return true
    }
    
    private func thresholdForFeatureCount(_ count: Int) -> Float {
        if count < 10 { return 0.90 }
        if count < 20 { return 0.86 }
        if count < 35 { return 0.83 }
        if count < 50 { return 0.80 }
        return 0.78
    }
    
    private func withLock(_ block: () -> Void) {
        os_unfair_lock_lock(&lock)
        block()
        os_unfair_lock_unlock(&lock)
    }
    
    private func resampleFingerprint(_ fingerprint: [Float], targetCount: Int) -> [Float] {
        guard targetCount > 1, fingerprint.count > 1 else { return fingerprint }
        
        var result = [Float](repeating: 0, count: targetCount)
        let scale = Float(fingerprint.count - 1) / Float(targetCount - 1)
        
        for index in 0..<targetCount {
            let position = Float(index) * scale
            let lower = Int(position)
            let upper = min(lower + 1, fingerprint.count - 1)
            let fraction = position - Float(lower)
            let lowerValue = fingerprint[lower]
            let upperValue = fingerprint[upper]
            result[index] = lowerValue + (upperValue - lowerValue) * fraction
        }
        
        return result
    }
    
    private func scaledThreshold(for count: Int, scale: Float) -> Float {
        var threshold = thresholdForFeatureCount(count)
        if abs(scale - 1) > 0.01 {
            threshold -= 0.03
        }
        return max(threshold, 0.72)
    }
    
    private func scaleVariants(for featureCount: Int) -> [Float] {
        if featureCount >= 45 {
            return [0.82, 0.9, 1.1, 1.22]
        }
        
        if featureCount >= 25 {
            return [0.86, 0.94, 1.08, 1.18]
        }
        
        if featureCount >= 12 {
            return [0.88, 1.12]
        }
        
        return [0.94, 1.06]
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
                let minimum = max(expected * 0.28, 0.00005)
                let maximum = max(expected * 3.2, minimum * 2.2)

                let baseModel = VariationModel(
                    keywordID: keyword.id,
                    keywordName: keyword.name,
                    fingerprint: normalized,
                    featureCount: featureCount,
                    minimumLevel: minimum,
                    maximumLevel: maximum,
                    matchThreshold: thresholdForFeatureCount(featureCount),
                    scale: 1
                )
                
                newModels.append(baseModel)
                longest = max(longest, featureCount)
                
                let variants = scaleVariants(for: featureCount)
                for scale in variants {
                    let scaledCount = max(6, Int(round(Float(featureCount) * scale)))
                    if scaledCount == featureCount { continue }
                    var scaledFingerprint = resampleFingerprint(normalized, targetCount: scaledCount)
                    if !normalizeVector(&scaledFingerprint) { continue }
                    
                    let scaledModel = VariationModel(
                        keywordID: keyword.id,
                        keywordName: keyword.name,
                        fingerprint: scaledFingerprint,
                        featureCount: scaledCount,
                        minimumLevel: minimum,
                        maximumLevel: maximum,
                        matchThreshold: scaledThreshold(for: scaledCount, scale: scale),
                        scale: scale
                    )
                    
                    newModels.append(scaledModel)
                    longest = max(longest, scaledCount)
                }
                
                enabledVariationCount += 1
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
