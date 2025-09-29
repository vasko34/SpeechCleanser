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
    }
    
    let id: UUID
    let filePath: String
    let duration: TimeInterval
    let fingerprint: [Float]

    init(id: UUID = UUID(), filePath: String, duration: TimeInterval, fingerprint: [Float]) {
        self.id = id
        self.filePath = filePath
        self.duration = duration
        self.fingerprint = fingerprint
    }
    
    init(from decoder: Decoder) {
        var decodedID = UUID()
        var decodedFilePath = ""
        var decodedDuration: TimeInterval = 0
        var decodedFingerprint: [Float] = []
        
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try container.decodeIfPresent(UUID.self, forKey: .id) {
                decodedID = value
            }
            
            decodedFilePath = try container.decode(String.self, forKey: .filePath)
            decodedDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
            decodedFingerprint = try container.decodeIfPresent([Float].self, forKey: .fingerprint) ?? []
        } catch {
            print("[Variation][ERROR] initFromDecoder: Decoder failed with error: \(error.localizedDescription)")
        }
        
        id = decodedID
        filePath = decodedFilePath
        duration = decodedDuration
        fingerprint = decodedFingerprint
    }
    
    func encode(to encoder: Encoder) {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        do {
            try container.encode(id, forKey: .id)
            try container.encode(filePath, forKey: .filePath)
            try container.encode(duration, forKey: .duration)
            try container.encode(fingerprint, forKey: .fingerprint)
        } catch {
            print("[Variation][ERROR] encode: Encoder failed with error: \(error.localizedDescription)")
        }
    }
}
