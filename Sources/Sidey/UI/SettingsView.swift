import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

struct SettingsView: View {
    @AppStorage("settingsSelectedTab") private var selectedTab = "general"
    @AppStorage("appLanguage") private var appLanguage = "system"

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label(L("General"), systemImage: "gear")
                }
                .tag("general")
            
            PromptSettingsView()
                .tabItem {
                    Label(L("Prompts"), systemImage: "text.bubble")
                }
                .tag("prompts")

            APISettingsView()
                .tabItem {
                    Label(L("AI Service"), systemImage: "sparkles")
                }
                .tag("api")
                
            DataSettingsView()
                .tabItem {
                    Label(L("Data"), systemImage: "arrow.triangle.2.circlepath")
                }
                .tag("data")
            
            AboutSettingsView()
                .tabItem {
                    Label(L("About"), systemImage: "info.circle")
                }
                .tag("about")
        }
        .frame(width: 580, height: 480)
        .id(appLanguage)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("windowOpacity") private var windowOpacity: Double = 1.0
    @AppStorage("sendBehavior") private var sendBehavior = "return"
    @AppStorage("autoPasteClipboard") private var autoPasteClipboard = false
    @AppStorage("menuBarIcon") private var menuBarIcon = "brain"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    
    let menuBarIcons = [
        "none", "brain", "sparkles", "bolt.fill", "cpu", "circle.hexagongrid.fill", 
        "antenna.radiowaves.left.and.right", "gearshape.2.fill", "face.smiling", "command", "wand.and.stars"
    ]
    
    var body: some View {
        Form {
            Section {
                Picker(L("Language"), selection: Binding(
                    get: { appLanguage },
                    set: { newValue in
                        if newValue == "system" {
                            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                        } else {
                            UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                        }
                        appLanguage = newValue
                    }
                )) {
                    Text(L("System Default")).tag("system")
                    Text(L("English")).tag("en")
                    Text(L("简体中文")).tag("zh-Hans")
                }
                .pickerStyle(.menu)
                .help(L("Restart or reopen windows to apply language changes."))
                .onChangeCompatible(of: appLanguage) { newValue in
                    if newValue == "system" {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                    }
                    SyncManager.shared.syncToCloud()
                }
                
                Toggle(L("Show application in Dock"), isOn: $showDockIcon)
                    .help(L("If disabled, the app will only appear in the menu bar."))
                    .onChangeCompatible(of: showDockIcon) { newValue in
                        let policy: NSApplication.ActivationPolicy = newValue ? .regular : .accessory
                        NSApplication.shared.setActivationPolicy(policy)
                        if newValue {
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        } else {
                            NSApplication.shared.deactivate()
                        }
                        SyncManager.shared.syncToCloud()
                    }

                Picker(L("Menu Bar Icon"), selection: $menuBarIcon) {
                    ForEach(menuBarIcons, id: \.self) { icon in
                        if icon == "none" {
                            Text(L("None")).tag("none")
                        } else {
                            HStack {
                                Image(systemName: icon)
                                    .frame(width: 20)
                                Text(L(icon))
                            }.tag(icon)
                        }
                    }
                }
                .pickerStyle(.menu)
                .onChangeCompatible(of: menuBarIcon) { _ in SyncManager.shared.syncToCloud() }

                HStack {
                    Text(L("Window Opacity"))
                    Slider(value: $windowOpacity, in: 0.5...1.0)
                        .onChangeCompatible(of: windowOpacity) { _ in SyncManager.shared.syncToCloud() }
                    Text("\(Int(windowOpacity * 100))%")
                        .frame(width: 40, alignment: .trailing)
                }

                Toggle(L("Always on top"), isOn: $alwaysOnTop)
                    .help(L("Keep the Assistant window above all other windows."))
            } header: {
                Text(L("Appearance")).font(.headline)
            }
            
            Section {
                Picker(L("Send Behavior"), selection: $sendBehavior) {
                    Text(L("Return to Send, ⇧+Return to Newline")).tag("return")
                    Text(L("⌘+Return to Send, Return to Newline")).tag("cmdReturn")
                }
                .pickerStyle(.menu)
                .onChangeCompatible(of: sendBehavior) { _ in SyncManager.shared.syncToCloud() }
                
                Toggle(L("Auto Paste from Clipboard"), isOn: $autoPasteClipboard)
                    .help(L("Automatically paste copied text from other apps when Assistant activates."))
                    .onChangeCompatible(of: autoPasteClipboard) { _ in SyncManager.shared.syncToCloud() }

                Toggle(L("Launch at Login"), isOn: $launchAtLogin)
                    .help(L("Start the app automatically when you log in."))
                    .onChangeCompatible(of: launchAtLogin) { newValue in
                        let service = SMAppService.mainApp
                        do {
                            if newValue {
                                try service.register()
                            } else {
                                try service.unregister()
                            }
                        } catch {
                            print("Failed to update login item: \(error)")
                            // Reset state if failed
                            launchAtLogin = service.status == .enabled
                        }
                    }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L("Global Shortcut:"))
                        Spacer()
                        ShortcutRecorderView()
                    }
                    Text(L("Brings the Assistant Window to the front globally."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            } header: {
                Text(L("Behavior")).font(.headline)
            }
        }
        .formStyle(.grouped)
    }
}

struct APISettingsView: View {
    @AppStorage("openAI_APIKey") private var apiKey = ""
    @AppStorage("openAI_BaseURL") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("appLanguage") private var appLanguage = "system"
    
    @State private var testResult: String?
    @State private var isTesting = false
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    SecureField(L("API Key"), text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .help(L("Enter your OpenAI or compatible API key."))
                        .onChangeCompatible(of: apiKey) { _ in SyncManager.shared.syncToCloud() }
                    if apiKey.isEmpty {
                        Text(L("⚠️ You need to provide an API key to use the assistant."))
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                
                TextField(L("Base URL"), text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .help(L("Default: https://api.openai.com/v1"))
                    .onChangeCompatible(of: baseURL) { _ in SyncManager.shared.syncToCloud() }
                
                HStack {
                    Button(action: testConnection) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                        }
                        Text(L("Test Connection"))
                    }
                    .disabled(isTesting || apiKey.isEmpty)
                    
                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.contains("✅") ? .green : .red)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 4)
            } header: {
                Text(L("OpenAI Settings")).font(.headline)
            }
        }
        .formStyle(.grouped)
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        let client = LLMClient()
        client.sendRequest(systemPrompt: "You are a helpful assistant.", userMessage: "Say 'OK' if you can hear me.") { response in
            isTesting = false
            if response.contains("Error") || response.contains("Failed") {
                testResult = "❌ " + response
            } else {
                testResult = "✅ " + L("Connection Successful")
            }
        }
    }
}

struct PromptSettingsView: View {
    @StateObject private var store = PromptStore.shared
    @State private var selectedPromptID: String?
    @State private var showingDeleteAlert = false
    @State private var promptToDelete: String?
    @AppStorage("appLanguage") private var appLanguage = "system"
    
    var body: some View {
        HStack(spacing: 0) {
            // Sidebar List
            VStack(spacing: 0) {
                List(selection: $selectedPromptID) {
                    ForEach(store.allPrompts) { prompt in
                        Text(prompt.name).tag(prompt.id)
                    }
                    .onMove { source, destination in
                        store.allPrompts.move(fromOffsets: source, toOffset: destination)
                        store.savePrompts()
                    }
                }
                .listStyle(.inset)
                
                Divider()
                
                HStack(spacing: 16) {
                    Button(action: {
                        let newPrompt = Prompt(id: UUID().uuidString, name: L("New Prompt"), system: L("You are a helpful assistant."), apps: [])
                        store.allPrompts.append(newPrompt)
                        store.savePrompts()
                        selectedPromptID = newPrompt.id
                    }) {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        if selectedPromptID != nil {
                            promptToDelete = selectedPromptID
                            showingDeleteAlert = true
                        }
                    }) {
                        Image(systemName: "minus")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedPromptID == nil)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor))
            }
            .frame(width: 180)
            
            Divider()
            
            // Detail Editor
            if let selectedID = selectedPromptID, let index = store.allPrompts.firstIndex(where: { $0.id == selectedID }) {
                Form {
                    Section {
                        TextField(L("Name"), text: $store.allPrompts[index].name)
                            .onChangeCompatible(of: store.allPrompts[index].name) { _ in store.savePrompts() }
                    }
                    
                    Section {
                        TextEditor(text: $store.allPrompts[index].system)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 140)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                            .onChangeCompatible(of: store.allPrompts[index].system) { _ in store.savePrompts() }
                    } header: {
                        Text(L("System Prompt")).font(.headline)
                    }
                    
                    Section {
                        HStack(spacing: 16) {
                            Button(L("Add App...")) {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [UTType.application]
                                panel.allowsMultipleSelection = true
                                panel.canChooseDirectories = false
                                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                                
                                if panel.runModal() == .OK {
                                    for url in panel.urls {
                                        if let bundleID = Bundle(url: url)?.bundleIdentifier {
                                            if !store.allPrompts[index].apps.contains(bundleID) {
                                                store.allPrompts[index].apps.append(bundleID)
                                            }
                                        }
                                    }
                                    store.savePrompts()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            
                            if !store.allPrompts[index].apps.contains("*") {
                                Button(L("Match All (*)")) {
                                    store.allPrompts[index].apps.insert("*", at: 0)
                                    store.savePrompts()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.bottom, 4)
                        
                        ForEach(store.allPrompts[index].apps, id: \.self) { appID in
                            AppInfoRow(bundleID: appID) {
                                store.allPrompts[index].apps.removeAll(where: { $0 == appID })
                                store.savePrompts()
                            }
                            .id(appLanguage)
                        }
                    } header: {
                        Text(L("Matched Apps")).font(.headline)
                    }
                }
                .formStyle(.grouped)
            } else {
                Text(L("Select a prompt to edit"))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .onReceive(store.$editingPromptID) { newID in
            if let id = newID {
                selectedPromptID = id
                // Optional: slight delay or just reset immediately
                store.editingPromptID = nil // reset
            }
        }
        .onAppear {
            if let id = store.editingPromptID {
                selectedPromptID = id
                store.editingPromptID = nil
            }
        }
        .alert(L("Delete Prompt?"), isPresented: $showingDeleteAlert) {
            Button(L("Delete"), role: .destructive) {
                if let id = promptToDelete {
                    store.allPrompts.removeAll(where: { $0.id == id })
                    store.savePrompts()
                    if selectedPromptID == id {
                        selectedPromptID = nil
                    }
                }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Are you sure you want to delete this prompt? This action cannot be undone."))
        }
    }
}

struct AppInfoRow: View {
    let bundleID: String
    let onRemove: () -> Void
    
    @State private var icon: NSImage? = nil
    @State private var name: String = ""
    
    var body: some View {
        HStack {
            if let icon = icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: bundleID == "*" ? "star.fill" : "app.fill")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundColor(bundleID == "*" ? .yellow : .secondary)
            }
            
            Text(name.isEmpty ? bundleID : name)
                .font(.body)
            
            if bundleID != "*" && name != bundleID {
                Text(bundleID)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: onRemove) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .onAppear {
            if bundleID == "*" {
                name = L("All Apps (*)")
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                name = FileManager.default.displayName(atPath: url.path)
                icon = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                name = bundleID
            }
        }
    }
}

struct ShortcutRecorderView: View {
    @AppStorage("hotKeyKeyCode") private var keyCode: Int = 49 // kVK_Space
    @AppStorage("hotKeyModifiers") private var modifiers: Int = 2304 // cmdKey (256) | optionKey (2048)
    
    @State private var isRecording = false
    @State private var monitor: Any?
    
    var body: some View {
        Button(action: {
            isRecording.toggle()
            if isRecording {
                startRecording()
            } else {
                stopRecording()
            }
        }) {
            Text(isRecording ? L("Recording...") : formattedShortcut())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isRecording ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundColor(isRecording ? .white : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
    
    private func formattedShortcut() -> String {
        var parts: [String] = []
        // Carbon modifiers mapping
        if (modifiers & 4096) != 0 { parts.append("⌃") } // controlKey
        if (modifiers & 2048) != 0 { parts.append("⌥") } // optionKey
        if (modifiers & 512) != 0 { parts.append("⇧") }  // shiftKey
        if (modifiers & 256) != 0 { parts.append("⌘") }  // cmdKey
        
        let charMap: [Int: String] = [
            49: "Space", 53: "Esc", 36: "Return", 48: "Tab", 51: "Delete",
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
            126: "↑", 125: "↓", 123: "←", 124: "→"
        ]
        
        parts.append(charMap[keyCode] ?? String(format: "Key %d", keyCode))
        return parts.joined(separator: "+")
    }
    
    private func startRecording() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Map NSEvent flags to Carbon modifiers
            var carbonFlags: Int = 0
            if event.modifierFlags.contains(.control) { carbonFlags |= 4096 }
            if event.modifierFlags.contains(.option) { carbonFlags |= 2048 }
            if event.modifierFlags.contains(.shift) { carbonFlags |= 512 }
            if event.modifierFlags.contains(.command) { carbonFlags |= 256 }
            
            // Refuse pure modifier keys
            let code = Int(event.keyCode)
            if [54, 55, 56, 59, 60, 61, 62, 63].contains(code) {
                return event
            }
            
            // Save newly captured keys
            keyCode = code
            modifiers = carbonFlags
            
            // Re-register via HotKeyManager
            HotKeyManager.shared.registerHotkey()
            SyncManager.shared.syncToCloud()
            
            isRecording = false
            stopRecording()
            
            return nil // Swallow event
        }
    }
    
    private func stopRecording() {
        if let currentMonitor = monitor {
            NSEvent.removeMonitor(currentMonitor)
            monitor = nil
        }
    }
}

struct DataSettingsView: View {
    @StateObject private var store = PromptStore.shared
    @State private var importSuccess = false
    @State private var exportSuccess = false
    @AppStorage("appLanguage") private var appLanguage = "system"
    
    var body: some View {
        Form {
            Section {
                Toggle(L("Enable File Sync"), isOn: $store.isFileSyncEnabled)
                    .onChangeCompatible(of: store.isFileSyncEnabled) { enabled in
                        if enabled {
                            store.loadPrompts()
                            store.setupFileWatcher()
                        } else {
                            store.setupFileWatcher() // This will cancel it
                        }
                    }
                
                HStack {
                    Text(L("Sync Folder:"))
                    Spacer()
                    if let userPath = UserDefaults.standard.string(forKey: "customSyncPath"), !userPath.isEmpty {
                        Text(userPath)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(L("Default (iCloud Drive)"))
                            .foregroundColor(.secondary)
                    }
                    Button(L("Choose...")) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.prompt = L("Select Sync Folder")
                        if let userPath = UserDefaults.standard.string(forKey: "customSyncPath"), !userPath.isEmpty {
                            panel.directoryURL = URL(fileURLWithPath: userPath)
                        }
                        
                        if panel.runModal() == .OK, let url = panel.url {
                            store.updateBookmark(for: url)
                            // Immediately migrate or load from the new path
                            store.loadPrompts()
                            store.setupFileWatcher()
                        }
                    }
                    .buttonStyle(.bordered)
                    
                    if let userPath = UserDefaults.standard.string(forKey: "customSyncPath"), !userPath.isEmpty {
                        Button(action: {
                            UserDefaults.standard.removeObject(forKey: "customSyncPath")
                            store.loadPrompts()
                            store.setupFileWatcher()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                Text(L("You can choose an iCloud Drive or DropBox folder to automatically sync your data across devices without limitations."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
            } header: {
                Text(L("File Sync")).font(.headline)
            }

            Section {
                Button(action: {
                    if let _ = store.exportBackup() {
                        exportSuccess = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exportSuccess = false }
                    }
                }) {
                    Label(exportSuccess ? L("Exported!") : L("Export Backup..."), systemImage: "square.and.arrow.up")
                }
                
                Button(action: {
                    if store.importBackup() {
                        importSuccess = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { importSuccess = false }
                    }
                }) {
                    Label(importSuccess ? L("Imported!") : L("Import Backup..."), systemImage: "square.and.arrow.down")
                }
            } header: {
                Text(L("Backup & Restore")).font(.headline)
            }
        }
        .formStyle(.grouped)
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct AboutSettingsView: View {
    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 100, height: 100)
                .shadow(radius: 5)
            
            VStack(spacing: 8) {
                Text(L("Sidey"))
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("\(L("Version")) \(version)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Text(L("A lightweight, context-aware AI assistant for macOS."))
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .frame(maxWidth: 300)
            
            Link(destination: URL(string: "https://github.com/chentao1006/Sidey")!) {
                HStack {
                    Image(systemName: "link")
                    Text("GitHub")
                }
                .foregroundColor(.accentColor)
            }
            
            Spacer()
            
            Text("© 2026 chentao1006")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
