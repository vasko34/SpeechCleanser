//
//  SpeechDetectionService.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import AVFoundation
import UIKit

final class SpeechDetectionService {
    static let shared = SpeechDetectionService()
    
    private struct NormalizedVariationEntry {
        let variation: Variation
        let normalized: String
        let tokens: [String]
    }
    
    private struct PendingWindow {
        let samples: [Float]
        let startDate: Date
    }
    
    private let processingQueue = DispatchQueue(label: "SpeechDetectionService.processing", qos: .userInitiated)
    private let audioEngine = AVAudioEngine()
    private let cooldownInterval: TimeInterval = 6.0
    private let targetSampleRate: Double = 16_000
    private let downsampler = AudioDownsampler(targetSampleRate: 16_000)
    private let windowDuration: TimeInterval = 0.6
    private let hopDuration: TimeInterval = 0.15
    
    private var whisperProcessor: WhisperRealtimeProcessor?
    private var keywordCache: [Keyword] = []
    private var normalizedVariationCache: [UUID: [NormalizedVariationEntry]] = [:]
    private var detectionCooldowns: [UUID: Date] = [:]
    private var sessionConfigured = false
    private var timestampEstimator: AudioTimestampEstimator?
    private var sessionStartDate: Date?
    private var pendingWindow: PendingWindow?
    private lazy var slidingBuffer = SlidingWindowBuffer(windowDuration: windowDuration, hopDuration: hopDuration, sampleRate: Int(targetSampleRate))
    
    var isListening: Bool { audioEngine.isRunning }
    
    private init() {
        configureModel()
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleKeywordStoreUpdate), name: .keywordStoreDidChange, object: nil)
        processingQueue.async { [weak self] in
            self?.reloadKeywordCache()
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        print("[SpeechDetectionService] deinit: Removed observers")
    }
    
    private func configureModel() {
        let bundle = Bundle.main
        let modelName = "ggml-small-q5_1"
        var locatedURL: URL?
        
        if let direct = bundle.url(forResource: modelName, withExtension: "bin") {
            locatedURL = direct
        } else if let subpath = bundle.url(forResource: modelName, withExtension: "bin", subdirectory: "WhisperResources") {
            locatedURL = subpath
        }
        
        guard let url = locatedURL else {
            print("[SpeechDetectionService][ERROR] configureModel: Model ggml-small-q5_1.bin not found in bundle or WhisperResources")
            return
        }
        
        let configuration = WhisperConfiguration(windowDuration: windowDuration, hopDuration: hopDuration, enableVAD: true)
        whisperProcessor = WhisperRealtimeProcessor(modelURL: url, configuration: configuration)
        if whisperProcessor?.isOperational == true {
            print("[SpeechDetectionService] configureModel: Whisper model loaded from \(url.lastPathComponent) forcing language=bg")
        } else {
            print("[SpeechDetectionService][ERROR] configureModel: Failed to initialize whisper processor with model at \(url)")
        }
    }
    
    private func configureSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers, .defaultToSpeaker])
            try session.setPreferredSampleRate(16_000)
            try session.setPreferredIOBufferDuration(hopDuration)
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
            sessionConfigured = true
            print("[SpeechDetectionService] configureSession: Session activated with measurement mode")
            return true
        } catch {
            sessionConfigured = false
            print("[SpeechDetectionService][ERROR] configureSession: Failed with error \(error.localizedDescription)")
            return false
        }
    }
    
    private func deactivateSession() {
        guard sessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            print("[SpeechDetectionService] deactivateSession: Session deactivated")
        } catch {
            print("[SpeechDetectionService][ERROR] deactivateSession: Failed with error \(error.localizedDescription)")
        }
        sessionConfigured = false
    }
    
    private func prepareEngine() -> Bool {
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardwareFormat.sampleRate, channels: hardwareFormat.channelCount, interleaved: false) else {
            print("[SpeechDetectionService][ERROR] prepareEngine: Unable to create tap format for sampleRate=\(hardwareFormat.sampleRate)")
            return false
        }
        
        timestampEstimator = AudioTimestampEstimator(sourceSampleRate: tapFormat.sampleRate)
        print("[SpeechDetectionService] prepareEngine: Installing tap sampleRate=\(tapFormat.sampleRate) channels=\(tapFormat.channelCount)")
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, when in
            guard let self = self else { return }
            
            self.processingQueue.async {
                self.handleAudioBuffer(buffer, time: when)
            }
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
            postStateChange()
            print("[SpeechDetectionService] prepareEngine: Audio engine started")
            return true
        } catch {
            print("[SpeechDetectionService][ERROR] prepareEngine: Audio engine failed with error \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            return false
        }
    }
    
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let samples = downsampler.convert(buffer: buffer)
        guard !samples.isEmpty else {
            print("[SpeechDetectionService] handleAudioBuffer: Downsampler returned empty sample array")
            return
        }
        
        let bufferDate = timestampEstimator?.bufferStartDate(for: time, frameLength: buffer.frameLength) ?? Date()
        if sessionStartDate == nil {
            sessionStartDate = bufferDate
            let timestamp = String(format: "%.3f", bufferDate.timeIntervalSince1970)
            print("[SpeechDetectionService] handleAudioBuffer: Session start anchored at epoch \(timestamp)s")
        }
        let windows = slidingBuffer.append(samples)
        guard !windows.isEmpty else { return }
        
        print("[SpeechDetectionService] handleAudioBuffer: Generated \(windows.count) windows from \(samples.count) samples")
        guard !keywordCache.isEmpty else {
            print("[SpeechDetectionService] handleAudioBuffer: Skipping transcription because keyword cache is empty")
            return
        }
        
        guard let baseDate = sessionStartDate else {
            print("[SpeechDetectionService][ERROR] handleAudioBuffer: Missing session start date while windows ready")
            return
        }
        
        for window in windows {
            let relativeOffset = Double(window.startSampleIndex) / targetSampleRate
            let windowStartDate = baseDate.addingTimeInterval(relativeOffset)
            enqueueWindow(samples: window.samples, startDate: windowStartDate)
        }
    }
    
    private func submitTranscription(with processor: WhisperRealtimeProcessor, samples: [Float], startDate: Date) -> Bool {
        return processor.transcribe(samples: samples, startDate: startDate, completionQueue: processingQueue) { [weak self] result in
            guard let self = self else { return }
            self.evaluateTranscription(result)
            self.processPendingWindowIfNeeded()
        }
    }
    
    private func enqueueWindow(samples: [Float], startDate: Date) {
        guard let processor = whisperProcessor, processor.isOperational else {
            print("[SpeechDetectionService][ERROR] enqueueWindow: Whisper processor unavailable or not operational")
            return
        }
        
        if submitTranscription(with: processor, samples: samples, startDate: startDate) {
            return
        }
        
        let offset = sessionStartDate.map { startDate.timeIntervalSince($0) } ?? 0
        print(String(format: "[SpeechDetectionService] enqueueWindow: Processor busy, deferring window offset=%.2fs", offset))
        pendingWindow = PendingWindow(samples: samples, startDate: startDate)
    }
    
    private func processPendingWindowIfNeeded() {
        guard let deferred = pendingWindow else { return }
        guard let processor = whisperProcessor, processor.isOperational else {
            print("[SpeechDetectionService][ERROR] processPendingWindowIfNeeded: Whisper processor unavailable during retry")
            pendingWindow = nil
            return
        }
        
        pendingWindow = nil
        if submitTranscription(with: processor, samples: deferred.samples, startDate: deferred.startDate) {
            return
        }
        
        let offset = sessionStartDate.map { deferred.startDate.timeIntervalSince($0) } ?? 0
        print(String(format: "[SpeechDetectionService][ERROR] processPendingWindowIfNeeded: Processor still busy for deferred window offset=%.2fs", offset))
        pendingWindow = deferred
    }
    
    private func reloadKeywordCache() {
        let keywords = KeywordStore.shared.load().filter { $0.isEnabled && !$0.variations.isEmpty }
        keywordCache = keywords
        normalizedVariationCache.removeAll(keepingCapacity: true)
        
        for keyword in keywords {
            var seen: Set<String> = []
            let entries = keyword.variations.compactMap { variation -> NormalizedVariationEntry? in
                let normalized = variation.name.normalizedForKeywordMatching()
                guard !normalized.isEmpty else { return nil }
                let tokens = normalized.split(separator: " ").map(String.init)
                guard !tokens.isEmpty else { return nil }
                guard seen.insert(normalized).inserted else {
                    print("[SpeechDetectionService] reloadKeywordCache: Skipping duplicate normalized variation for keyword \(keyword.name)")
                    return nil
                }
                
                return NormalizedVariationEntry(variation: variation, normalized: normalized, tokens: tokens)
            }
            normalizedVariationCache[keyword.id] = entries
        }
        
        detectionCooldowns = detectionCooldowns.filter { Date().timeIntervalSince($0.value) < cooldownInterval }
        let variations = keywords.reduce(0) { $0 + ($1.variations.count) }
        let normalizedCount = normalizedVariationCache.values.reduce(0) { $0 + $1.count }
        print("[SpeechDetectionService] reloadKeywordCache: Cached \(keywords.count) enabled keywords with \(variations) variations (normalized=\(normalizedCount))")
    }
    
    private func evaluateTranscription(_ result: WhisperTranscriptionResult) {
        guard !result.transcript.isEmpty else {
            print("[SpeechDetectionService] evaluateTranscription: Received empty transcript window")
            return
        }
        
        let transcript = result.transcript
        print(String(format: "[SpeechDetectionService] evaluateTranscription: Transcript='%@' startOffset=%.2fs endOffset=%.2fs", transcript, result.startOffset, result.endOffset))
        let normalizedTranscript = transcript.normalizedForKeywordMatching()
        print("[SpeechDetectionService] evaluateTranscription: Normalized='\(normalizedTranscript)' length=\(normalizedTranscript.count)")
        guard !normalizedTranscript.isEmpty else { return }
        let transcriptTokens = normalizedTranscript.split(separator: " ").map(String.init)
        guard !transcriptTokens.isEmpty else { return }
        
        var tokenOffsets: [Int] = []
        tokenOffsets.reserveCapacity(transcriptTokens.count)
        var runningOffset = 0
        for (index, token) in transcriptTokens.enumerated() {
            tokenOffsets.append(runningOffset)
            runningOffset += token.count
            if index < transcriptTokens.count - 1 {
                runningOffset += 1
            }
        }
        
        let normalizedLength = runningOffset
        for keyword in keywordCache {
            guard let normalizedEntries = normalizedVariationCache[keyword.id] else {
                print("[SpeechDetectionService][ERROR] evaluateTranscription: Missing normalized variations for keyword \(keyword.name)")
                continue
            }
            guard !normalizedEntries.isEmpty else {
                print("[SpeechDetectionService] evaluateTranscription: Normalized variation list empty for keyword \(keyword.name)")
                continue
            }
            
            for entry in normalizedEntries {
                guard let matchIndex = transcriptTokens.firstIndexOfSequence(entry.tokens) else { continue }
                
                let detectionDate = detectionDate(forMatchAt: matchIndex, entry: entry, tokenOffsets: tokenOffsets, normalizedLength: normalizedLength, result: result)
                if let last = detectionCooldowns[keyword.id], detectionDate.timeIntervalSince(last) < cooldownInterval {
                    print("[SpeechDetectionService] evaluateTranscription: Cooldown active for keyword \(keyword.name)")
                    continue
                }
                
                detectionCooldowns[keyword.id] = detectionDate
                handleDetection(keyword: keyword, variation: entry.variation, transcript: transcript, detectionDate: detectionDate)
                
                return
            }
        }
    }
    
    private func detectionDate(forMatchAt tokenIndex: Int, entry: NormalizedVariationEntry, tokenOffsets: [Int], normalizedLength: Int, result: WhisperTranscriptionResult) -> Date {
        let baseDate = result.windowStartDate.addingTimeInterval(result.startOffset)
        let duration = result.segmentDuration
        guard tokenIndex < tokenOffsets.count else { return baseDate }
        guard normalizedLength > 0, duration > 0 else { return baseDate }
        
        let startOffset = tokenOffsets[tokenIndex]
        var matchLength = entry.tokens.reduce(0) { $0 + $1.count }
        if entry.tokens.count > 1 {
            matchLength += entry.tokens.count - 1
        }
        
        let midpoint = startOffset + max(matchLength - 1, 0) / 2
        let divisor = max(normalizedLength - 1, 1)
        let ratio = max(0, min(Double(midpoint) / Double(divisor), 1))
        
        return baseDate.addingTimeInterval(ratio * duration)
    }
    
    private func handleDetection(keyword: Keyword, variation: Variation, transcript: String, detectionDate: Date) {
        print("[SpeechDetectionService] handleDetection: Keyword=\(keyword.name) variation=\(variation.name) transcript=\(transcript) detectionTime=\(detectionDate)")
        PavlokService.shared.sendZap(for: keyword)
        NotificationManager.sendDetectionNotification(for: keyword, variation: variation, detectionDate: detectionDate)
    }
    
    private func postStateChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .speechDetectionStateChanged, object: nil)
        }
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        switch type {
        case .began:
            print("[SpeechDetectionService] handleInterruption: Interruption began")
            stopListening()
        case .ended:
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("[SpeechDetectionService] handleInterruption: Interruption ended, attempting to resume")
                    startListening()
                }
            }
        default:
            print("[SpeechDetectionService][ERROR] handleInterruption: Unknown interruption type")
        }
    }
    
    @objc private func handleKeywordStoreUpdate() {
        processingQueue.async { [weak self] in
            self?.reloadKeywordCache()
        }
    }
    
    func startListening(completion: ((Bool) -> Void)? = nil) {
        print("[SpeechDetectionService] startListening: Requested start, current state=\(audioEngine.isRunning)")
        if audioEngine.isRunning {
            DispatchQueue.main.async {
                completion?(true)
            }
            return
        }
        
        guard let processor = whisperProcessor, processor.isOperational else {
            print("[SpeechDetectionService][ERROR] startListening: Whisper processor unavailable")
            DispatchQueue.main.async {
                completion?(false)
            }
            return
        }
        
        let session = AVAudioSession.sharedInstance()
        print("[SpeechDetectionService] startListening: Requesting microphone permission")
        
        session.requestRecordPermission { [weak self] granted in
            guard let self = self else { return }
            if !granted {
                print("[SpeechDetectionService][ERROR] startListening: Microphone permission denied")
                DispatchQueue.main.async {
                    completion?(false)
                }
                return
            }
            
            print("[SpeechDetectionService] startListening: Microphone permission granted")
            self.processingQueue.async {
                self.reloadKeywordCache()
                self.slidingBuffer.reset()
                self.detectionCooldowns.removeAll()
                self.downsampler.reset()
                self.timestampEstimator = nil
                self.sessionStartDate = nil
                self.pendingWindow = nil
                print("[SpeechDetectionService] startListening: Cleared buffers and cooldowns prior to session start")
                
                let sessionConfigured = self.configureSession()
                guard sessionConfigured else {
                    DispatchQueue.main.async {
                        completion?(false)
                    }
                    return
                }
                
                if self.keywordCache.isEmpty {
                    print("[SpeechDetectionService] startListening: No enabled keywords available at start")
                }
                
                let prepared = self.prepareEngine()
                if !prepared {
                    self.deactivateSession()
                }
                DispatchQueue.main.async {
                    completion?(prepared)
                }
            }
        }
    }
    
    func stopListening() {
        print("[SpeechDetectionService] stopListening: Requested stop")
        processingQueue.async {
            guard self.audioEngine.isRunning else {
                print("[SpeechDetectionService] stopListening: Audio engine already stopped")
                return
            }
            
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.audioEngine.stop()
            self.audioEngine.reset()
            self.slidingBuffer.reset()
            self.detectionCooldowns.removeAll()
            self.pendingWindow = nil
            self.sessionStartDate = nil
            self.timestampEstimator = nil
            self.downsampler.reset()
            self.deactivateSession()
            self.postStateChange()
            print("[SpeechDetectionService] stopListening: Audio engine stopped")
        }
    }
}
