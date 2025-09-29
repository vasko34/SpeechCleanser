//
//  AudioManager.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import UIKit
import AVFoundation
import Accelerate

final class AudioManager {
    static let shared = AudioManager()
    
    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let detector = KeywordDetector()
    
    private var isRunning = false
    private var currentKeywords: [UUID: Keyword] = [:]
    private var currentSampleRate: Double = 44_100
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    var onAudioLevel: ((Float) -> Void)?
    var onKeywordDetected: ((Keyword) -> Void)?
    var running: Bool { isRunning }
    
    private init() {
        detector.onDetection = { [weak self] keywordID, _ in
            guard let keyword = self?.currentKeywords[keywordID] else { return }
            self?.onKeywordDetected?(keyword)
        }
    }
    
    private func beginBackgroundTask() {
        DispatchQueue.main.async { [weak self] in
            guard self?.backgroundTask == .invalid else { return }
            
            self?.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AudioDetection") {
                self?.endBackgroundTask()
            }
        }
    }
    
    private func endBackgroundTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if self.backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
    }
    
    func reloadKeywords() {
        let keywords = KeywordStore.shared.load()
        currentKeywords = Dictionary(uniqueKeysWithValues: keywords.map { ($0.id, $0) })
        detector.configure(keywords: keywords, sampleRate: currentSampleRate)
    }
    
    func start() {
        guard !isRunning else { return }
        
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("AVAudioSession configuration failed with error: \(error.localizedDescription)")
        }
        
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        
        currentSampleRate = format.sampleRate
        reloadKeywords()
        
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
                self.detector.process(samples: samples)
            }
            self.onAudioLevel?(rms)
        }
        
        engine.prepare()
        
        do {
            try engine.start()
            beginBackgroundTask()
        } catch {
            print("AVAudioEngine failed to start engine with error: \(error.localizedDescription)")
        }
        
        isRunning = true
    }
    
    func stop() {
        guard isRunning else { return }
        
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        
        do {
            try session.setActive(false)
        } catch {
            print("AVAudioSession failed to setActive with error: \(error.localizedDescription)")
        }
        
        endBackgroundTask()
        isRunning = false
    }
}
