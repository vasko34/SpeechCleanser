//
//  Variation.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import Foundation

struct Variation: Codable, Equatable, Identifiable {
    let id: UUID
    let filePath: String
    
    init(id: UUID = UUID(), filePath: String, duration: TimeInterval) {
        self.id = id
        self.filePath = filePath
    }
}
