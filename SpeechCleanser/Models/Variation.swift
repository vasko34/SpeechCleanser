//
//  Variation.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import Foundation

struct Variation: Codable, Equatable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id
        case filePath
        case duration
        case fingerprint
        case rms
        case analysisSampleRate
        case analysisWindowSize
        case analysisHopSize
    }
    
    let id: UUID
    let filePath: String
    let duration: TimeInterval
    let fingerprint: [Float]
    let rms: Float
    let analysisSampleRate: Double
    let analysisWindowSize: Int
    let analysisHopSize: Int

    init(id: UUID = UUID(), filePath: String, duration: TimeInterval, fingerprint: [Float], rms: Float, analysisSampleRate: Double, analysisWindowSize: Int, analysisHopSize: Int) {
        self.id = id
        self.filePath = filePath
        self.duration = duration
        self.fingerprint = fingerprint
        self.rms = rms
        self.analysisSampleRate = analysisSampleRate
        self.analysisWindowSize = analysisWindowSize
        self.analysisHopSize = analysisHopSize
    }
    
    init(from decoder: Decoder) {
        var decodedID = UUID()
        var decodedFilePath = ""
        var decodedDuration: TimeInterval = 0
        var decodedFingerprint: [Float] = []
        var decodedRMS: Float = 0
        var decodedSampleRate = AudioFingerprint.defaultSampleRate
        var decodedWindowSize = max(1, Int(AudioFingerprint.defaultSampleRate * AudioFingerprint.defaultWindowDuration))
        var decodedHopSize = max(1, Int(AudioFingerprint.defaultSampleRate * AudioFingerprint.defaultHopDuration))
        
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try container.decodeIfPresent(UUID.self, forKey: .id) {
                decodedID = value
            }
            
            decodedFilePath = try container.decode(String.self, forKey: .filePath)
            decodedDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
            decodedFingerprint = try container.decodeIfPresent([Float].self, forKey: .fingerprint) ?? []
            decodedRMS = try container.decodeIfPresent(Float.self, forKey: .rms) ?? decodedRMS
            decodedSampleRate = try container.decodeIfPresent(Double.self, forKey: .analysisSampleRate) ?? decodedSampleRate
            decodedWindowSize = try container.decodeIfPresent(Int.self, forKey: .analysisWindowSize) ?? decodedWindowSize
            decodedHopSize = try container.decodeIfPresent(Int.self, forKey: .analysisHopSize) ?? decodedHopSize

        } catch {
            print("[Variation][ERROR] initFromDecoder: Decoder failed with error: \(error.localizedDescription)")
        }
        
        id = decodedID
        filePath = decodedFilePath
        duration = decodedDuration
        fingerprint = decodedFingerprint
        rms = decodedRMS
        analysisSampleRate = decodedSampleRate
        analysisWindowSize = decodedWindowSize
        analysisHopSize = decodedHopSize
    }
    
    func encode(to encoder: Encoder) {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        do {
            try container.encode(id, forKey: .id)
            try container.encode(filePath, forKey: .filePath)
            try container.encode(duration, forKey: .duration)
            try container.encode(fingerprint, forKey: .fingerprint)
            try container.encode(rms, forKey: .rms)
            try container.encode(analysisSampleRate, forKey: .analysisSampleRate)
            try container.encode(analysisWindowSize, forKey: .analysisWindowSize)
            try container.encode(analysisHopSize, forKey: .analysisHopSize)
        } catch {
            print("[Variation][ERROR] encode: Encoder failed with error: \(error.localizedDescription)")
        }
    }
}
