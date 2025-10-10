//
//  SpeechDetectionService.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 10.10.25.
//

import Foundation
import AVFoundation
import UIKit

final class SpeechDetectionService {
    static let shared = SpeechDetectionService()
    
    private let processingQueue = DispatchQueue(label: "com.speechcleanser.processing", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem, target: nil)
    private let matcher = KeywordMatcher()
    private let whisperProcessor = WhisperRealtimeProcessor()
    private let session = AVAudioSession.sharedInstance()
    private let userDefaults = UserDefaults.standard
    private let modelPreferenceKey = "preferred_whisper_model_size"
    private let detectionProbabilityThreshold: Float = 0.35
    private let notificationFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "bg_BG")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    
    private var keywordObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var keywords: [Keyword] = []
    private var audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private var desiredFormat: AVAudioFormat?
    private var activeConfiguration: WhisperConfiguration?
    private var sampleAccumulator: [Float] = []
    private var chunkBaseSampleIndex: Int = 0
    private var processedSamples: Int = 0
    private var captureStartDate: Date?
    private var metricsStartDate: Date?
    private var metricsBatteryLevel: Float = -1
    private var zapCount: Int = 0
    private var lastZapDate: Date?
    private var consecutiveHighLatencyDuration: TimeInterval = 0
    private var vadWindow: [Bool] = []
    private var lastLatencyAlertDate: Date?
    private var lastVADDutyAlertDate: Date?
    private var silenceChunkAllowance: Int = 0
    
    private(set) var isListening = false
    private(set) var selectedModelSize: ModelSize
    
    private init() {
        if let stored = userDefaults.string(forKey: modelPreferenceKey), let size = ModelSize(rawValue: stored) {
            selectedModelSize = size
        } else {
            selectedModelSize = .medium
        }
        
        keywords = KeywordStore.shared.load()
        keywordObserver = NotificationCenter.default.addObserver(forName: .keywordStoreDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.refreshKeywords()
        }
    }
    
    private func startInternal() -> Bool {
        refreshKeywords()
        let configuration = resolvedConfiguration()
        
        guard whisperProcessor.prepare(configuration: configuration) else {
            print("[SpeechDetectionService][ERROR] startInternal: Failed to prepare Whisper processor")
            return false
        }
        
        guard configureAudioSession(configuration: configuration) else {
            print("[SpeechDetectionService][ERROR] startInternal: Audio session configuration failed")
            return false
        }
        
        guard startAudioEngine(with: configuration) else {
            print("[SpeechDetectionService][ERROR] startInternal: Audio engine start failed")
            whisperProcessor.reset()
            do {
                try session.setActive(false, options: [.notifyOthersOnDeactivation])
            } catch {
                print("[SpeechDetectionService][ERROR] startInternal: Failed to deactivate session after engine error: \(error.localizedDescription)")
            }
            return false
        }
        
        activeConfiguration = configuration
        captureStartDate = nil
        sampleAccumulator.removeAll(keepingCapacity: true)
        chunkBaseSampleIndex = 0
        processedSamples = 0
        vadWindow.removeAll(keepingCapacity: true)
        consecutiveHighLatencyDuration = 0
        lastLatencyAlertDate = nil
        lastVADDutyAlertDate = nil
        silenceChunkAllowance = 0
        
        UIDevice.current.isBatteryMonitoringEnabled = true
        metricsStartDate = Date()
        metricsBatteryLevel = UIDevice.current.batteryLevel
        if metricsBatteryLevel < 0 {
            print("[SpeechDetectionService][ERROR] startInternal: Battery monitoring unavailable")
        }
        zapCount = 0
        registerAudioNotifications()

        return true
    }
    
    private func resolvedConfiguration() -> WhisperConfiguration {
        var configuration = WhisperConfiguration.default(for: selectedModelSize)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryState = UIDevice.current.batteryState
        if batteryState == .unplugged {
            configuration = WhisperConfiguration(
                modelSize: configuration.modelSize,
                sampleRate: configuration.sampleRate,
                frameDuration: configuration.frameDuration,
                chunkDuration: 1.5,
                overlapDuration: 0.3,
                language: configuration.language,
                translate: configuration.translate,
                threads: configuration.threads,
                beamSize: configuration.beamSize,
                bestOf: configuration.bestOf,
                temperatureFallback: configuration.temperatureFallback,
                suppressNumerals: configuration.suppressNumerals,
                contextTokenCount: configuration.contextTokenCount
            )
            print("[SpeechDetectionService] resolvedConfiguration: Operating on battery, adjusted chunk duration to reduce load")
        }
        
        return configuration
    }
    
    private func stopInternal() {
        unregisterAudioNotifications()
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.reset()
        
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("[SpeechDetectionService][ERROR] stopInternal: Failed to deactivate audio session with error: \(error.localizedDescription)")
        }
        
        whisperProcessor.reset()
        audioConverter = nil
        desiredFormat = nil
        activeConfiguration = nil
        sampleAccumulator.removeAll(keepingCapacity: true)
        vadWindow.removeAll(keepingCapacity: true)
        UIDevice.current.isBatteryMonitoringEnabled = false
        metricsStartDate = nil
        metricsBatteryLevel = -1
        lastZapDate = nil
        silenceChunkAllowance = 0
    }
    
    private func refreshKeywords() {
        keywords = KeywordStore.shared.load()
        matcher.updateKeywords(keywords)
        let enabledKeywords = keywords.filter { $0.isEnabled }
        let enabledCount = enabledKeywords.count
        let variationCount = enabledKeywords.reduce(0) { $0 + $1.variations.count }
        print("[SpeechDetectionService] refreshKeywords: Loaded \(keywords.count) keywords enabled=\(enabledCount) variationCount=\(variationCount)")
    }
    
    private func configureAudioSession(configuration: WhisperConfiguration) -> Bool {
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .mixWithOthers])
            try session.setPreferredSampleRate(configuration.sampleRate)
            try session.setPreferredIOBufferDuration(configuration.frameDuration)
            try session.setActive(true, options: [])
            print("[SpeechDetectionService] configureAudioSession: Session configured for background recording")
            return true
        } catch {
            print("[SpeechDetectionService][ERROR] configureAudioSession: Failed with error: \(error.localizedDescription)")
            return false
        }
    }
    
    private func startAudioEngine(with configuration: WhisperConfiguration) -> Bool {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        guard let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: configuration.sampleRate, channels: 1, interleaved: false) else {
            print("[SpeechDetectionService][ERROR] startAudioEngine: Unable to create target audio format")
            return false
        }
        
        audioConverter = AVAudioConverter(from: inputFormat, to: desiredFormat)
        guard audioConverter != nil else {
            print("[SpeechDetectionService][ERROR] startAudioEngine: AVAudioConverter initialization failed")
            return false
        }
        
        self.desiredFormat = desiredFormat
        let bufferSize = max(1024, AVAudioFrameCount(configuration.frameDuration * inputFormat.sampleRate))
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
            self?.handleIncoming(buffer: buffer, audioTime: time)
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
            print("[SpeechDetectionService] startAudioEngine: Audio engine running")
            return true
        } catch {
            print("[SpeechDetectionService][ERROR] startAudioEngine: Failed to start audio engine with error: \(error.localizedDescription)")
            return false
        }
    }
    
    private func handleIncoming(buffer: AVAudioPCMBuffer, audioTime: AVAudioTime) {
        processingQueue.async {
            self.processIncomingBuffer(buffer, audioTime: audioTime)
        }
    }
    
    private func processIncomingBuffer(_ buffer: AVAudioPCMBuffer, audioTime: AVAudioTime) {
        guard let configuration = activeConfiguration else { return }
        guard let converter = audioConverter, let desiredFormat = desiredFormat else { return }
        
        let frameCapacity = AVAudioFrameCount(configuration.frameDuration * configuration.sampleRate * 2)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: frameCapacity) else {
            print("[SpeechDetectionService][ERROR] processIncomingBuffer: Failed to allocate converted buffer")
            return
        }
        
        var error: NSError?
        var isInputConsumed = false
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus -> AVAudioBuffer? in
            if isInputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            isInputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        
        if status == .error || error != nil {
            let message = error?.localizedDescription ?? "Unknown"
            print("[SpeechDetectionService][ERROR] processIncomingBuffer: Conversion failed with error: \(message)")
            return
        }
        
        let frameLength = Int(convertedBuffer.frameLength)
        guard frameLength > 0, let channelData = convertedBuffer.floatChannelData else { return }
        
        if captureStartDate == nil {
            captureStartDate = approximateStartDate(for: audioTime, frameCount: frameLength, sampleRate: desiredFormat.sampleRate)
        }
        
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        appendSamples(samples, configuration: configuration)
    }
    
    private func appendSamples(_ samples: [Float], configuration: WhisperConfiguration) {
        guard !samples.isEmpty else { return }
        
        if sampleAccumulator.isEmpty {
            chunkBaseSampleIndex = processedSamples
        }
        
        sampleAccumulator.append(contentsOf: samples)
        processedSamples += samples.count
        
        let chunkFrames = configuration.chunkFrameCount
        let strideFrames = configuration.strideFrameCount
        
        while sampleAccumulator.count >= chunkFrames {
            let chunk = Array(sampleAccumulator.prefix(chunkFrames))
            let chunkStartSample = chunkBaseSampleIndex
            let chunkStartTime = Double(chunkStartSample) / configuration.sampleRate
            
            if strideFrames >= sampleAccumulator.count {
                sampleAccumulator.removeAll(keepingCapacity: true)
            } else {
                sampleAccumulator.removeFirst(strideFrames)
            }
            
            chunkBaseSampleIndex += strideFrames
            processChunk(chunk, startTime: chunkStartTime, configuration: configuration)
        }
    }
    
    private func processChunk(_ chunk: [Float], startTime: TimeInterval, configuration: WhisperConfiguration) {
        let processingStart = Date()
        let allowSilenceDecoding = silenceChunkAllowance > 0
        guard let output = whisperProcessor.process(samples: chunk, chunkStartTime: startTime, allowSilenceDecoding: allowSilenceDecoding) else { return }
        
        if output.speechDetected {
            let holdChunks = max(2, Int(ceil(0.6 / configuration.strideDuration)))
            silenceChunkAllowance = holdChunks
        } else if silenceChunkAllowance > 0 {
            silenceChunkAllowance -= 1
        }
        
        if !output.didDecode {
            print("[SpeechDetectionService] processChunk: Skipped decode for silence (allowanceRemaining=\(silenceChunkAllowance))")
            return
        }
        
        let latency = Date().timeIntervalSince(processingStart)
        updateMetrics(latency: latency, speechDetected: output.speechDetected, configuration: configuration)
        handleTranscriptions(output.results)
    }
    
    private func handleTranscriptions(_ results: [WhisperTranscriptionResult]) {
        guard !results.isEmpty else { return }
        let filtered = results.filter { $0.averageProbability >= detectionProbabilityThreshold }
        guard !filtered.isEmpty else { return }
        
        var triggeredVariations = Set<UUID>()
        for result in filtered {
            let sanitizedText = result.text.replacingOccurrences(of: "\n", with: " ")
            let probability = String(format: "%.2f", result.averageProbability)
            let startTime = String(format: "%.2f", result.startTime)
            let endTime = String(format: "%.2f", result.endTime)
            print("[SpeechDetectionService] handleTranscriptions: Candidate text=\"\(sanitizedText)\" start=\(startTime)s end=\(endTime)s probability=\(probability)")
            
            let matches = matcher.matches(in: result.text)
            guard !matches.isEmpty else { continue }
            
            for match in matches where !triggeredVariations.contains(match.variation.id) {
                triggeredVariations.insert(match.variation.id)
                fireActions(for: match, spokenTime: result.endTime)
            }
        }
    }
    
    private func fireActions(for match: KeywordDetectionMatch, spokenTime: TimeInterval) {
        guard let baseDate = captureStartDate else { return }
        let spokenDate = baseDate.addingTimeInterval(spokenTime)
        let spokenTimeString = notificationFormatter.string(from: spokenDate)
        print("[SpeechDetectionService] fireActions: Detected variation=\(match.variation.name) at \(spokenTimeString)")
        
        triggerZapIfNeeded(for: match.keyword)
        NotificationManager.sendDetectionNotification(for: match.keyword, variation: match.variation, spokenDate: spokenDate, deliveryDate: Date())
    }
    
    private func triggerZapIfNeeded(for keyword: Keyword) {
        let now = Date()
        if let last = lastZapDate, now.timeIntervalSince(last) < 10 {
            print("[SpeechDetectionService] triggerZapIfNeeded: Rate limited zap for keyword \(keyword.name)")
            return
        }
        
        PavlokService.shared.sendZap(for: keyword)
        zapCount += 1
        lastZapDate = now
        print("[SpeechDetectionService] triggerZapIfNeeded: Zap sent for keyword \(keyword.name) totalZaps=\(zapCount)")
    }
    
    private func updateMetrics(latency: TimeInterval, speechDetected: Bool, configuration: WhisperConfiguration) {
        let chunkStride = configuration.strideDuration
        if latency > 2 {
            consecutiveHighLatencyDuration += chunkStride
        } else {
            consecutiveHighLatencyDuration = 0
        }
        
        if consecutiveHighLatencyDuration >= 300 {
            if lastLatencyAlertDate == nil || Date().timeIntervalSince(lastLatencyAlertDate!) > 60 {
                let latencyMilliseconds = Int(latency * 1000)
                print("[SpeechDetectionService][ERROR] updateMetrics: Chunk latency high (\(latencyMilliseconds) ms) for over 5 minutes")
                lastLatencyAlertDate = Date()
            }
        }
        
        vadWindow.append(speechDetected)
        if vadWindow.count > 60 {
            vadWindow.removeFirst()
        }
        
        let vadActive = vadWindow.filter { $0 }.count
        let dutyCycle = vadWindow.isEmpty ? 0 : (Double(vadActive) / Double(vadWindow.count))
        let dutyPercent = dutyCycle * 100
        
        if vadWindow.count == 60 && dutyCycle > 0.6 {
            if lastVADDutyAlertDate == nil || Date().timeIntervalSince(lastVADDutyAlertDate!) > 60 {
                print("[SpeechDetectionService][ERROR] updateMetrics: VAD duty cycle elevated at \(String(format: "%.1f", dutyPercent))%")
                lastVADDutyAlertDate = Date()
            }
        }
        
        print("[SpeechDetectionService] updateMetrics: latency=\(String(format: "%.0f", latency * 1000))ms dutyCycle=\(String(format: "%.1f", dutyPercent))% speechDetected=\(speechDetected)")
        logBatteryIfNeeded()
    }
    
    private func logBatteryIfNeeded() {
        guard let start = metricsStartDate else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= 3600 else { return }
        
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
        }
        
        let currentLevel = device.batteryLevel
        if currentLevel < 0 || metricsBatteryLevel < 0 {
            print("[SpeechDetectionService][ERROR] logBatteryIfNeeded: Battery level unavailable for logging")
        } else {
            let delta = currentLevel - metricsBatteryLevel
            let perHour = delta / Float(elapsed / 3600)
            print("[SpeechDetectionService] logBatteryIfNeeded: Battery delta/hour=\(String(format: "%.2f", perHour)) zapCount=\(zapCount)")
        }
        
        metricsStartDate = Date()
        metricsBatteryLevel = device.batteryLevel
    }
    
    private func approximateStartDate(for audioTime: AVAudioTime, frameCount: Int, sampleRate: Double) -> Date {
        guard audioTime.isHostTimeValid else { return Date() }
        let hostSeconds = AVAudioTime.seconds(forHostTime: audioTime.hostTime)
        let duration = Double(frameCount) / sampleRate
        let bufferStartUptime = hostSeconds - duration
        let systemUptime = ProcessInfo.processInfo.systemUptime
        let delta = systemUptime - bufferStartUptime
        return Date(timeIntervalSinceNow: -delta)
    }
    
    private func registerAudioNotifications() {
        guard interruptionObserver == nil else { return }
        
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        routeObserver = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
        print("[SpeechDetectionService] registerAudioNotifications: Observers registered")
    }
    
    private func unregisterAudioNotifications() {
        let center = NotificationCenter.default
        if let observer = interruptionObserver {
            center.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = routeObserver {
            center.removeObserver(observer)
            routeObserver = nil
        }
        print("[SpeechDetectionService] unregisterAudioNotifications: Observers removed")
    }
    
    private func handleInterruption(_ notification: Notification) {
        guard isListening else { return }
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        
        switch type {
        case .began:
            print("[SpeechDetectionService] handleInterruption: Interruption began")
        case .ended:
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            print("[SpeechDetectionService] handleInterruption: Interruption ended shouldResume=\(options.contains(.shouldResume))")
            processingQueue.async {
                self.restartAudioEngine()
            }
        default:
            print("[SpeechDetectionService][ERROR] handleInterruption: Unknown interruption type received")
        }
    }
    
    private func handleRouteChange(_ notification: Notification) {
        guard isListening else { return }
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        
        print("[SpeechDetectionService] handleRouteChange: Reason=\(reason.rawValue)")
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .categoryChange:
            processingQueue.async {
                self.restartAudioEngine()
            }
        default:
            break
        }
    }
    
    private func restartAudioEngine() {
        guard let configuration = activeConfiguration else { return }
        audioEngine.stop()
        audioEngine.reset()
        do {
            try session.setActive(true, options: [])
        } catch {
            print("[SpeechDetectionService][ERROR] restartAudioEngine: Failed to reactivate audio session with error: \(error.localizedDescription)")
        }
        
        sampleAccumulator.removeAll(keepingCapacity: true)
        processedSamples = 0
        chunkBaseSampleIndex = 0
        captureStartDate = nil
        
        if !startAudioEngine(with: configuration) {
            print("[SpeechDetectionService][ERROR] restartAudioEngine: Failed to restart audio engine")
        } else {
            print("[SpeechDetectionService] restartAudioEngine: Audio engine restarted")
        }
    }
    
    func updatePreferredModel(size: ModelSize) {
        guard selectedModelSize != size else { return }
        selectedModelSize = size
        userDefaults.set(size.rawValue, forKey: modelPreferenceKey)
        NotificationCenter.default.post(name: .whisperModelPreferenceChanged, object: nil)
        print("[SpeechDetectionService] updatePreferredModel: Preferred model set to \(size)")
    }
    
    func startListening(completion: @escaping (Bool) -> Void) {
        if isListening {
            completion(true)
            return
        }
        
        session.requestRecordPermission { [weak self] granted in
            guard let self = self else { return }
            
            if !granted {
                print("[SpeechDetectionService][ERROR] startListening: Microphone permission denied")
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            
            self.processingQueue.async {
                let success = self.startInternal()
                DispatchQueue.main.async {
                    if success {
                        self.isListening = true
                        NotificationCenter.default.post(name: .speechDetectionStateChanged, object: nil)
                        print("[SpeechDetectionService] startListening: Listening started")
                    }
                    completion(success)
                }
            }
        }
    }
    
    func stopListening() {
        processingQueue.async {
            guard self.isListening else { return }
            self.stopInternal()
            DispatchQueue.main.async {
                self.isListening = false
                NotificationCenter.default.post(name: .speechDetectionStateChanged, object: nil)
                print("[SpeechDetectionService] stopListening: Listening stopped")
            }
        }
    }
}
