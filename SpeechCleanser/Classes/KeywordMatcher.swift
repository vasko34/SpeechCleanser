//
//  KeywordMatcher.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 10.10.25.
//

import Foundation

class KeywordMatcher {
    private let locale = Locale(identifier: "bg_BG")
    private let whitespace = CharacterSet.whitespacesAndNewlines
    
    func matches(in text: String, keywords: [Keyword]) -> [KeywordDetectionMatch] {
        let enabledKeywords = keywords.filter { $0.isEnabled }
        guard !enabledKeywords.isEmpty else { return [] }
        
        let normalizedText = normalize(text)
        guard !normalizedText.isEmpty else { return [] }
        
        let tokens = tokenized(normalizedText)
        var results: [KeywordDetectionMatch] = []
        
        for keyword in enabledKeywords {
            for variation in keyword.variations {
                let normalizedVariation = normalize(variation.name)
                guard !normalizedVariation.isEmpty else { continue }
                
                if normalizedText.contains(normalizedVariation) {
                    results.append(KeywordDetectionMatch(keyword: keyword, variation: variation))
                    continue
                }
                
                if fuzzyMatch(variation: normalizedVariation, in: tokens) {
                    results.append(KeywordDetectionMatch(keyword: keyword, variation: variation))
                }
            }
        }
        
        return results
    }
    
    private func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: whitespace)
        guard !trimmed.isEmpty else { return "" }
        
        let lowered = trimmed.lowercased(with: locale)
        let folded = lowered.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(folded.unicodeScalars.count)
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        
        for scalar in folded.unicodeScalars {
            scalars.append(allowed.contains(scalar) ? scalar : " ")
        }
        
        let normalized = String(String.UnicodeScalarView(scalars))
        let collapsedSpaces = normalized.replacingOccurrences(of: "  ", with: " ")
        return collapsedSpaces.trimmingCharacters(in: whitespace)
    }
    
    private func tokenized(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }
    
    private func fuzzyMatch(variation: String, in tokens: [String]) -> Bool {
        let variationTokens = tokenized(variation)
        guard !variationTokens.isEmpty else { return false }
        
        if variationTokens.count == 1 {
            let target = variationTokens[0]
            for token in tokens {
                if token == target || levenshteinDistance(between: token, and: target) <= 1 {
                    return true
                }
            }
            return false
        }
        
        let length = variationTokens.count
        guard tokens.count >= length else { return false }
        
        for index in 0...(tokens.count - length) {
            let window = tokens[index..<(index + length)].joined(separator: " ")
            if window == variation || levenshteinDistance(between: window, and: variation) <= 1 {
                return true
            }
        }
        
        return false
    }
    
    private func levenshteinDistance(between lhs: String, and rhs: String) -> Int {
        if lhs == rhs { return 0 }
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        var previousRow = Array(0...rhsChars.count)
        var currentRow = Array(repeating: 0, count: rhsChars.count + 1)
        
        for (i, lhsChar) in lhsChars.enumerated() {
            currentRow[0] = i + 1
            
            for (j, rhsChar) in rhsChars.enumerated() {
                let insertion = currentRow[j] + 1
                let deletion = previousRow[j + 1] + 1
                let substitution = previousRow[j] + (lhsChar == rhsChar ? 0 : 1)
                currentRow[j + 1] = min(insertion, deletion, substitution)
            }
            
            previousRow = currentRow
        }
        
        return previousRow[rhsChars.count]
    }
}
