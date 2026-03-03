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
    
    @AppStorage("isFileSyncEnabled") var isFileSyncEnabled = false
    @AppStorage("customSyncBookmark") private var customSyncBookmarkData = Data()
    
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var currentAccessingURL: URL? = nil
    
    private var fileURL: URL {
        // 1. Try Custom Sync Folder via Bookmark (User selected)
        if !customSyncBookmarkData.isEmpty {
            let bookmarkData = customSyncBookmarkData
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                if isStale {
                    // Update stale bookmark if possible
                    updateBookmark(for: url)
                }
                if url.startAccessingSecurityScopedResource() {
                    currentAccessingURL = url
                    return url.appendingPathComponent("sidey_sync.json")
                }
            } catch {
                print("Failed to resolve bookmark: \(error)")
            }
        }

        // 2. Try App's iCloud Container (Standard Sandbox way)
        if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") {
            if !FileManager.default.fileExists(atPath: iCloudURL.path) {
                try? FileManager.default.createDirectory(at: iCloudURL, withIntermediateDirectories: true, attributes: nil)
            }
            return iCloudURL.appendingPathComponent("sidey_sync.json")
        }
        
        // 3. Fallback to local Application Support (Sandboxed path)
        let fileManager = FileManager.default
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appDir = appSupport.appendingPathComponent("Sidey", isDirectory: true)
            if !fileManager.fileExists(atPath: appDir.path) {
                try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
            }
            return appDir.appendingPathComponent("sidey_sync.json")
        }
        
        // Absolute fallback
        return fileManager.temporaryDirectory.appendingPathComponent("sidey_sync.json")
    }
    
    func updateBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            customSyncBookmarkData = data
            UserDefaults.standard.set(url.path, forKey: "customSyncPath")
        } catch {
            print("Failed to update bookmark: \(error)")
        }
    }
    
    private func stopAccessing() {
        currentAccessingURL?.stopAccessingSecurityScopedResource()
        currentAccessingURL = nil
    }
    
    init() {
        loadPrompts()
        setupFileWatcher()
    }
    
    func setupFileWatcher() {
        fileWatcher?.cancel()
        guard isFileSyncEnabled else { return }
        
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
        ["openAI_APIKey", "openAI_BaseURL", "alwaysOnTop", "showDockIcon", "windowOpacity", "sendBehavior", "autoPasteClipboard", "appLanguage", "hotKeyKeyCode", "hotKeyModifiers", "menuBarIcon"]
    }
    
    func loadPrompts() {
        if !isFileSyncEnabled {
            // If disabled, we still need initial prompts (from local/bundle)
            if allPrompts.isEmpty {
                let localURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("Sidey/sidey_sync.json")
                let loadURL = FileManager.default.fileExists(atPath: localURL.path) ? localURL : Bundle.module.url(forResource: "prompts", withExtension: "json")
                if let loadURL = loadURL, let data = try? Data(contentsOf: loadURL),
                   let decoded = try? JSONDecoder().decode(SyncData.self, from: data) {
                    self.allPrompts = decoded.prompts
                }
            }
            return
        }
        
        let url = fileURL
        
        // Handle Migration
        if !FileManager.default.fileExists(atPath: url.path) {
            let oldURL = url.deletingLastPathComponent().appendingPathComponent("prompts.json")
            if FileManager.default.fileExists(atPath: oldURL.path) {
                try? FileManager.default.moveItem(at: oldURL, to: url)
            } else if let bundleURL = Bundle.module.url(forResource: "prompts", withExtension: "json") {
                try? FileManager.default.copyItem(at: bundleURL, to: url)
            } else {
                return // Nothing to load
            }
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(SyncData.self, from: data)
            
            DispatchQueue.main.async {
                // Restore Settings UI-side or via UserDefaults
                if let settings = decoded.settings {
                    var changed = false
                    for (key, value) in settings {
                        // Skip if already matching
                        let current = "\(UserDefaults.standard.object(forKey: key) ?? "")"
                        if current != value {
                            if key == "alwaysOnTop" || key == "showDockIcon" || key == "autoPasteClipboard" {
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
                
                // Only update prompts if they actually changed (avoid refresh loops)
                if self.allPrompts != decoded.prompts {
                    self.allPrompts = decoded.prompts
                }
            }
            self.stopAccessing()
        } catch {
            print("Error parsing sync file: \(error)")
            self.stopAccessing()
        }
    }
    
    func savePrompts() {
        guard isFileSyncEnabled else { return }
        
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
            stopAccessing()
            
            // Automatically push to cloud KVS (legacy/option)
            SyncManager.shared.syncPromptsToCloud(prompts: allPrompts)
            
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        } catch {
            print("Failed to save sync data: \(error)")
            stopAccessing()
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
                if key == "alwaysOnTop" || key == "showDockIcon" || key == "autoPasteClipboard" {
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
