//
//  ModelSize.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 10.10.25.
//

import Foundation

enum ModelSize: String, CaseIterable, Codable {
    case medium
    case large
    
    var resourceName: String {
        switch self {
        case .medium:
            return "ggml-medium-q5_0"
        case .large:
            return "ggml-large-v2-q5_0"
        }
    }
}
