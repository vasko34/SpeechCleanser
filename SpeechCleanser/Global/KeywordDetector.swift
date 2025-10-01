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
        let expectedLevel: Float
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
    
    private struct CandidateState {
        let keywordID: UUID
        let name: String
        var streak: Int
        var bestScore: Float
        var totalLevel: Float
        var frameCount: Int
        var featureCount: Int
        var scale: Float
        var threshold: Float
        var expectedLevel: Float
        var hasStrongFrame: Bool
        var framesSinceUpdate: Int
        var nearMissCount: Int
    }
    
    private let acceptanceMargin: Float = 0.06
    private let maxInactiveFrames = 3
    
    private var lock = os_unfair_lock_s()
    private var models: [VariationModel] = []
    private var sampleBuffer: [Float] = []
    private var processedOffset = 0
    private var featureBuffer: [Float] = []
    private var candidateBuffer: [Float] = []
    private var cooldowns: [UUID: Int] = [:]
    private var candidateStates: [UUID: CandidateState] = [:]
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
            if !candidateStates.isEmpty {
                candidateStates.removeAll(keepingCapacity: true)
            }
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
        
        var nearMiss: (keywordName: String, score: Float, threshold: Float, scale: Float)?
        var bestMatches: [UUID: (name: String, score: Float, mean: Float, featureCount: Int, scale: Float, threshold: Float, passesThreshold: Bool, expectedLevel: Float)] = [:]
        
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
            
            let acceptanceThreshold = max(model.matchThreshold - acceptanceMargin, 0.70)
            if score >= acceptanceThreshold {
                let passesThreshold = score >= model.matchThreshold
                if let existing = bestMatches[model.keywordID] {
                    if score > existing.score {
                        bestMatches[model.keywordID] = (
                            model.keywordName,
                            score,
                            mean,
                            model.featureCount,
                            model.scale,
                            model.matchThreshold,
                            passesThreshold,
                            model.expectedLevel
                        )
                    }
                } else {
                    bestMatches[model.keywordID] = (
                        model.keywordName,
                        score,
                        mean,
                        model.featureCount,
                        model.scale,
                        model.matchThreshold,
                        passesThreshold,
                        model.expectedLevel
                    )
                }
                
                if !passesThreshold {
                    if nearMiss == nil || score > nearMiss!.score {
                        nearMiss = (model.keywordName, score, model.matchThreshold, model.scale)
                    }
                }
            } else if score >= model.matchThreshold - 0.02 {
                if nearMiss == nil || score > nearMiss!.score {
                    nearMiss = (model.keywordName, score, model.matchThreshold, model.scale)
                }
            }
        }
        if bestMatches.isEmpty, let info = nearMiss {
            let scoreString = String(format: "%.3f", Double(info.score))
            let thresholdString = String(format: "%.3f", Double(info.threshold))
            let scaleString = String(format: "%.2fx", Double(info.scale))
            print("[KeywordDetector] appendFeatureLocked: Near miss for keyword \(info.keywordName) score=\(scoreString) threshold=\(thresholdString) scale=\(scaleString)")
        }
        guard !bestMatches.isEmpty else {
            if !candidateStates.isEmpty {
                var retained: [UUID: CandidateState] = [:]
                for (identifier, var state) in candidateStates {
                    state.framesSinceUpdate += 1
                    state.streak = max(state.streak - 1, 0)
                    if state.framesSinceUpdate <= maxInactiveFrames {
                        retained[identifier] = state
                    } else {
                        let scoreString = String(format: "%.3f", Double(state.bestScore))
                        print("[KeywordDetector] appendFeatureLocked: Candidate expired for keyword \(state.name) after \(state.framesSinceUpdate) silent frames bestScore=\(scoreString)")
                    }
                }
                candidateStates = retained
            }
            return nil
        }
        
        let orderedMatches = bestMatches.sorted { $0.value.score > $1.value.score }
        var updatedStates: [UUID: CandidateState] = [:]
        var detectionFromStates: DetectionResult?
        
        for (keywordID, context) in orderedMatches {
            let match = context
            let previous = candidateStates[keywordID]
            var didReset = false
            var state = previous ?? CandidateState(
                keywordID: keywordID,
                name: match.name,
                streak: 0,
                bestScore: 0,
                totalLevel: 0,
                frameCount: 0,
                featureCount: match.featureCount,
                scale: match.scale,
                threshold: match.threshold,
                expectedLevel: match.expectedLevel,
                hasStrongFrame: false,
                framesSinceUpdate: 0,
                nearMissCount: 0
            )
            
            if var previousState = previous {
                let gap = previousState.framesSinceUpdate
                if gap > 0 {
                    if gap > maxInactiveFrames {
                        previousState.streak = 0
                        previousState.bestScore = 0
                        previousState.totalLevel = 0
                        previousState.frameCount = 0
                        previousState.hasStrongFrame = false
                        previousState.nearMissCount = 0
                        didReset = true
                    } else {
                        previousState.streak = max(previousState.streak - gap, 0)
                        previousState.nearMissCount = max(previousState.nearMissCount - gap, 0)
                        if previousState.bestScore < previousState.threshold && previousState.nearMissCount == 0 {
                            previousState.hasStrongFrame = false
                        }
                    }
                }
                previousState.framesSinceUpdate = 0
                state = previousState
            }
            
            state.streak += 1
            state.totalLevel += match.mean
            state.frameCount += 1
            
            if match.score > state.bestScore {
                state.bestScore = match.score
                state.featureCount = match.featureCount
                state.scale = match.scale
                state.threshold = match.threshold
                state.expectedLevel = match.expectedLevel
            }
            
            if match.passesThreshold {
                state.hasStrongFrame = true
            }
            
            let requiredStreak = state.featureCount <= 14 ? 2 : 3
            if match.passesThreshold {
                state.hasStrongFrame = true
                state.nearMissCount = max(state.nearMissCount, 1)
            } else if match.score >= state.threshold - acceptanceMargin * 0.5 {
                state.nearMissCount += 1
                if state.nearMissCount >= requiredStreak + 1 {
                    state.hasStrongFrame = true
                }
            } else {
                state.nearMissCount = max(state.nearMissCount - 1, 0)
                if state.nearMissCount == 0 && state.bestScore < state.threshold {
                    state.hasStrongFrame = false
                }
            }
            
            let startedNew = previous == nil || didReset
            if startedNew {
                let scoreString = String(format: "%.3f", Double(match.score))
                let thresholdString = String(format: "%.3f", Double(match.threshold))
                let scaleString = String(format: "%.2fx", Double(match.scale))
                let levelString = String(format: "%.5f", Double(match.mean))
                print("[KeywordDetector] appendFeatureLocked: Candidate started for keyword \(match.name) score=\(scoreString) threshold=\(thresholdString) level=\(levelString) scale=\(scaleString)")
            } else if match.score > (previous?.bestScore ?? 0) {
                let scoreString = String(format: "%.3f", Double(match.score))
                let thresholdString = String(format: "%.3f", Double(match.threshold))
                let scaleString = String(format: "%.2fx", Double(match.scale))
                let levelString = String(format: "%.5f", Double(match.mean))
                print("[KeywordDetector] appendFeatureLocked: Candidate improved for keyword \(match.name) score=\(scoreString) threshold=\(thresholdString) level=\(levelString) scale=\(scaleString) streak=\(state.streak)")
            }
            
            let averageLevel = state.totalLevel / Float(max(state.frameCount, 1))
            let expectedLevel = max(state.expectedLevel, 0.0001)
            let levelRatio = averageLevel / expectedLevel
            let levelWithinBounds: Bool

            if expectedLevel < 0.0025 {
                let minimumRatio = max(0.22, 0.38 - expectedLevel * 22)
                let maximumRatio: Float = 3.4
                let tolerance = max(0.0048, expectedLevel * 1.1)
                levelWithinBounds = (levelRatio >= minimumRatio && levelRatio <= maximumRatio) || abs(averageLevel - expectedLevel) <= tolerance
            } else if expectedLevel < 0.0065 {
                let minimumRatio = max(0.26, 0.46 - expectedLevel * 15)
                let maximumRatio: Float = 3.1
                let tolerance = max(0.0055, expectedLevel * 0.95)
                levelWithinBounds = (levelRatio >= minimumRatio && levelRatio <= maximumRatio) || abs(averageLevel - expectedLevel) <= tolerance
            } else {
                let minimumRatio = max(0.33, 0.52 - expectedLevel * 11)
                let maximumRatio: Float = 2.45
                let tolerance = max(0.006, expectedLevel * 0.85)
                levelWithinBounds = (levelRatio >= minimumRatio && levelRatio <= maximumRatio) || abs(averageLevel - expectedLevel) <= tolerance
            }
            
            if state.bestScore >= state.threshold - acceptanceMargin * 0.3 {
                state.hasStrongFrame = true
            }

            let highConfidence = state.hasStrongFrame && max(state.bestScore, match.score) >= state.threshold + 0.14
            let competitor = orderedMatches.first { $0.key != keywordID }

            let hasRequiredFrames = state.frameCount >= requiredStreak

            if state.hasStrongFrame && levelWithinBounds && ((state.streak >= requiredStreak && hasRequiredFrames) || highConfidence) {
                let finalScore = max(state.bestScore, match.score)
                
                if let competitor {
                    let competitorScore = competitor.value.score
                    let competitorThreshold = competitor.value.threshold
                    let difference = finalScore - competitorScore
                    if competitorScore >= competitorThreshold - acceptanceMargin * 0.5 && difference < 0.035 {
                        let scoreString = String(format: "%.3f", Double(finalScore))
                        let competitorString = String(format: "%.3f", Double(competitorScore))
                        let differenceString = String(format: "%.3f", Double(difference))
                        print("[KeywordDetector] appendFeatureLocked: Candidate suppressed for keyword \(state.name) due to competitor \(competitor.value.name) score=\(scoreString) competitorScore=\(competitorString) diff=\(differenceString)")
                        state.framesSinceUpdate = 1
                        state.streak = max(state.streak - 1, 0)
                        state.nearMissCount = max(state.nearMissCount - 1, 0)
                        if state.nearMissCount == 0 && state.bestScore < state.threshold {
                            state.hasStrongFrame = false
                        }
                        updatedStates[keywordID] = state
                        continue
                    }
                }
                
                let cooldownFrames = max(state.featureCount, featuresPerSecond * 2)
                cooldowns[keywordID] = cooldownFrames
                globalCooldown = max(globalCooldown, featuresPerSecond)
                let scoreString = String(format: "%.3f", Double(finalScore))
                let levelString = String(format: "%.5f", Double(averageLevel))
                let expectedString = String(format: "%.5f", Double(expectedLevel))
                let ratioString = String(format: "%.2fx", Double(levelRatio))
                let scaleString = String(format: "%.2fx", Double(state.scale))
                print("[KeywordDetector] appendFeatureLocked: Detected keyword \(state.name) score=\(scoreString) level=\(levelString) expected=\(expectedString) ratio=\(ratioString) scale=\(scaleString)")
                
                detectionFromStates = DetectionResult(
                    keywordID: keywordID,
                    name: state.name,
                    score: finalScore,
                    averageLevel: averageLevel,
                    featureCount: state.featureCount,
                    scale: state.scale
                )
                
                candidateStates.removeAll(keepingCapacity: true)
                break
            }
            
            if state.hasStrongFrame {
                if hasRequiredFrames && state.streak == requiredStreak - 1 {
                    let scoreString = String(format: "%.3f", Double(state.bestScore))
                    print("[KeywordDetector] appendFeatureLocked: Candidate pending streak for keyword \(state.name) score=\(scoreString) streak=\(state.streak) required=\(requiredStreak)")
                } else if hasRequiredFrames && state.streak >= requiredStreak && !levelWithinBounds {
                    let ratioString = String(format: "%.2fx", Double(levelRatio))
                    let expectedString = String(format: "%.5f", Double(expectedLevel))
                    let levelString = String(format: "%.5f", Double(averageLevel))
                    print("[KeywordDetector] appendFeatureLocked: Candidate blocked by level for keyword \(state.name) level=\(levelString) expected=\(expectedString) ratio=\(ratioString)")
                } else if !hasRequiredFrames {
                    let scoreString = String(format: "%.3f", Double(state.bestScore))
                    print("[KeywordDetector] appendFeatureLocked: Candidate building streak for keyword \(state.name) score=\(scoreString) streak=\(state.streak) required=\(requiredStreak)")
                }
            }
            updatedStates[keywordID] = state
        }
        
        if let detectionFromStates {
            return detectionFromStates
        }
        
        if !candidateStates.isEmpty {
            for (identifier, var state) in candidateStates where updatedStates[identifier] == nil {
                state.framesSinceUpdate += 1
                state.streak = max(state.streak - 1, 0)
                if state.framesSinceUpdate <= maxInactiveFrames {
                    updatedStates[identifier] = state
                } else {
                    let scoreString = String(format: "%.3f", Double(state.bestScore))
                    print("[KeywordDetector] appendFeatureLocked: Candidate expired for keyword \(state.name) after \(state.framesSinceUpdate) silent frames bestScore=\(scoreString)")
                }
            }
        }
        
        candidateStates = updatedStates
        return nil
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
        if count < 10 { return 0.86 }
        if count < 20 { return 0.83 }
        if count < 35 { return 0.8 }
        if count < 50 { return 0.78 }
        return 0.76
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
        let deviation = abs(scale - 1)
        if deviation > 0.01 {
            let penalty = min(0.03 + deviation * 0.08, 0.14)
            threshold += penalty
        }
        return min(max(threshold, 0.71), 0.96)
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
                let minimum = max(max(expected * 0.45, expected - max(expected * 0.6, 0.004)), 0.00008)
                let dynamicUpper = max(expected * 2.4, expected + max(expected * 1.3, 0.005))
                let maximum = max(dynamicUpper, minimum * 1.6)

                let baseModel = VariationModel(
                    keywordID: keyword.id,
                    keywordName: keyword.name,
                    fingerprint: normalized,
                    featureCount: featureCount,
                    expectedLevel: expected,
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
                        expectedLevel: expected,
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
