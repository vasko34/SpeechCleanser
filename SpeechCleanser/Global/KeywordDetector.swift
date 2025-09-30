//
//  KeywordDetector.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import AVFoundation
import Accelerate

final class KeywordDetector {
    private struct CachedVariation {
        let sampleCount: Int
        let template: [Float]
        let minRMS: Float
    }
    
    private struct CachedKeyword {
        let id: UUID
        let name: String
        let variations: [CachedVariation]
    }
    
    private let queue = DispatchQueue(label: "KeywordDetector.queue")
    private let similarityThreshold: Float = 0.68
    private let marginThreshold: Float = 0.1
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
    private var lastLoggedNoise: Float = 0
    
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
            lastLoggedNoise = clamped
            print("[KeywordDetector] updateNoise: Initialized noiseFloor=\(clamped)")
            return
        }
        
        let alpha = clamped > noiseFloor ? noiseLearningRate * 0.5 : noiseLearningRate
        let updated = (1 - alpha) * noiseFloor + alpha * clamped
        noiseFloor = min(max(updated, 0.0005), maxNoiseFloor)
        
        if abs(noiseFloor - lastLoggedNoise) > 0.01 {
            lastLoggedNoise = noiseFloor
            print("[KeywordDetector] updateNoise: Adjusted noiseFloor=\(noiseFloor) level=\(clamped)")
        }
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
    
    private func normalize(_ values: inout [Float]) -> Bool {
        guard !values.isEmpty else { return false }
        
        var mean: Float = 0
        vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))
        
        var negativeMean = -mean
        vDSP_vsadd(values, 1, &negativeMean, &values, 1, vDSP_Length(values.count))
        
        var variance: Float = 0
        vDSP_measqv(values, 1, &variance, vDSP_Length(values.count))
        variance = sqrtf(variance)
        
        guard variance > .ulpOfOne else { return false }
        
        var divisor = variance
        vDSP_vsdiv(values, 1, &divisor, &values, 1, vDSP_Length(values.count))
        return true
    }
    
    private func trimSilence(from samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        
        let threshold: Float = 0.002
        var start = 0
        var end = samples.count - 1
        
        while start < end && abs(samples[start]) < threshold { start += 1 }
        while end > start && abs(samples[end]) < threshold { end -= 1 }
        
        if end <= start { return samples }
        return Array(samples[start...end])
    }
    
    private func resample(_ samples: [Float], to targetCount: Int) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard targetCount > 0 else { return [] }
        
        if samples.count == targetCount { return samples }
        if targetCount == 1 { return [samples.last ?? 0] }
        
        let inputCount = samples.count
        let step = Float(inputCount - 1) / Float(targetCount - 1)
        var position: Float = 0
        var output = [Float](repeating: 0, count: targetCount)
        
        for index in 0..<targetCount {
            let lower = min(Int(position), inputCount - 1)
            let upper = min(lower + 1, inputCount - 1)
            let fraction = position - Float(lower)
            let lowerValue = samples[lower]
            let upperValue = samples[upper]
            output[index] = lowerValue + (upperValue - lowerValue) * fraction
            position += step
        }
        
        return output
    }
    
    private func prepareVariation(_ variation: Variation, sampleRate: Double) -> CachedVariation? {
        let url = KeywordStore.fileURL(for: variation.filePath)
        let audioFile: AVAudioFile
        
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            print("[KeywordDetector][ERROR] prepareVariation: Failed to open file with error: \(error.localizedDescription)")
            return nil
        }
        
        let format = audioFile.processingFormat
        let frameCapacity = AVAudioFrameCount(audioFile.length)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            print("[KeywordDetector][ERROR] prepareVariation: Unable to create PCM buffer")
            return nil
        }
        
        do {
            try audioFile.read(into: buffer)
        } catch {
            print("[KeywordDetector][ERROR] prepareVariation: Failed to read audio with error: \(error.localizedDescription)")
            return nil
        }
        
        guard let channelData = buffer.floatChannelData else {
            print("[KeywordDetector][ERROR] prepareVariation: Missing channel data")
            return nil
        }
        
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else {
            print("[KeywordDetector][ERROR] prepareVariation: Invalid channel count")
            return nil
        }
        
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            print("[KeywordDetector][ERROR] prepareVariation: Empty buffer")
            return nil
        }
        
        var mono = [Float](repeating: 0, count: frameLength)

        for frameIndex in 0..<frameLength {
            var accumulator: Float = 0
            for channel in 0..<channelCount {
                let source = channelData[channel]
                accumulator += source[frameIndex]
            }
            mono[frameIndex] = accumulator
        }

        if channelCount > 1 {
            let divisor = Float(channelCount)
            for index in 0..<frameLength {
                mono[index] /= divisor
            }
        }

        let trimmed = trimSilence(from: mono)
        let safeDuration = max(variation.duration, 0.3)
        let targetCount = max(1, Int(safeDuration * sampleRate))
        let resampled = resample(trimmed, to: targetCount)
        
        guard !resampled.isEmpty else {
            print("[KeywordDetector][ERROR] prepareVariation: Resampled data empty")
            return nil
        }
        
        var rms: Float = 0
        vDSP_measqv(resampled, 1, &rms, vDSP_Length(resampled.count))
        rms = sqrtf(rms)
        
        var template = resampled
        guard normalize(&template) else {
            print("[KeywordDetector][ERROR] prepareVariation: Normalization failed")
            return nil
        }
        
        let minimumRMS = max(minSignalLevel, rms * 0.45)
        return CachedVariation(sampleCount: template.count, template: template, minRMS: minimumRMS)
    }
    
    func configure(keywords: [Keyword], sampleRate: Double) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.sampleRate = sampleRate
            let enabled = keywords.filter { $0.isEnabled }
            self.keywords = enabled.compactMap { keyword -> CachedKeyword? in
                let variations = keyword.variations.compactMap { variation -> CachedVariation? in
                    return self.prepareVariation(variation, sampleRate: sampleRate)
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
                    let startOffset = min(latestStart, searchBuffer.count - sampleCount)
                    var windowBuffer = [Float](repeating: 0, count: sampleCount)
                    
                    searchBuffer.withUnsafeBufferPointer { pointer in
                        guard let base = pointer.baseAddress else { return }
                        var offset = startOffset
                        
                        while offset + sampleCount <= searchBuffer.count {
                            windowBuffer.withUnsafeMutableBufferPointer { destination in
                                guard let dest = destination.baseAddress else { return }
                                let source = base + offset
                                dest.update(from: source, count: sampleCount)
                            }
                            
                            var rms: Float = 0
                            vDSP_measqv(windowBuffer, 1, &rms, vDSP_Length(sampleCount))
                            rms = sqrtf(rms)
                            
                            if rms < variation.minRMS {
                                offset += stride
                                continue
                            }
                            
                            if !self.normalize(&windowBuffer) {
                                offset += stride
                                continue
                            }
                            
                            var similarity: Float = 0
                            vDSP_dotpr(windowBuffer, 1, variation.template, 1, &similarity, vDSP_Length(sampleCount))
                            similarity /= Float(sampleCount)
                            
                            if similarity > keywordBest {
                                keywordBest = similarity
                            }
                            offset += stride
                        }
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
            if bestScore >= 0.4 {
                print("[KeywordDetector] process: Candidate=\(candidate.name) score=\(bestScore) runnerUp=\(runnerUp) level=\(clampedLevel) threshold=\(triggerLevel)")
            }
            
            guard bestScore >= self.similarityThreshold else {
                print("[KeywordDetector] process: Rejected \(candidate.name) reason=similarity threshold score=\(bestScore) required=\(self.similarityThreshold)")
                return
            }
            
            let margin = bestScore - runnerUp
            guard margin >= self.marginThreshold else {
                print("[KeywordDetector] process: Rejected \(candidate.name) reason=margin score=\(bestScore) runnerUp=\(runnerUp) requiredMargin=\(self.marginThreshold)")
                return
            }
            
            guard self.canTrigger(keywordID: candidate.id) else {
                print("[KeywordDetector] process: Rejected \(candidate.name) reason=cooldown active")
                return
            }
            
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
