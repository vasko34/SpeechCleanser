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
    
    var onAudioLevel: ((Float) -> Void)?
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
            self.reloadKeywords(sampleRate: format.sampleRate)
            print("[AudioManager] start: Installing tap with bufferSize 1024 at sampleRate \(format.sampleRate)")
            
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self = self else { return }
                
                let channelData = buffer.floatChannelData?[0]
                let frameLength = Int(buffer.frameLength)
                var rms: Float = 0
                if let data = channelData, frameLength > 0 {
                    var sum: Float = 0
                    vDSP_measqv(data, 1, &sum, vDSP_Length(frameLength))
                    rms = sqrtf(sum)
                    
                    let samples = Array(UnsafeBufferPointer(start: data, count: frameLength))
                    self.detector.process(samples: samples, level: rms)
                }
                self.onAudioLevel?(rms)
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
