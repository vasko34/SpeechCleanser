//
//  Keyword.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import Foundation

struct Keyword: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var variations: [Variation]
    
    init(id: UUID = UUID(), name: String, isEnabled: Bool = true, variations: [Variation] = []) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.variations = variations
    }
}
