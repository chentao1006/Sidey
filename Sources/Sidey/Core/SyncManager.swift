import Foundation
import SwiftUI

class SyncManager: ObservableObject {
    static let shared = SyncManager()
    
    @AppStorage("isiCloudSyncEnabled") var isiCloudSyncEnabled = false
    @Published var lastSyncTime: Date?
    @Published var lastSyncStatus: String = ""
    
    private let kvs = NSUbiquitousKeyValueStore.default
    private let keysToSync = ["openAI_APIKey", "openAI_BaseURL", "alwaysOnTop", "showDockIcon", "windowOpacity", "sendBehavior", "autoPasteClipboard", "appLanguage", "hotKeyKeyCode", "hotKeyModifiers", "menuBarIcon"]
    
    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(externalChange), name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kvs)
        kvs.synchronize()
    }
    
    @objc private func externalChange(notification: Notification) {
        guard isiCloudSyncEnabled else { return }
        
        let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
        var meaningfulChange = false
        
        for key in changedKeys {
            if keysToSync.contains(key) {
                let val = kvs.object(forKey: key)
                UserDefaults.standard.set(val, forKey: key)
                meaningfulChange = true
            }
        }
        
        if changedKeys.contains("allPrompts_Sync") {
            if let data = kvs.data(forKey: "allPrompts_Sync"),
               let prompts = try? JSONDecoder().decode([Prompt].self, from: data) {
                DispatchQueue.main.async {
                    if PromptStore.shared.allPrompts != prompts {
                        PromptStore.shared.allPrompts = prompts
                        PromptStore.shared.savePrompts() // This will also write to local file
                    }
                }
            }
            meaningfulChange = true
        }
        
        if meaningfulChange {
            PromptStore.shared.savePrompts()
            DispatchQueue.main.async {
                self.lastSyncTime = Date()
                self.lastSyncStatus = "Cloud -> Local"
            }
        }
        
        // Handle special logic after sync (like hotkey registration)
        if changedKeys.contains("hotKeyKeyCode") || changedKeys.contains("hotKeyModifiers") {
            HotKeyManager.shared.registerHotkey()
        }
    }
    
    func syncToCloud() {
        guard isiCloudSyncEnabled else { return }
        
        for key in keysToSync {
            if let val = UserDefaults.standard.object(forKey: key) {
                kvs.set(val, forKey: key)
            }
        }
        kvs.synchronize()
        
        // Also update the external sync file if enabled
        PromptStore.shared.savePrompts()
        
        DispatchQueue.main.async {
            self.lastSyncTime = Date()
            self.lastSyncStatus = "Local -> Cloud"
        }
    }
    
    // Sync current prompts to cloud as well
    func syncPromptsToCloud(prompts: [Prompt]) {
        guard isiCloudSyncEnabled else { return }
        
        do {
            let data = try JSONEncoder().encode(prompts)
            if data.count < 100 * 1024 { // 100KB limit per key in KVS
                kvs.set(data, forKey: "allPrompts_Sync")
                kvs.synchronize()
                
                DispatchQueue.main.async {
                    self.lastSyncTime = Date()
                    self.lastSyncStatus = "Prompts -> Cloud"
                }
            } else {
                self.lastSyncStatus = "Error: Data too large"
            }
        } catch {
            print("Failed to sync prompts to cloud: \(error)")
            self.lastSyncStatus = "Error: Sync failed"
        }
    }
    
    func loadPromptsFromCloud() -> [Prompt]? {
        guard isiCloudSyncEnabled else { return nil }
        
        kvs.synchronize() // Force sync to fetch latest data before reading
        
        guard let data = kvs.data(forKey: "allPrompts_Sync") else {
            DispatchQueue.main.async {
                self.lastSyncTime = Date()
                self.lastSyncStatus = "No Prompts in Cloud"
            }
            return nil
        }
        
        do {
            let prompts = try JSONDecoder().decode([Prompt].self, from: data)
            DispatchQueue.main.async {
                self.lastSyncTime = Date()
                self.lastSyncStatus = "Prompts <- Cloud"
            }
            return prompts
        } catch {
            DispatchQueue.main.async {
                self.lastSyncTime = Date()
                self.lastSyncStatus = "Error: Invalid Data"
            }
            return nil
        }
    }
}
