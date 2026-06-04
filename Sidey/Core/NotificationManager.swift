import AppKit
import UserNotifications

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private var isBundledApp: Bool = false
    
    override private init() {
        super.init()
        let bundleID = Bundle.main.bundleIdentifier
        // Check if there's a valid bundle identifier not belonging to Xcode / SwiftPM test environments
        self.isBundledApp = (bundleID != nil && !bundleID!.isEmpty && !bundleID!.starts(with: "com.apple.dt."))
        
        if self.isBundledApp {
            UNUserNotificationCenter.current().delegate = self
        }
    }
    
    func sendNotification(title: String, body: String, bundleID: String, promptID: String) {
        guard self.isBundledApp else {
            DebugLogger.shared.log("Notification skipped because the app is not running from a bundle.", type: .error)
            return
        }
        
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }
            DebugLogger.shared.log("Notification status before send: \(self.authorizationStatusDescription(settings.authorizationStatus))", type: .info)
            
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.enqueueNotification(title: title, body: body, bundleID: bundleID, promptID: promptID)
            case .notDetermined:
                self.requestAuthorizationForNotification {
                    self.enqueueNotification(title: title, body: body, bundleID: bundleID, promptID: promptID)
                }
            case .denied:
                DebugLogger.shared.log("Notification skipped because permission is denied.", type: .error)
            @unknown default:
                DebugLogger.shared.log("Notification skipped because permission status is unknown.", type: .error)
            }
        }
    }
    
    private func requestAuthorizationForNotification(onGranted: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if granted {
                    DebugLogger.shared.log("Notification permission granted.", type: .info)
                    onGranted?()
                } else if let error = error {
                    DebugLogger.shared.log("Notification permission error: \(error.localizedDescription)", type: .error)
                } else {
                    DebugLogger.shared.log("Notification permission not granted.", type: .error)
                }
            }
        }
    }
    
    private func enqueueNotification(title: String, body: String, bundleID: String, promptID: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = notificationPreview(from: body)
        content.sound = .default
        content.userInfo = [
            "bundleID": bundleID,
            "promptID": promptID
        ]
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                DebugLogger.shared.log("Error adding notification: \(error.localizedDescription)", type: .error)
            } else {
                DebugLogger.shared.log("Notification enqueued for \(bundleID)|\(promptID).", type: .info)
            }
        }
    }
    
    private func authorizationStatusDescription(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
    
    private func notificationPreview(from body: String) -> String {
        let singleLine = body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard singleLine.count > 180 else { return singleLine }
        return String(singleLine.prefix(180)) + "..."
    }
    
    // UNUserNotificationCenterDelegate
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        
        if let bundleID = userInfo["bundleID"] as? String,
           let promptID = userInfo["promptID"] as? String {
            DebugLogger.shared.log("Notification clicked for \(bundleID)|\(promptID).", type: .info)
            DispatchQueue.main.async {
                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                    appDelegate.openAssistant(bundleID: bundleID, promptID: promptID)
                } else {
                    DebugLogger.shared.log("Notification click ignored because AppDelegate is unavailable.", type: .error)
                }
            }
        } else {
            DebugLogger.shared.log("Notification click ignored because bundleID or promptID is missing.", type: .error)
        }
        
        completionHandler()
    }
}
