//
//  NotificationManager.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 29.09.25.
//

import UserNotifications

enum NotificationManager {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification authorization error: \(error.localizedDescription)")
            } else {
                print("Notifications granted: \(granted)")
            }
        }
    }
    
    static func sendDetectionNotification(for keyword: Keyword) {
        let content = UNMutableNotificationContent()
        content.title = "Keyword Detected"
        
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        
        let time = formatter.string(from: Date())
        content.body = "\(keyword.name) triggered a zap at \(time)."
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Notification scheduling error: \(error.localizedDescription)")
            }
        }
    }
}
