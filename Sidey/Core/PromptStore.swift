import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct Prompt: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var system: String
    var apps: [String]
}

struct SyncData: Codable {
    var prompts: [Prompt]
    var settings: [String: String]?
}

class PromptStore: ObservableObject {
    static let shared = PromptStore()
    
    @Published var allPrompts: [Prompt] = []
    @Published var editingPromptID: String? = nil
    
    @AppStorage("isiCloudSyncEnabled") var isiCloudSyncEnabled = false
    
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var isInitialLoading = false
    
    private var fileURL: URL {
        // 1. Try App's iCloud Container (Standard Sandbox way)
        if isiCloudSyncEnabled, let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") {
            if !FileManager.default.fileExists(atPath: iCloudURL.path) {
                try? FileManager.default.createDirectory(at: iCloudURL, withIntermediateDirectories: true, attributes: nil)
            }
            return iCloudURL.appendingPathComponent("settings.json")
        }
        
        // 2. Fallback to local Application Support (Sandboxed path)
        let fileManager = FileManager.default
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appDir = appSupport.appendingPathComponent("Sidey", isDirectory: true)
            if !fileManager.fileExists(atPath: appDir.path) {
                try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
            }
            return appDir.appendingPathComponent("settings.json")
        }
        
        // Absolute fallback
        return fileManager.temporaryDirectory.appendingPathComponent("settings.json")
    }
    
    init() {
        loadPrompts()
        setupFileWatcher()
    }
    
    func setupFileWatcher() {
        fileWatcher?.cancel()
        
        let url = fileURL
        let descriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor != -1 else { return }
        
        fileWatcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        fileWatcher?.setEventHandler { [weak self] in
            // Files in the directory changed, reload prompts if file was updated
            self?.loadPrompts()
        }
        fileWatcher?.setCancelHandler {
            close(descriptor)
        }
        fileWatcher?.resume()
    }
    
    private var settingsKeys: [String] {
        ["openAI_APIKey", "openAI_BaseURL", "openAI_Model", "alwaysOnTop", "showDockIcon", "windowOpacity", "sendBehavior", "appLanguage", "hotKeyKeyCode", "hotKeyModifiers", "menuBarIcon"]
    }
    
    func loadPrompts() {
        guard !isInitialLoading else { return }
        
        let url = fileURL
        isInitialLoading = true
        
        // 1. If remote/local file exists, strictly read it
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode(SyncData.self, from: data)
                
                DispatchQueue.main.async {
                    self.isInitialLoading = false
                    if let settings = decoded.settings {
                        self.applySettings(settings)
                    }
                    
                    if self.allPrompts != decoded.prompts {
                        self.allPrompts = decoded.prompts
                    }
                }
            } catch {
                print("Error parsing sync file: \(error)")
                isInitialLoading = false
            }
            return
        }
        
        // 2. If file does NOT exist, handle migration or initialize with local data
        let syncOldURL = url.deletingLastPathComponent().appendingPathComponent("sidey_sync.json")
        let promptsOldURL = url.deletingLastPathComponent().appendingPathComponent("prompts.json")
        
        if FileManager.default.fileExists(atPath: syncOldURL.path) {
            try? FileManager.default.moveItem(at: syncOldURL, to: url)
            isInitialLoading = false
            self.loadPrompts() // call again to perform actual load
        } else if FileManager.default.fileExists(atPath: promptsOldURL.path) {
            try? FileManager.default.moveItem(at: promptsOldURL, to: url)
            isInitialLoading = false
            self.loadPrompts() // call again to perform actual load
        } else {
            // Folder is empty. Check if we have local work to persist to this new storage.
            if !allPrompts.isEmpty {
                // Initialize new storage with current local state
                isInitialLoading = false
                self.savePrompts()
            } else if let bundleURL = Bundle.sideyModule.url(forResource: "prompts", withExtension: "json") {
                // True fresh start: copy bundle to folder.
                try? FileManager.default.copyItem(at: bundleURL, to: url)
                isInitialLoading = false
                self.loadPrompts()
            } else {
                isInitialLoading = false
            }
        }
    }
    
    private func applySettings(_ settings: [String: String]) {
        var changed = false
        for (key, value) in settings {
            let current = "\(UserDefaults.standard.object(forKey: key) ?? "")"
            if current != value {
                if key == "alwaysOnTop" || key == "showDockIcon" {
                    UserDefaults.standard.set(value == "1" || value.lowercased() == "true", forKey: key)
                } else if key == "windowOpacity" {
                    UserDefaults.standard.set(Double(value) ?? 1.0, forKey: key)
                } else if key == "hotKeyKeyCode" || key == "hotKeyModifiers" {
                    UserDefaults.standard.set(Int(value) ?? 0, forKey: key)
                } else {
                    UserDefaults.standard.set(value, forKey: key)
                }
                changed = true
            }
        }
        if changed {
            if settings.keys.contains("hotKeyKeyCode") || settings.keys.contains("hotKeyModifiers") {
                HotKeyManager.shared.registerHotkey()
            }
        }
    }
    
    func savePrompts() {
        guard !isInitialLoading else { return }
        
        var settings: [String: String] = [:]
        for key in settingsKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                settings[key] = "\(value)"
            }
        }
        
        let syncData = SyncData(prompts: allPrompts, settings: settings)
        do {
            let url = fileURL
            let data = try JSONEncoder().encode(syncData)
            try data.write(to: url)
            
            // Automatically push to cloud KVS (legacy/backup)
            SyncManager.shared.syncPromptsToCloud(prompts: allPrompts)
            
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        } catch {
            print("Failed to save sync data: \(error)")
        }
    }
    
    // Backup & Restore
    struct BackupData: Codable {
        var prompts: [Prompt]
        var settings: [String: String]
    }
    
    func exportBackup() -> URL? {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "Sidey_Backup_\(Int(Date().timeIntervalSince1970)).json"
        
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return nil }
        
        let settingsKeys = self.settingsKeys
        var settings: [String: String] = [:]
        for key in settingsKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                settings[key] = "\(value)"
            }
        }
        
        let backup = BackupData(prompts: allPrompts, settings: settings)
        do {
            let data = try JSONEncoder().encode(backup)
            try data.write(to: url)
            return url
        } catch {
            print("Export failed: \(error)")
            return nil
        }
    }
    
    func importBackup() -> Bool {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowedContentTypes = [.json]
        
        guard openPanel.runModal() == .OK, let url = openPanel.url else { return false }
        
        do {
            let data = try Data(contentsOf: url)
            let backup = try JSONDecoder().decode(BackupData.self, from: data)
            
            // Restore Settings
            for (key, value) in backup.settings {
                if key == "alwaysOnTop" || key == "showDockIcon" {
                    UserDefaults.standard.set(value == "1" || value.lowercased() == "true", forKey: key)
                } else if key == "windowOpacity" {
                    UserDefaults.standard.set(Double(value) ?? 1.0, forKey: key)
                } else if key == "hotKeyKeyCode" || key == "hotKeyModifiers" {
                    UserDefaults.standard.set(Int(value) ?? 0, forKey: key)
                } else {
                    UserDefaults.standard.set(value, forKey: key)
                }
            }
            
            // Restore Prompts
            DispatchQueue.main.async {
                self.allPrompts = backup.prompts
                self.savePrompts()
                self.objectWillChange.send()
            }
            return true
        } catch {
            print("Import failed: \(error)")
            return false
        }
    }
    
    func getPrompts(for bundleID: String) -> [Prompt] {
        let matching = allPrompts.filter { prompt in
            prompt.apps.contains("*") || prompt.apps.contains(bundleID)
        }
        
        let specific = matching.filter { !$0.apps.contains("*") }
        let global = matching.filter { $0.apps.contains("*") }
        
        return specific + global
    }
}
