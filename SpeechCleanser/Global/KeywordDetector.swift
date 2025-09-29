//
//  KeywordDetector.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import Foundation
import Accelerate

final class KeywordDetector {
    private struct CachedVariation {
        let sampleCount: Int
        let duration: TimeInterval
        let fingerprint: [Float]
    }
    
    private struct CachedKeyword {
        let keywordID: UUID
        let keywordName: String
        let representative: [Float]
        let variations: [CachedVariation]
    }
    
    private struct FingerprintCacheKey: Hashable {
        let offset: Int
        let length: Int
    }
    
    private struct DetectionCandidate {
        let keyword: CachedKeyword
        let variationSimilarity: Float
        let aggregatedSimilarity: Float
    }
    
    private let queue = DispatchQueue(label: "KeywordDetector.queue")
    private let searchPadding: TimeInterval = 0.35
    private let primaryThreshold: Float = 0.58
    private let aggregateThreshold: Float = 0.50
    private let similarityMargin: Float = 0.05
    private let silenceThreshold: Float = 0.006
    private let noiseLearningRate: Float = 0.04
    private let signalBoost: Float = 2.3
    private let minActiveLevel: Float = 0.015
    private let maxNoiseFloor: Float = 0.05
    private let keywordRepeatInterval: TimeInterval = 6.0
    private let windowStrideDivisor = 6
    
    private var keywords: [CachedKeyword] = []
    private var lastDetection: Date?
    private var debounceInterval: TimeInterval = 3.0
    private var sampleRate: Double = 44_100
    private var circularBuffer: [Float] = []
    private var maxSampleCount: Int = 0
    private var noiseFloor: Float = 0
    private var lastKeywordID: UUID?
    
    var onDetection: ((UUID, String) -> Void)?
    
    private func appendSamples(_ samples: [Float]) {
        circularBuffer.append(contentsOf: samples)
        if circularBuffer.count > maxSampleCount {
            circularBuffer.removeFirst(circularBuffer.count - maxSampleCount)
        }
    }
    
    private func canTriggerDetection(for keywordID: UUID) -> Bool {
        if let last = lastDetection, Date().timeIntervalSince(last) < debounceInterval {
            return false
        }
        
        if let previousID = lastKeywordID,
           previousID == keywordID,
           let last = lastDetection,
           Date().timeIntervalSince(last) < keywordRepeatInterval {
            return false
        }
        
        return true
    }
    
    private func updateNoise(with level: Float) {
        let clamped = max(0, min(level, 1))
        
        if noiseFloor == 0 {
            noiseFloor = clamped
            return
        }
        
        let alpha: Float = clamped > noiseFloor ? noiseLearningRate * 0.5 : noiseLearningRate
        let updated = (1 - alpha) * noiseFloor + alpha * clamped
        noiseFloor = min(max(updated, 0.0005), maxNoiseFloor)
    }
    
    private func normalize(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        
        var mean: Float = 0
        vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))
        
        var centered = [Float](repeating: 0, count: values.count)
        var negativeMean = -mean
        vDSP_vsadd(values, 1, &negativeMean, &centered, 1, vDSP_Length(values.count))
        
        var variance: Float = 0
        vDSP_measqv(centered, 1, &variance, vDSP_Length(values.count))
        let std = sqrtf(variance)
        
        guard std > .ulpOfOne else { return centered }
        
        var normalized = [Float](repeating: 0, count: values.count)
        var divisor = std
        vDSP_vsdiv(centered, 1, &divisor, &normalized, 1, vDSP_Length(values.count))
        return normalized
    }
    
    private func representativeFingerprint(from fingerprints: [[Float]]) -> [Float] {
        guard let first = fingerprints.first, !first.isEmpty else { return [] }
        
        var accumulator = [Float](repeating: 0, count: first.count)
        var count: Float = 0
        
        for fingerprint in fingerprints where fingerprint.count == first.count {
            vDSP_vadd(accumulator, 1, fingerprint, 1, &accumulator, 1, vDSP_Length(first.count))
            count += 1
        }
        
        guard count > 0 else { return [] }
        
        var divisor = count
        vDSP_vsdiv(accumulator, 1, &divisor, &accumulator, 1, vDSP_Length(first.count))
        return normalize(accumulator)
    }
    
    private func fingerprint(for buffer: [Float], offset: Int, length: Int, cache: inout [FingerprintCacheKey: [Float]]) -> [Float] {
        let key = FingerprintCacheKey(offset: offset, length: length)
        if let cached = cache[key] {
            return cached
        }
        
        let window = Array(buffer[offset..<(offset + length)])
        let fingerprint = AudioFingerprint.generateFingerprint(from: window)
        cache[key] = fingerprint
        return fingerprint
    }
    
    func configure(keywords: [Keyword], sampleRate: Double) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.sampleRate = sampleRate
            let enabledKeywords = keywords.filter { $0.isEnabled }
            
            self.keywords = enabledKeywords.compactMap { keyword -> CachedKeyword? in
                let cachedVariations = keyword.variations.compactMap { variation -> CachedVariation? in
                    guard !variation.fingerprint.isEmpty else { return nil }
                    let sampleCount = max(1, Int(variation.duration * sampleRate))
                    return CachedVariation(sampleCount: sampleCount, duration: variation.duration, fingerprint: variation.fingerprint)
                }
                
                guard !cachedVariations.isEmpty else { return nil }
                
                let representative = self.representativeFingerprint(from: cachedVariations.map { $0.fingerprint })
                return CachedKeyword(
                    keywordID: keyword.id,
                    keywordName: keyword.name,
                    representative: representative,
                    variations: cachedVariations
                )
            }
            
            let longestDuration = self.keywords.flatMap { $0.variations.map { $0.duration } }.max() ?? 0
            let windowDuration = max(longestDuration + self.searchPadding, 0.5)
            self.maxSampleCount = Int(windowDuration * sampleRate) + 1_024
            if self.maxSampleCount <= 0 { self.maxSampleCount = 1_024 }
            self.circularBuffer.removeAll(keepingCapacity: false)
            
            self.noiseFloor = 0
            self.lastKeywordID = nil
            
            let variationTotal = self.keywords.reduce(0) { $0 + $1.variations.count }
            print("[KeywordDetector] configure: Cached \(variationTotal) variations at sampleRate \(sampleRate)")
        }
    }
    
    func process(samples: [Float], level: Float) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.keywords.isEmpty else { return }
            
            let clampedLevel = max(0, min(level, 1))
            self.updateNoise(with: clampedLevel)
            let dynamicThreshold = max(self.minActiveLevel, max(self.silenceThreshold, self.noiseFloor * self.signalBoost))
            self.appendSamples(samples)
            guard clampedLevel >= dynamicThreshold else { return }
            
            let availableCount = self.circularBuffer.count
            let searchCount = min(availableCount, self.maxSampleCount)
            guard searchCount > 0 else { return }
            
            let startIndex = availableCount - searchCount
            let searchBuffer = Array(self.circularBuffer[startIndex..<availableCount])
            
            var cache: [FingerprintCacheKey: [Float]] = [:]
            var bestScore: Float = 0
            var runnerUpScore: Float = 0
            var bestCandidate: DetectionCandidate?
            
            for keyword in self.keywords {
                var keywordBestScore: Float = 0
                var keywordBestOffset = 0
                var keywordBestLength = 0
                
                for variation in keyword.variations {
                    let sampleCount = variation.sampleCount
                    guard sampleCount > 0, searchBuffer.count >= sampleCount else { continue }
                    
                    let strideLength = max(1, sampleCount / self.windowStrideDivisor)
                    var offset = 0
                    
                    while offset + sampleCount <= searchBuffer.count {
                        let fingerprint = self.fingerprint(for: searchBuffer, offset: offset, length: sampleCount, cache: &cache)
                        guard fingerprint.count == variation.fingerprint.count else {
                            offset += strideLength
                            continue
                        }
                        
                        let similarity = AudioFingerprint.similarity(between: fingerprint, and: variation.fingerprint)
                        if similarity > keywordBestScore {
                            keywordBestScore = similarity
                            keywordBestOffset = offset
                            keywordBestLength = sampleCount
                        }
                        
                        offset += strideLength
                    }
                }
                
                guard keywordBestScore > 0, keywordBestLength > 0 else { continue }
                
                let aggregatedSimilarity: Float
                if keyword.representative.isEmpty {
                    aggregatedSimilarity = keywordBestScore
                } else {
                    let fingerprint = self.fingerprint(for: searchBuffer, offset: keywordBestOffset, length: keywordBestLength, cache: &cache)
                    aggregatedSimilarity = AudioFingerprint.similarity(between: fingerprint, and: keyword.representative)
                }
                
                let effectiveScore = min(keywordBestScore, aggregatedSimilarity)
                if effectiveScore > bestScore {
                    runnerUpScore = bestScore
                    bestScore = effectiveScore
                    bestCandidate = DetectionCandidate(keyword: keyword, variationSimilarity: keywordBestScore, aggregatedSimilarity: aggregatedSimilarity)
                } else if effectiveScore > runnerUpScore {
                    runnerUpScore = effectiveScore
                }
            }
            guard let candidate = bestCandidate else { return }
            guard candidate.variationSimilarity >= self.primaryThreshold else { return }
            guard candidate.aggregatedSimilarity >= self.aggregateThreshold else { return }
            guard bestScore - runnerUpScore >= self.similarityMargin else { return }
            guard self.canTriggerDetection(for: candidate.keyword.keywordID) else { return }
            
            self.noiseFloor = min(self.noiseFloor, clampedLevel * 0.6)
            self.lastDetection = Date()
            self.lastKeywordID = candidate.keyword.keywordID
            DispatchQueue.main.async {
                self.onDetection?(candidate.keyword.keywordID, candidate.keyword.keywordName)
            }
            
            print("[KeywordDetector] process: Detected keyword \(candidate.keyword.keywordName) with similarity \(candidate.variationSimilarity) aggregated=\(candidate.aggregatedSimilarity)")
        }
    }
}
