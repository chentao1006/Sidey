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
    
    func requestAuthorization() {
        if self.isBundledApp {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if granted {
                    print("Notification permission granted.")
                } else if let error = error {
                    print("Notification permission error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func sendNotification(title: String, body: String, bundleID: String, promptID: String) {
        if self.isBundledApp {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = [
                "bundleID": bundleID,
                "promptID": promptID
            ]
            
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("Error adding notification: \(error.localizedDescription)")
                }
            }
        } else {
            // Fallback for SwiftPM direct execution or unbundled runs avoiding UNUserNotificationCenter crashes
            let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")
            let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")
            
            let script = """
            display notification "\(escapedBody)" with title "\(escapedTitle)" sound name "Glass"
            """
            
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                if let appleScript = NSAppleScript(source: script) {
                    appleScript.executeAndReturnError(&error)
                }
            }
        }
    }
    
    // UNUserNotificationCenterDelegate
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        
        if let bundleID = userInfo["bundleID"] as? String {
            if let targetApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                if bundleID != Bundle.main.bundleIdentifier {
                    targetApp.activate(options: .activateIgnoringOtherApps)
                }
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                    appDelegate.showAssistant()
                }
                
                if let promptID = userInfo["promptID"] as? String {
                    NotificationCenter.default.post(
                        name: Notification.Name("CXAISwitchSession"),
                        object: nil,
                        userInfo: ["bundleID": bundleID, "promptID": promptID]
                    )
                }
            }
        }
        
        completionHandler()
    }
}
