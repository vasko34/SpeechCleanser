//
//  AudioManager.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import AVFoundation
import Accelerate

final class AudioManager {
    static let shared = AudioManager()
    
    private let keywordQueue = DispatchQueue(label: "AudioManager.keywordQueue", attributes: .concurrent)
    private let controlQueue = DispatchQueue(label: "AudioManager.controlQueue")
    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let detector = KeywordDetector()
    
    private var isRunning = false
    private var isStarting = false
    private var currentKeywords: [UUID: Keyword] = [:]
    private var currentSampleRate: Double = 44_100
    private var didLogChannelMix = false
    private var didLogMissingChannelData = false
    
    var onKeywordDetected: ((Keyword) -> Void)?
    var running: Bool { controlQueue.sync { isRunning } }
    
    private init() {
        detector.onDetection = { [weak self] keywordID, keywordName in
            guard let self = self else { return }
            guard let keyword = self.keyword(for: keywordID) else {
                print("[AudioManager][ERROR] init: Missing keyword for detection id \(keywordID.uuidString)")
                return
            }
            
            print("[AudioManager] init: Detected keyword \(keywordName)")
            self.onKeywordDetected?(keyword)
        }
    }
    
    private func keyword(for id: UUID) -> Keyword? {
        keywordQueue.sync { currentKeywords[id] }
    }
    
    func reloadKeywords(_ overrideKeywords: [Keyword]? = nil, sampleRate overrideRate: Double? = nil) {
        let keywords: [Keyword]
        if let overrideKeywords = overrideKeywords {
            keywords = overrideKeywords
        } else {
            keywords = KeywordStore.shared.load()
        }
        
        let resolvedSampleRate: Double
        
        if let overrideRate = overrideRate {
            resolvedSampleRate = overrideRate
        } else {
            resolvedSampleRate = controlQueue.sync { currentSampleRate }
        }
        
        keywordQueue.async(flags: .barrier) { [weak self] in
            self?.currentKeywords = Dictionary(uniqueKeysWithValues: keywords.map { ($0.id, $0) })
        }
        
        detector.configure(keywords: keywords, sampleRate: resolvedSampleRate)
        print("[AudioManager] reloadKeywords: Loaded \(keywords.count) keywords with sampleRate \(resolvedSampleRate)")
    }
    
    func start() {
        controlQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isRunning, !self.isStarting else {
                print("[AudioManager] start: Ignored start request because engine is already running")
                return
            }
            
            self.isStarting = true
            do {
                try self.session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
                try self.session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                self.isStarting = false
                print("[AudioManager][ERROR] start: AVAudioSession configuration failed with error: \(error.localizedDescription)")
                return
            }
            
            let input = self.engine.inputNode
            let format = input.outputFormat(forBus: 0)
            
            self.currentSampleRate = format.sampleRate
            self.didLogChannelMix = false
            self.didLogMissingChannelData = false
            self.reloadKeywords(sampleRate: format.sampleRate)
            print("[AudioManager] start: Installing tap with bufferSize 1024 sampleRate=\(format.sampleRate) channels=\(format.channelCount)")
            
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                let frameLength = Int(buffer.frameLength)
                guard let self = self else { return }
                guard frameLength > 0 else { return }
                guard let rawPointers = buffer.floatChannelData else {
                    if !self.didLogMissingChannelData {
                        self.didLogMissingChannelData = true
                        print("[AudioManager][ERROR] start: Missing channel data in audio buffer")
                    }
                    return
                }
                
                let channelCount = Int(buffer.format.channelCount)
                guard channelCount > 0 else {
                    if !self.didLogMissingChannelData {
                        self.didLogMissingChannelData = true
                        print("[AudioManager][ERROR] start: Invalid channel count detected in audio buffer")
                    }
                    return
                }
                
                let channels = UnsafeBufferPointer(start: rawPointers, count: channelCount)
                var samples: [Float]
                if channelCount == 1, let firstChannel = channels.first {
                    samples = Array(UnsafeBufferPointer(start: firstChannel, count: frameLength))
                } else {
                    if !self.didLogChannelMix {
                        self.didLogChannelMix = true
                        print("[AudioManager] start: Mixing \(channelCount) channels for keyword detection")
                    }
                    
                    samples = [Float](repeating: 0, count: frameLength)
                    samples.withUnsafeMutableBufferPointer { bufferPointer in
                        guard let destination = bufferPointer.baseAddress else { return }
                        vDSP_vclr(destination, 1, vDSP_Length(frameLength))
                        
                        for index in 0..<channelCount {
                            let source = channels[index]
                            vDSP_vadd(source, 1, destination, 1, destination, 1, vDSP_Length(frameLength))
                        }
                        
                        if channelCount > 1 {
                            var divisor = Float(channelCount)
                            vDSP_vsdiv(destination, 1, &divisor, destination, 1, vDSP_Length(frameLength))
                        }
                    }
                }
                
                var sum: Float = 0
                samples.withUnsafeBufferPointer { pointer in
                    guard let baseAddress = pointer.baseAddress else { return }
                    vDSP_measqv(baseAddress, 1, &sum, vDSP_Length(frameLength))
                }
                
                let rms = sqrtf(sum)
                self.detector.process(samples: samples, level: rms)
                
                if self.didLogMissingChannelData {
                    self.didLogMissingChannelData = false
                }
            }
            
            self.engine.prepare()
            do {
                try self.engine.start()
                self.isRunning = true
                DispatchQueue.main.async {
                    print("[AudioManager] start: Engine started")
                }
            } catch {
                self.isRunning = false
                print("[AudioManager][ERROR] start: AVAudioEngine failed to start engine with error: \(error.localizedDescription)")
            }
            
            self.isStarting = false
        }
    }
    
    func stop() {
        controlQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isRunning || self.isStarting else {
                print("[AudioManager] stop: Ignored stop request because engine is not running")
                return
            }
            
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            
            do {
                try self.session.setActive(false)
            } catch {
                print("[AudioManager][ERROR] stop: AVAudioSession failed to setActive with error: \(error.localizedDescription)")
            }
            
            self.isRunning = false
            self.isStarting = false
            DispatchQueue.main.async {
                print("[AudioManager] stop: Engine stopped")
            }
        }
    }
}
