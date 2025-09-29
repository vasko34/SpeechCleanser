//
//  KeywordStore.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import Foundation

final class KeywordStore {
    private init() {}
    static let shared = KeywordStore()
    
    private let defaultsKey = "custom_keywords_v1"
    private let userDefaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    static func fileURL(for filename: String) -> URL {
        documentsURL().appendingPathComponent(filename)
    }
    
    func load() -> [Keyword] {
        guard let data = userDefaults.data(forKey: defaultsKey) else { return [] }
        
        do {
            let decoded = try decoder.decode([Keyword].self, from: data)
            print("[KeywordStore] load: Loaded \(decoded.count) keywords")
            return decoded
        } catch {
            print("[KeywordStore][ERROR] load: KeywordStore load failed with error: \(error.localizedDescription)")
            return []
        }
    }
    
    func save(_ keywords: [Keyword]) {
        do {
            let data = try encoder.encode(keywords)
            userDefaults.set(data, forKey: defaultsKey)
            print("[KeywordStore] save: Stored \(keywords.count) keywords")
        } catch {
            print("[KeywordStore][ERROR] save: KeywordStore save failed with error: \(error.localizedDescription)")
        }
    }
}
