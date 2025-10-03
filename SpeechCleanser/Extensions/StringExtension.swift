//
//  StringExtension.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import Foundation

extension String {
    func normalizedForKeywordMatching() -> String {
        let locale = Locale(identifier: "bg_BG")
        let folded = folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale).lowercased(with: locale)
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " "))
        var filtered = ""
        filtered.reserveCapacity(folded.count)
        
        for character in folded {
            var isAllowed = true
            for scalar in character.unicodeScalars {
                if !allowed.contains(scalar) {
                    isAllowed = false
                    break
                }
            }
            
            if isAllowed {
                filtered.append(character)
            } else {
                filtered.append(" ")
            }
        }
        
        let components = filtered.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
        return components.joined(separator: " ")
    }
}
