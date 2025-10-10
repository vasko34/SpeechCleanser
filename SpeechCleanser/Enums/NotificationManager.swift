//
//  NotificationManager.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import UserNotifications

enum NotificationManager {
    private static let detectionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "bg_BG")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("[NotificationManager][ERROR] requestAuthorization: Notification authorization failed with error: \(error.localizedDescription)")
            } else if granted {
                print("[NotificationManager] requestAuthorization: Notifications granted: true")
            } else {
                print("[NotificationManager][ERROR] requestAuthorization: Notifications denied by user")
            }
        }
    }

    static func sendDetectionNotification(for keyword: Keyword, variation: Variation, spokenDate: Date, deliveryDate: Date = Date()) {
        let content = UNMutableNotificationContent()
        content.title = "Keyword Detected"
        
        let spokenTime = detectionFormatter.string(from: spokenDate)
        content.body = "Keyword: \(keyword.name), Variation: \(variation.name) – spoken at: \(spokenTime)"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[NotificationManager][ERROR] sendDetectionNotification: Notification scheduling failed with error: \(error.localizedDescription)")
            } else {
                let sendTime = detectionFormatter.string(from: deliveryDate)
                print("[NotificationManager] sendDetectionNotification: Scheduled notification for keyword=\(keyword.name) variation=\(variation.name) spokenTime=\(spokenTime) sendTime=\(sendTime)")
            }
        }
    }
}
