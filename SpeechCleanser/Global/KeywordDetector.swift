//
//  KeywordDetector.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import Foundation

final class KeywordDetector {
    private struct CachedVariation {
        let keywordID: UUID
        let keywordName: String
        let variationID: UUID
        let duration: TimeInterval
        let fingerprint: [Float]
    }
    
    private let searchPadding: TimeInterval = 0.35
    private let similarityThreshold: Float = 0.62
    private let windowStrideDivisor = 5
    private let queue = DispatchQueue(label: "KeywordDetector.queue")
    
    private var variations: [CachedVariation] = []
    private var lastDetection: Date?
    private var debounceInterval: TimeInterval = 2.5
    private var sampleRate: Double = 44_100
    private var circularBuffer: [Float] = []
    private var maxSampleCount: Int = 0
    
    var onDetection: ((UUID, String) -> Void)?
    
    private func appendSamples(_ samples: [Float]) {
        circularBuffer.append(contentsOf: samples)
        if circularBuffer.count > maxSampleCount {
            circularBuffer.removeFirst(circularBuffer.count - maxSampleCount)
        }
    }
    
    private func canTriggerDetection() -> Bool {
        guard let last = lastDetection else { return true }
        return Date().timeIntervalSince(last) >= debounceInterval
    }
    
    func configure(keywords: [Keyword], sampleRate: Double) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.sampleRate = sampleRate
            self.variations = keywords
                .filter { $0.isEnabled }
                .flatMap { keyword in
                    keyword.variations.compactMap { variation -> CachedVariation? in
                        guard !variation.fingerprint.isEmpty else { return nil }
                        
                        return CachedVariation(
                            keywordID: keyword.id,
                            keywordName: keyword.name,
                            variationID: variation.id,
                            duration: variation.duration,
                            fingerprint: variation.fingerprint
                        )
                    }
                }
            
            let longestDuration = self.variations.map { $0.duration }.max() ?? 0
            let windowDuration = max(longestDuration + self.searchPadding, 0.5)
            self.maxSampleCount = Int(windowDuration * sampleRate) + 1_024
            if self.maxSampleCount <= 0 { self.maxSampleCount = 1_024 }
            self.circularBuffer = []
            print("[KeywordDetector] configure: Cached \(self.variations.count) variations at sampleRate \(sampleRate)")
        }
    }
    
    func process(samples: [Float]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard !self.variations.isEmpty else { return }
            
            self.appendSamples(samples)
            let availableCount = self.circularBuffer.count
            let searchCount = min(availableCount, self.maxSampleCount)
            guard searchCount > 0 else { return }
            
            let startIndex = availableCount - searchCount
            let searchBuffer = Array(self.circularBuffer[startIndex..<availableCount])
            
            for variation in self.variations {
                let sampleCount = max(1, Int(variation.duration * self.sampleRate))
                guard searchBuffer.count >= sampleCount else { continue }
                
                let strideLength = max(1, sampleCount / self.windowStrideDivisor)
                var offset = 0
                
                while offset + sampleCount <= searchBuffer.count {
                    let window = Array(searchBuffer[offset..<(offset + sampleCount)])
                    let fingerprint = AudioFingerprint.generateFingerprint(from: window)
                    guard fingerprint.count == variation.fingerprint.count else {
                        offset += strideLength
                        continue
                    }
                    
                    let similarity = AudioFingerprint.similarity(between: fingerprint, and: variation.fingerprint)
                    if similarity >= self.similarityThreshold, self.canTriggerDetection() {
                        self.lastDetection = Date()
                        DispatchQueue.main.async {
                            self.onDetection?(variation.keywordID, variation.keywordName)
                        }
                        print("[KeywordDetector] process: Detected keyword \(variation.keywordName) with similarity \(similarity)")
                        return
                    }
                    
                    offset += strideLength
                }
            }
        }
    }
}
