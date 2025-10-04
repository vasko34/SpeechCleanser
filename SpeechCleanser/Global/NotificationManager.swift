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

    static func sendDetectionNotification(for keyword: Keyword, variation: Variation, detectionDate: Date) {
        let content = UNMutableNotificationContent()
        content.title = "Keyword Detected"
        
        let detectionTime = detectionFormatter.string(from: detectionDate)
        content.body = "\(keyword.name) (variation: \(variation.name)) triggered a zap at \(detectionTime)."
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[NotificationManager][ERROR] sendDetectionNotification: Notification scheduling failed with error: \(error.localizedDescription)")
            } else {
                let notificationTime = detectionFormatter.string(from: Date())
                print("[NotificationManager] sendDetectionNotification: Send notification for keyword \(keyword.name) variation \(variation.name), detectionTime=\(detectionTime) notificationTime=\(notificationTime)")
            }
        }
    }
}
