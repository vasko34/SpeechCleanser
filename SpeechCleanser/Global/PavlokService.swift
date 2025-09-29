//
//  PavlokService.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import Foundation

final class PavlokService {
    private init() {}
    static let shared = PavlokService()
    
    private let defaults = UserDefaults.standard
    private let apiKeyKey = "pavlok_api_key"
    private let intensityKey = "pavlok_intensity"
    
    var apiKey: String? {
        get { defaults.string(forKey: apiKeyKey) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: apiKeyKey)
            } else {
                defaults.removeObject(forKey: apiKeyKey)
            }
        }
    }
    
    var intensity: Int {
        get {
            let stored = defaults.integer(forKey: intensityKey)
            return stored == 0 ? 50 : stored
        }
        set {
            let clamped = max(10, min(100, newValue))
            defaults.set(clamped, forKey: intensityKey)
        }
    }
    
    func sendZap(for keyword: Keyword) {
        guard let token = apiKey, !token.isEmpty else {
            print("PavlokService: API key missing, skipping zap")
            return
        }
        
        var request = URLRequest(url: URL(string: "https://app.pavlok.com/api/v1/stimulus")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let payload: [String: Any] = [
            "stimulus": "zap",
            "intensity": intensity,
            "reason": "Keyword detected: \(keyword.name)"
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            print("PavlokService JSON encoding error: \(error.localizedDescription)")
            return
        }
        
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("PavlokService request error: \(error.localizedDescription)")
                return
            }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("PavlokService unexpected status:", http.statusCode)
            }
        }.resume()
    }
}
