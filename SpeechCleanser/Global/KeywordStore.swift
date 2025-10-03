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
    private let notificationCenter = NotificationCenter.default
    
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
            userDefaults.removeObject(forKey: defaultsKey)
            print("[KeywordStore] load: Cleared persisted keyword data due to decode failure")
            
            return []
        }
    }
    
    func save(_ keywords: [Keyword]) {
        do {
            let data = try encoder.encode(keywords)
            userDefaults.set(data, forKey: defaultsKey)
            print("[KeywordStore] save: Stored \(keywords.count) keywords")
            notificationCenter.post(name: .keywordStoreDidChange, object: nil)
        } catch {
            print("[KeywordStore][ERROR] save: KeywordStore save failed with error: \(error.localizedDescription)")
        }
    }
    
    func update(_ keyword: Keyword) {
        var all = load()
        if let index = all.firstIndex(where: { $0.id == keyword.id }) {
            all[index] = keyword
            save(all)
            print("[KeywordStore] update: Updated keyword \(keyword.name)")
        } else {
            print("[KeywordStore][ERROR] update: Keyword \(keyword.name) not found for update")
        }
    }
    
    func deleteKeyword(withID id: UUID) {
        var all = load()
        let initialCount = all.count
        all.removeAll { $0.id == id }
        if all.count != initialCount {
            save(all)
            print("[KeywordStore] deleteKeyword: Removed keyword with id \(id.uuidString)")
        } else {
            print("[KeywordStore][ERROR] deleteKeyword: Keyword with id \(id.uuidString) not found")
        }
    }
}
