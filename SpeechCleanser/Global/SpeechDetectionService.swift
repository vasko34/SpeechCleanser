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
    
    private let processingQueue = DispatchQueue(label: "SpeechDetectionService.processing", qos: .userInitiated)
    private let audioEngine = AVAudioEngine()
    private let cooldownInterval: TimeInterval = 6.0
    private let downsampler = AudioDownsampler(targetSampleRate: 16_000)
    
    private var slidingBuffer = SlidingWindowBuffer(windowDuration: 0.8, hopDuration: 0.2, sampleRate: 16_000)
    private var whisperProcessor: WhisperRealtimeProcessor?
    private var keywordCache: [Keyword] = []
    private var detectionCooldowns: [UUID: Date] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var sessionConfigured = false
    
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
        if let url = Bundle.main.url(forResource: "ggml-small-q5_0", withExtension: "bin") {
            let configuration = WhisperRealtimeProcessor.Configuration(windowDuration: 0.8, hopDuration: 0.2, enableVAD: true)
            whisperProcessor = WhisperRealtimeProcessor(modelURL: url, configuration: configuration)
            if whisperProcessor?.isOperational == true {
                print("[SpeechDetectionService] configureModel: Whisper model loaded from \(url.lastPathComponent)")
            } else {
                print("[SpeechDetectionService][ERROR] configureModel: Failed to initialize whisper processor with model at \(url)")
            }
        } else {
            print("[SpeechDetectionService][ERROR] configureModel: Model ggml-small-q5_0.bin not found in bundle")
        }
    }
    
    private func configureSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers, .defaultToSpeaker])
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
        
        print("[SpeechDetectionService] prepareEngine: Installing tap sampleRate=\(tapFormat.sampleRate) channels=\(tapFormat.channelCount)")
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            self.processingQueue.async {
                self.handleAudioBuffer(buffer)
            }
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
            beginBackgroundTask()
            postStateChange()
            print("[SpeechDetectionService] prepareEngine: Audio engine started")
            return true
        } catch {
            print("[SpeechDetectionService][ERROR] prepareEngine: Audio engine failed with error \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            return false
        }
    }
    
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let samples = downsampler.convert(buffer: buffer)
        guard !samples.isEmpty else { return }
        
        let windows = slidingBuffer.append(samples)
        if !windows.isEmpty {
            print("[SpeechDetectionService] handleAudioBuffer: Generated \(windows.count) windows from \(samples.count) samples")
        }
        guard let processor = whisperProcessor else { return }
        guard !keywordCache.isEmpty else {
            print("[SpeechDetectionService] handleAudioBuffer: Skipping transcription because keyword cache is empty")
            return
        }
        
        for window in windows {
            processor.transcribe(samples: window, completionQueue: processingQueue) { [weak self] transcript in
                guard let self = self else { return }
                guard !transcript.isEmpty else { return }
                
                self.evaluateTranscription(transcript)
            }
        }
    }
    
    private func reloadKeywordCache() {
        let keywords = KeywordStore.shared.load().filter { $0.isEnabled && !$0.variations.isEmpty }
        keywordCache = keywords
        detectionCooldowns = detectionCooldowns.filter { Date().timeIntervalSince($0.value) < cooldownInterval }
        let variations = keywords.reduce(0) { $0 + $1.variations.count }
        print("[SpeechDetectionService] reloadKeywordCache: Cached \(keywords.count) enabled keywords with \(variations) variations")
    }
    
    private func evaluateTranscription(_ transcript: String) {
        print("[SpeechDetectionService] evaluateTranscription: Transcript='\(transcript)'")
        let normalizedTranscript = transcript.normalizedForKeywordMatching()
        guard !normalizedTranscript.isEmpty else { return }
        
        let now = Date()
        for keyword in keywordCache {
            for variation in keyword.variations {
                let normalizedVariation = variation.name.normalizedForKeywordMatching()
                guard !normalizedVariation.isEmpty else { continue }
                
                if normalizedTranscript.contains(normalizedVariation) {
                    if let last = detectionCooldowns[keyword.id], now.timeIntervalSince(last) < cooldownInterval {
                        continue
                    }
                    
                    detectionCooldowns[keyword.id] = now
                    handleDetection(keyword: keyword, variation: variation, transcript: transcript)
                    return
                }
            }
        }
    }
    
    private func handleDetection(keyword: Keyword, variation: Variation, transcript: String) {
        print("[SpeechDetectionService] handleDetection: Keyword=\(keyword.name) variation=\(variation.name) transcript=\(transcript)")
        PavlokService.shared.sendZap(for: keyword)
        NotificationManager.sendDetectionNotification(for: keyword, variation: variation)
    }
    
    private func beginBackgroundTask() {
        DispatchQueue.main.async {
            guard self.backgroundTask == .invalid else { return }
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SpeechDetection") { [weak self] in
                self?.endBackgroundTask()
            }
            print("[SpeechDetectionService] beginBackgroundTask: Background task started")
        }
    }
    
    private func endBackgroundTask() {
        DispatchQueue.main.async {
            guard self.backgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
            print("[SpeechDetectionService] endBackgroundTask: Background task ended")
        }
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
        session.requestRecordPermission { [weak self] granted in
            guard let self = self else { return }
            if !granted {
                print("[SpeechDetectionService][ERROR] startListening: Microphone permission denied")
                DispatchQueue.main.async {
                    completion?(false)
                }
                return
            }
            
            self.processingQueue.async {
                self.reloadKeywordCache()
                let sessionConfigured = self.configureSession()
                guard sessionConfigured else {
                    DispatchQueue.main.async {
                        completion?(false)
                    }
                    return
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
        processingQueue.async {
            guard self.audioEngine.isRunning else { return }
            
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.audioEngine.stop()
            self.audioEngine.reset()
            self.slidingBuffer.reset()
            self.detectionCooldowns.removeAll()
            self.endBackgroundTask()
            self.deactivateSession()
            self.postStateChange()
            print("[SpeechDetectionService] stopListening: Audio engine stopped")
        }
    }
}
