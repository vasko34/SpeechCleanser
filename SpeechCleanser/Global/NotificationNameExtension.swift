//
//  NotificationNameExtension.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 3.10.25.
//

import Foundation

extension Notification.Name {
    static let speechDetectionStateChanged = Notification.Name("SpeechDetectionServiceStateChanged")
    static let keywordStoreDidChange = Notification.Name("KeywordStoreDidChangeNotification")
}
