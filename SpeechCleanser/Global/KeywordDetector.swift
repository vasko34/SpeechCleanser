//
//  KeywordDetector.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import Foundation

final class KeywordDetector {
    private struct CachedVariation {
        let sampleCount: Int
        let fingerprint: [Float]
    }
    
    private struct CachedKeyword {
        let id: UUID
        let name: String
        let variations: [CachedVariation]
    }
    
    private struct FingerprintCacheKey: Hashable {
        let offset: Int
        let length: Int
    }
    
    private let queue = DispatchQueue(label: "KeywordDetector.queue")
    private let similarityThreshold: Float = 0.74
    private let marginThreshold: Float = 0.08
    private let minSignalLevel: Float = 0.015
    private let noiseBoost: Float = 2.4
    private let noiseLearningRate: Float = 0.04
    private let maxNoiseFloor: Float = 0.05
    private let globalCooldown: TimeInterval = 1.6
    private let keywordCooldown: TimeInterval = 4.0
    private let windowPadding: TimeInterval = 0.45
    private let strideDivisor = 6
    private let retentionMultiplier = 4
    
    private var keywords: [CachedKeyword] = []
    private var sampleRate: Double = 44_100
    private var circularBuffer: [Float] = []
    private var maxSampleCount: Int = 0
    private var noiseFloor: Float = 0
    private var lastGlobalDetection: Date?
    private var lastKeywordDetections: [UUID: Date] = [:]
    
    var onDetection: ((UUID, String) -> Void)?
    
    private func appendSamples(_ samples: [Float]) {
        circularBuffer.append(contentsOf: samples)
        if circularBuffer.count > maxSampleCount {
            circularBuffer.removeFirst(circularBuffer.count - maxSampleCount)
        }
    }
    
    private func updateNoise(with level: Float) {
        let clamped = max(0, min(level, 1))
        
        if noiseFloor == 0 {
            noiseFloor = clamped
            return
        }
        
        let alpha = clamped > noiseFloor ? noiseLearningRate * 0.5 : noiseLearningRate
        let updated = (1 - alpha) * noiseFloor + alpha * clamped
        noiseFloor = min(max(updated, 0.0005), maxNoiseFloor)
    }
    
    private func currentThreshold() -> Float {
        let boosted = noiseFloor * noiseBoost
        return max(minSignalLevel, min(boosted, maxNoiseFloor))
    }
    
    private func canTrigger(keywordID: UUID) -> Bool {
        let now = Date()
        if let last = lastGlobalDetection, now.timeIntervalSince(last) < globalCooldown {
            return false
        }
        
        if let previous = lastKeywordDetections[keywordID], now.timeIntervalSince(previous) < keywordCooldown {
            return false
        }
        
        return true
    }
    
    private func markDetection(for keywordID: UUID) {
        let now = Date()
        lastGlobalDetection = now
        lastKeywordDetections[keywordID] = now
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
            let enabled = keywords.filter { $0.isEnabled }
            self.keywords = enabled.compactMap { keyword -> CachedKeyword? in
                let variations = keyword.variations.compactMap { variation -> CachedVariation? in
                    guard !variation.fingerprint.isEmpty else { return nil }
                    let safeDuration = max(variation.duration, 0.3)
                    let sampleCount = max(1, Int(safeDuration * sampleRate))
                    return CachedVariation(sampleCount: sampleCount, fingerprint: variation.fingerprint)
                }
                guard !variations.isEmpty else { return nil }
                
                return CachedKeyword(id: keyword.id, name: keyword.name, variations: variations)
            }
            
            let longest = self.keywords.flatMap { $0.variations.map { Double($0.sampleCount) / sampleRate } }.max() ?? 0
            let windowDuration = max(longest + self.windowPadding, 0.5)
            
            self.maxSampleCount = Int(windowDuration * sampleRate) + 1_024
            if self.maxSampleCount <= 0 {
                self.maxSampleCount = 1_024
            }
            
            self.circularBuffer.removeAll(keepingCapacity: false)
            self.noiseFloor = 0
            self.lastGlobalDetection = nil
            self.lastKeywordDetections.removeAll(keepingCapacity: true)
            
            let variationCount = self.keywords.reduce(0) { $0 + $1.variations.count }
            print("[KeywordDetector] configure: Cached \(variationCount) variations at sampleRate \(sampleRate)")
        }
    }
    
    func process(samples: [Float], level: Float) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.keywords.isEmpty else { return }
            
            let clampedLevel = max(0, min(level, 1))
            self.updateNoise(with: clampedLevel)
            self.appendSamples(samples)
            let triggerLevel = self.currentThreshold()
            guard clampedLevel >= triggerLevel else { return }
            
            let availableCount = self.circularBuffer.count
            guard availableCount > 0 else { return }
            
            let searchCount = min(availableCount, self.maxSampleCount)
            let startIndex = availableCount - searchCount
            let searchBuffer = Array(self.circularBuffer[startIndex..<availableCount])
            guard !searchBuffer.isEmpty else { return }
            
            var cache: [FingerprintCacheKey: [Float]] = [:]
            var bestKeyword: CachedKeyword?
            var bestScore: Float = 0
            var runnerUp: Float = 0
            
            for keyword in self.keywords {
                var keywordBest: Float = 0
                
                for variation in keyword.variations {
                    let sampleCount = variation.sampleCount
                    guard sampleCount > 0, searchBuffer.count >= sampleCount else { continue }
                    
                    let stride = max(1, sampleCount / self.strideDivisor)
                    let latestStart = max(0, searchBuffer.count - sampleCount * self.retentionMultiplier)
                    var offset = min(latestStart, searchBuffer.count - sampleCount)
                    
                    while offset + sampleCount <= searchBuffer.count {
                        let fingerprint = self.fingerprint(for: searchBuffer, offset: offset, length: sampleCount, cache: &cache)
                        guard fingerprint.count == variation.fingerprint.count else {
                            offset += stride
                            continue
                        }
                        
                        let similarity = AudioFingerprint.similarity(between: fingerprint, and: variation.fingerprint)
                        if similarity > keywordBest {
                            keywordBest = similarity
                        }
                        
                        offset += stride
                    }
                }
                guard keywordBest > 0 else { continue }
                
                if keywordBest > bestScore {
                    runnerUp = bestScore
                    bestScore = keywordBest
                    bestKeyword = keyword
                } else if keywordBest > runnerUp {
                    runnerUp = keywordBest
                }
            }
            guard let candidate = bestKeyword else { return }
            guard bestScore >= self.similarityThreshold else { return }
            guard bestScore - runnerUp >= self.marginThreshold else { return }
            guard self.canTrigger(keywordID: candidate.id) else { return }
            
            self.markDetection(for: candidate.id)
            self.noiseFloor = min(self.noiseFloor, clampedLevel * 0.6)
            self.circularBuffer.removeAll(keepingCapacity: true)
            DispatchQueue.main.async {
                self.onDetection?(candidate.id, candidate.name)
            }
            
            print("[KeywordDetector] process: Detected keyword \(candidate.name) with similarity \(bestScore)")
        }
    }
}
