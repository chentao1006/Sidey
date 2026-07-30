import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement
import Combine
import AppKit
import Aptabase


struct SettingsView: View {
    @AppStorage("settingsSelectedTab") private var selectedTab = "prompts"
    @AppStorage("appLanguage") private var appLanguage = "system"

    var body: some View {
        let currentLocale = appLanguage == "system" ? Locale.current : Locale(identifier: appLanguage)
        TabView(selection: $selectedTab) {
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
                
            GeneralSettingsView()
                .tabItem {
                    Label(L("General"), systemImage: "gear")
                }
                .tag("general")
            
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
        .environment(\.locale, currentLocale)
        .frame(width: 580, height: 480)
        .id(appLanguage)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("windowOpacity") private var windowOpacity: Double = 1.0
    @AppStorage("sendBehavior") private var sendBehavior = "return"
    @AppStorage("menuBarIcon") private var menuBarIcon = "brain"
    @AppStorage("assistantWindowType") private var assistantWindowType = "menuBarPopover"
    #if !APPSTORE
    @AppStorage("isSelectionCaptureEnabled") private var isSelectionCaptureEnabled = true
    #endif
    @ObservedObject private var dockingManager = DockingManager.shared
    #if !APPSTORE
    @ObservedObject private var permissionManager = PermissionManager.shared
    #endif
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isPopClipInstalled = PopClipIntegration.isPopClipInstalled
    @State private var isPopClipExtensionInstalled = PopClipIntegration.isExtensionInstalled
    
    private var usesRegularAssistantWindow: Bool {
        assistantWindowType == "regularWindow"
    }

    private var systemDefaultLanguageTitle: String {
        localizedLanguageOption("System Default", for: systemPreferredLanguageIdentifier)
    }

    private var systemLanguageTitle: String {
        localizedLanguageOption("Language", for: systemPreferredLanguageIdentifier)
    }

    private var systemPreferredLanguageIdentifier: String {
        let globalLanguages = UserDefaults.standard
            .persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return globalLanguages?.first ?? "en"
    }
    
    let menuBarIcons = [
        "none", "brain", "sparkles", "bolt.fill", "cpu", "circle.hexagongrid.fill", 
        "antenna.radiowaves.left.and.right", "gearshape.2.fill", "face.smiling", "command", "wand.and.stars"
    ]
    
    var body: some View {
        Form {
            Section {
                Picker(systemLanguageTitle, selection: Binding(
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
                    Text(systemDefaultLanguageTitle).tag("system")
                    Text(L("English")).tag("en")
                    Text(L("简体中文")).tag("zh-Hans")
                    Text(L("日本語")).tag("ja")
                    Text(L("한국어")).tag("ko")
                    Text(L("Deutsch")).tag("de")
                    Text(L("Français")).tag("fr")
                    Text(L("Español")).tag("es")
                    Text(L("Italiano")).tag("it")
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
                
                Picker(L("Window Type"), selection: $assistantWindowType) {
                    Text(L("Temporary Popover")).tag("menuBarPopover")
                    Text(L("Regular Window")).tag("regularWindow")
                }
                .pickerStyle(.menu)
                .onChangeCompatible(of: assistantWindowType) { _ in
                    AppDelegate.shared.applyAssistantWindowTypePreference()
                    SyncManager.shared.syncToCloud()
                }

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
                if isPopClipInstalled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            popClipIcon
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L("Install PopClip Extension"))
                                    .fontWeight(.semibold)
                                Text(L("Install the plugin to send selected text from PopClip to Sidey and open the assistant instantly."))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        HStack {
                            Spacer()
                            if isPopClipExtensionInstalled {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text(L("Installed"))
                            } else {
                                Button(L("Install Plugin")) {
                                    PopClipIntegration.installExtension()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                #if !APPSTORE
                VStack(alignment: .leading, spacing: 8) {

                    HStack {
                        Text(L("Accessibility Permission"))
                        Spacer()
                        if permissionManager.isAccessibilityGranted {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(L("Authorized"))
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Button(L("Authorize...")) {
                                permissionManager.checkAccessibility(prompt: true)
                                // Standard system behavior: wait for user to come back
                            }
                        }
                    }
                    Text(L("Required for capturing text selection and global shortcuts. If authorized but not working, try toggling the switch in System Settings."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                
                Toggle(L("Quick Selection Capture"), isOn: $isSelectionCaptureEnabled)
                    .help(L("Show a floating button when text is selected in other apps."))
                    .disabled(!permissionManager.isAccessibilityGranted)
                #endif
            } header: {
                Text(L("Permissions")).font(.headline)
            }
            .onAppear {
                isPopClipInstalled = PopClipIntegration.isPopClipInstalled
                isPopClipExtensionInstalled = PopClipIntegration.isExtensionInstalled
                #if !APPSTORE
                permissionManager.checkAccessibilityStatus()
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: PopClipIntegration.installStateDidChangeNotification)) { _ in
                isPopClipInstalled = PopClipIntegration.isPopClipInstalled
                isPopClipExtensionInstalled = PopClipIntegration.isExtensionInstalled
            }



            Section {
                Toggle(L("Window Docking"), isOn: $dockingManager.isAdsorptionEnabled)
                .help(L("Attach the assistant to the side of the active application window."))
                
                Toggle(L("Show Window Icon"), isOn: $dockingManager.isIconVisible)
                .help(L("Show a small floating icon next to the active application window."))
                

                if dockingManager.isAdsorptionEnabled || dockingManager.isIconVisible {
                    Picker(L("Docking Position"), selection: $dockingManager.dockingPosition) {
                        Text(L("Right")).tag(DockingPosition.right)
                        Text(L("Left")).tag(DockingPosition.left)
                        Text(L("Auto")).tag(DockingPosition.auto)
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text(L("Window Companion")).font(.headline)
            }
            .disabled(!usesRegularAssistantWindow)
            
            Section {
                Picker(L("Send Behavior"), selection: $sendBehavior) {
                    Text(L("Return to Send, ⇧+Return to Newline")).tag("return")
                    Text(L("⌘+Return to Send, Return to Newline")).tag("cmdReturn")
                }
                .pickerStyle(.menu)
                .onChangeCompatible(of: sendBehavior) { _ in SyncManager.shared.syncToCloud() }

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
    
    @ViewBuilder
    private var popClipIcon: some View {
        if let icon = PopClipIntegration.applicationIcon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: "wand.and.stars")
                .foregroundColor(.blue)
                .font(.system(size: 18))
        }
    }

    private func localizedLanguageOption(_ key: String, for languageIdentifier: String) -> String {
        let languageCode = normalizedLanguageIdentifier(languageIdentifier)
        let bundle = Bundle.sideyModule
        if let path = bundle.path(forResource: languageCode, ofType: "lproj"),
           let languageBundle = Bundle(path: path) {
            return languageBundle.localizedString(forKey: key, value: key, table: nil)
        }
        return key
    }

    private func normalizedLanguageIdentifier(_ identifier: String) -> String {
        let lowercased = identifier.lowercased()
        if lowercased.hasPrefix("zh") { return "zh-Hans" }
        if lowercased.hasPrefix("ja") { return "ja" }
        if lowercased.hasPrefix("ko") { return "ko" }
        if lowercased.hasPrefix("de") { return "de" }
        if lowercased.hasPrefix("fr") { return "fr" }
        if lowercased.hasPrefix("es") { return "es" }
        if lowercased.hasPrefix("it") { return "it" }
        return "en"
    }
}

struct APISettingsView: View {
    private struct ProviderPreset: Identifiable, Equatable {
        let id: String
        let name: String
        let apiFormat: String
        let baseURL: String
        let defaultModel: String
    }

    private static let customProviderID = "custom"
    private static let apiFormatOptions = [
        ("openai", "OpenAI Chat Completions"),
        ("anthropic", "Anthropic Messages"),
        ("gemini", "Google Gemini Native"),
        ("ollama", "Ollama Native")
    ]
    private static let providerPresets: [ProviderPreset] = [
        ProviderPreset(id: "openai", name: "OpenAI", apiFormat: "openai", baseURL: "https://api.openai.com/v1", defaultModel: "gpt-4o-mini"),
        ProviderPreset(id: "anthropic", name: "Anthropic Claude", apiFormat: "anthropic", baseURL: "https://api.anthropic.com", defaultModel: "claude-sonnet-4-20250514"),
        ProviderPreset(id: "google", name: "Google Gemini", apiFormat: "gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta", defaultModel: "gemini-2.5-flash"),
        ProviderPreset(id: "ollama", name: "Ollama (Local)", apiFormat: "ollama", baseURL: "http://localhost:11434", defaultModel: "llama3.2"),
        ProviderPreset(id: "deepseek", name: "DeepSeek", apiFormat: "openai", baseURL: "https://api.deepseek.com", defaultModel: "deepseek-chat"),
        ProviderPreset(id: "dashscope", name: "Alibaba Cloud Bailian (Qwen)", apiFormat: "openai", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", defaultModel: "qwen3.5-plus"),
        ProviderPreset(id: "kimi", name: "Moonshot Kimi", apiFormat: "openai", baseURL: "https://api.moonshot.ai/v1", defaultModel: "kimi-k2.5"),
        ProviderPreset(id: "siliconflow", name: "SiliconFlow", apiFormat: "openai", baseURL: "https://api.siliconflow.com/v1", defaultModel: "Qwen/Qwen3-235B-A22B"),
        ProviderPreset(id: "openrouter", name: "OpenRouter", apiFormat: "openai", baseURL: "https://openrouter.ai/api/v1", defaultModel: "openrouter/auto"),
        ProviderPreset(id: "groq", name: "Groq", apiFormat: "openai", baseURL: "https://api.groq.com/openai/v1", defaultModel: "llama-3.3-70b-versatile"),
        ProviderPreset(id: "mistral", name: "Mistral AI", apiFormat: "openai", baseURL: "https://api.mistral.ai/v1", defaultModel: "mistral-small-latest"),
        ProviderPreset(id: "together", name: "Together AI", apiFormat: "openai", baseURL: "https://api.together.ai/v1", defaultModel: "openai/gpt-oss-20b"),
        ProviderPreset(id: "xai", name: "xAI", apiFormat: "openai", baseURL: "https://api.x.ai/v1", defaultModel: "grok-4.3"),
        ProviderPreset(id: "zhipu", name: "Zhipu AI", apiFormat: "openai", baseURL: "https://open.bigmodel.cn/api/paas/v4", defaultModel: "glm-4.5")
    ]

    @StateObject private var client = LLMClient()
    @AppStorage("usePublicService") private var usePublicService = true
    @AppStorage("openAI_Provider") private var provider = "openai"
    @AppStorage("openAI_APIFormat") private var apiFormat = "openai"
    @AppStorage("openAI_APIKey") private var apiKey = ""
    @AppStorage("openAI_BaseURL") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("openAI_Model") private var model = "gpt-4o-mini"
    @AppStorage("appLanguage") private var appLanguage = "system"
    
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var isApplyingProviderPreset = false
    
    var body: some View {
        Form {
            Section {
                Picker(L("AI Service"), selection: $usePublicService) {
                    Text(L("Public Service (Limited)")).tag(true)
                    Text(L("Custom API")).tag(false)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChangeCompatible(of: usePublicService) { newValue in
                    if !newValue && baseURL.isEmpty {
                        baseURL = "https://"
                    }
                    SyncManager.shared.syncToCloud()
                }
                
                if usePublicService {
                    Text(L("Public service has rate limits and daily total limits. Use your own API for unrestricted access."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text(L("Service Mode")).font(.headline)
            }

            if !usePublicService {
                Section {
                    Picker(L("Provider"), selection: $provider) {
                        ForEach(Self.providerPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                        Divider()
                        Text(L("Custom Provider")).tag(Self.customProviderID)
                    }
                    .pickerStyle(.menu)
                    .help(L("Choose a common provider preset."))
                    .onChangeCompatible(of: provider) { newValue in
                        applyProviderPreset(newValue)
                        SyncManager.shared.syncToCloud()
                    }

                    Picker(L("API Format"), selection: $apiFormat) {
                        ForEach(Self.apiFormatOptions, id: \.0) { option in
                            Text(option.1).tag(option.0)
                        }
                    }
                    .pickerStyle(.menu)
                    .help(L("Choose the wire protocol used by this service."))
                    .onChangeCompatible(of: apiFormat) { _ in
                        markProviderAsCustomIfNeeded()
                        SyncManager.shared.syncToCloud()
                    }

                    TextField(L("Base URL"), text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .help(L("Default: https://api.openai.com/v1"))
                        .onChangeCompatible(of: baseURL) { newValue in
                            if newValue.isEmpty {
                                baseURL = apiFormat == "ollama" ? "http://" : "https://"
                            }
                            markProviderAsCustomIfNeeded()
                            SyncManager.shared.syncToCloud()
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(L("API Key"), text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .help(L("Enter the API key for this service."))
                            .onChangeCompatible(of: apiKey) { _ in SyncManager.shared.syncToCloud() }
                        if apiKey.isEmpty && apiFormat != "ollama" {
                            Text(L("⚠️ You need to provide an API key to use the assistant."))
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                    
                    TextField(L("Model"), text: $model)
                        .textFieldStyle(.roundedBorder)
                        .help(L("Default: gpt-4o-mini"))
                        .onChangeCompatible(of: model) { _ in
                            markProviderAsCustomIfNeeded()
                            SyncManager.shared.syncToCloud()
                        }
                    
                    HStack {
                        Button(action: testConnection) {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.trailing, 4)
                            }
                            Text(L("Test Connection"))
                        }
                        .disabled(isTesting || (apiKey.isEmpty && apiFormat != "ollama"))
                        
                        if let result = testResult {
                            Text(result)
                                .font(.caption)
                                .foregroundColor(result.contains("✅") ? .green : .red)
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 4)
                } header: {
                    Text(L("Custom API Settings")).font(.headline)
                }
            } else {
                Section {
                    HStack {
                        Button(action: testConnection) {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.trailing, 4)
                            }
                            Text(L("Test Connection"))
                        }
                        .disabled(isTesting)
                        
                        if let result = testResult {
                            Text(result)
                                .font(.caption)
                                .foregroundColor(result.contains("✅") ? .green : .red)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    Text(L("Public Service Settings")).font(.headline)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func applyProviderPreset(_ providerID: String) {
        guard let preset = Self.providerPresets.first(where: { $0.id == providerID }) else {
            return
        }
        isApplyingProviderPreset = true
        apiFormat = preset.apiFormat
        baseURL = preset.baseURL
        model = preset.defaultModel
        DispatchQueue.main.async {
            isApplyingProviderPreset = false
        }
    }

    private func markProviderAsCustomIfNeeded() {
        guard !isApplyingProviderPreset else { return }
        guard provider != Self.customProviderID else { return }
        guard let preset = Self.providerPresets.first(where: { $0.id == provider }) else {
            provider = Self.customProviderID
            return
        }
        if apiFormat != preset.apiFormat || baseURL != preset.baseURL || model != preset.defaultModel {
            provider = Self.customProviderID
        }
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        client.sendRequest(systemPrompt: "You are a helpful assistant.", messages: [ChatMessage(role: "user", content: "Say 'OK' if you can hear me.")], onUpdate: { _ in }) { response in
            isTesting = false
            let isError = response.localizedCaseInsensitiveContains("Error") || 
                          response.localizedCaseInsensitiveContains("Failed") || 
                          response.localizedCaseInsensitiveContains("No content") || 
                          response.isEmpty
            
            if isError {
                testResult = "❌ " + (response.isEmpty ? L("Unknown Error") : response)
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
    
    @State private var showingAutoCreateSheet = false
    @State private var autoCreateApps: [(bundleID: String, name: String)] = []
    
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
                        Aptabase.shared.trackEvent("add_assistant")
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
                    
                    Button(action: {
                        autoCreateApps = []
                        showingAutoCreateSheet = true
                    }) {
                        Image(systemName: "wand.and.stars")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Auto Create Assistants"))
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
                            .frame(height: 100)
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
                        Picker(L("Context Messages"), selection: Binding(
                            get: { store.allPrompts[index].contextMessageCount ?? 5 },
                            set: { newValue in
                                store.allPrompts[index].contextMessageCount = newValue
                                store.savePrompts()
                            }
                        )) {
                            ForEach(0...10, id: \.self) { count in
                                Text("\(count)").tag(count)
                            }
                            Text(L("Unlimited")).tag(-1)
                        }
                        .pickerStyle(.menu)
                    } header: {
                        Text(L("Behavior")).font(.headline)
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
                            .id("\(appLanguage)_\(appID)")
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
        .sheet(isPresented: $showingAutoCreateSheet) {
            AutoCreatePromptsSheet(initialApps: autoCreateApps) { newPrompts in
                for prompt in newPrompts {
                    store.allPrompts.append(prompt)
                }
                Aptabase.shared.trackEvent("add_assistant_bulk")
                store.savePrompts()
                if let first = newPrompts.first {
                    selectedPromptID = first.id
                }
            }
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
                Image(systemName: "minus.circle")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .onAppear {
            loadInfo()
        }
        .onChangeCompatible(of: bundleID) { _ in
            loadInfo()
        }
    }
    
    private func loadInfo() {
        if bundleID == "*" {
            name = L("All Apps (*)")
            icon = nil
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            name = bundleID
            icon = nil
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
        if (modifiers & 4096) != 0 { parts.append("⌃") } 
        if (modifiers & 2048) != 0 { parts.append("⌥") } 
        if (modifiers & 512) != 0 { parts.append("⇧") }  
        if (modifiers & 256) != 0 { parts.append("⌘") }  
        
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
            var carbonFlags: Int = 0
            if event.modifierFlags.contains(.control) { carbonFlags |= 4096 }
            if event.modifierFlags.contains(.option) { carbonFlags |= 2048 }
            if event.modifierFlags.contains(.shift) { carbonFlags |= 512 }
            if event.modifierFlags.contains(.command) { carbonFlags |= 256 }
            
            let code = Int(event.keyCode)
            if [54, 55, 56, 59, 60, 61, 62, 63].contains(code) { return event }
            
            keyCode = code
            modifiers = carbonFlags
            HotKeyManager.shared.registerHotkey()
            SyncManager.shared.syncToCloud()
            isRecording = false
            stopRecording()
            return nil
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
    @ObservedObject private var logger = DebugLogger.shared
    @State private var importSuccess = false
    @State private var exportSuccess = false
    @AppStorage("appLanguage") private var appLanguage = "system"
    private let logDisplayLimit = 100
    
    private var displayedLogs: [LogEntry] {
        Array(logger.logs.prefix(logDisplayLimit))
    }
    
    var body: some View {
        Form {
            Section {
                Toggle(L("iCloud Sync"), isOn: $store.isiCloudSyncEnabled)
                    .onChangeCompatible(of: store.isiCloudSyncEnabled) { enabled in
                        store.loadPrompts()
                        store.setupFileWatcher()
                        if enabled { SyncManager.shared.syncToCloud() }
                    }
                Text(L("Sync settings and prompts across your devices using iCloud."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text(L("iCloud Sync")).font(.headline) }

            Section {
                HStack {
                    Button(action: {
                        if let _ = store.exportBackup() {
                            exportSuccess = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exportSuccess = false }
                        }
                    }) {
                        Label(exportSuccess ? L("Exported!") : L("Export Backup..."), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                    
                    Button(action: {
                        if store.importBackup() {
                            importSuccess = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { importSuccess = false }
                        }
                    }) {
                        Label(importSuccess ? L("Imported!") : L("Import Backup..."), systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                }
            } header: { Text(L("Backup & Restore")).font(.headline) }
            
            Section {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if logger.logs.isEmpty {
                                Text(L("No logs available.")).foregroundColor(.secondary).italic().frame(maxWidth: .infinity, alignment: .center).padding(.top, 80)
                            } else {
                                if logger.logs.count > logDisplayLimit {
                                    Text(String(format: L("Showing latest %d of %d logs."), logDisplayLimit, logger.logs.count))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.bottom, 4)
                                }
                                
                                ForEach(displayedLogs) { entry in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(entry.timestamp, style: .time).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                                            Text(entry.type.rawValue.uppercased()).font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1).background(colorForType(entry.type)).foregroundColor(.white).cornerRadius(3)
                                        }
                                        Text(entry.message).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        Divider().padding(.vertical, 4)
                                    }
                                }
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 200).frame(maxWidth: .infinity).background(Color(NSColor.textBackgroundColor)).cornerRadius(4).overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    HStack {
                        Spacer()
                        Button(L("Clear Logs")) { logger.clear() }.buttonStyle(.borderless).controlSize(.small).foregroundColor(.red)
                    }.padding(.top, 4)
                }.frame(maxWidth: .infinity)
            } header: { Text(L("Debug Logs")).font(.headline) }
        }.formStyle(.grouped)
    }
    
    private func colorForType(_ type: LogEntry.LogType) -> Color {
        switch type {
        case .info: return .blue
        case .error: return .red
        case .request: return .purple
        case .response: return .green
        }
    }
}

struct AboutSettingsView: View {
    @StateObject private var updater = UpdaterViewModel()
    @AppStorage("allowAnalytics") private var allowAnalytics = false
    var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0" }
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().frame(width: 100, height: 100).shadow(radius: 5)
            VStack(spacing: 8) {
                Text(L("Sidey")).font(.title).fontWeight(.bold)
                Text("\(L("Version")) \(version)").font(.subheadline).foregroundColor(.secondary)
                #if !APPSTORE
                Button(action: { updater.checkForUpdates() }) { Label(L("Check for Updates..."), systemImage: "arrow.clockwise.circle") }.buttonStyle(.bordered).disabled(!updater.canCheckForUpdates).padding(.top, 4)
                #endif
            }

            Text(L("A lightweight, context-aware AI assistant for macOS.")).font(.body).multilineTextAlignment(.center).padding(.horizontal).frame(maxWidth: 300)
            Link(destination: URL(string: "https://github.com/chentao1006/Sidey")!) { HStack { Image(systemName: "link"); Text("GitHub") }.foregroundColor(.accentColor) }
            
            Toggle(L("Help improve Sidey by sharing anonymous usage data"), isOn: $allowAnalytics)
                .onChange(of: allowAnalytics) { newValue in
                    if newValue {
                        Aptabase.shared.initialize(appKey: "A-US-3536295643")
                    }
                }
                .padding(.top, 10)
            
            Spacer()
            Text("© 2026 chentao1006").font(.caption2).foregroundColor(.secondary).padding(.bottom, 20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Auto Create Assistants Sheet

struct AutoCreatePromptsSheet: View {
    let initialApps: [(bundleID: String, name: String)]
    let onAdd: ([Prompt]) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [(bundleID: String, name: String)] = []
    @State private var suggestions: [PromptSuggestion] = []
    @State private var isGenerating = true
    @State private var errorMessage: String?
    @State private var currentStyle: ResponseStyle = ResponseStyle(rawValue: PromptStore.shared.lastUsedResponseStyle) ?? .serious
    
    struct PromptSuggestion: Identifiable {
        let id = UUID().uuidString
        var name: String
        var system: String
        var isSelected: Bool = true
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.accent)
                Text(L("Auto Create Assistants")).font(.headline)
                Spacer()
            }.padding()
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button(action: {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [UTType.application]
                        panel.allowsMultipleSelection = true
                        panel.canChooseDirectories = false
                        panel.directoryURL = URL(fileURLWithPath: "/Applications")
                        if panel.runModal() == .OK {
                            let newApps: [(bundleID: String, name: String)] = panel.urls.compactMap { url in
                                let resolvedURL = url.resolvingSymlinksInPath()
                                guard let bundleID = Bundle(url: resolvedURL)?.bundleIdentifier else { return nil }
                                let name = FileManager.default.displayName(atPath: resolvedURL.path)
                                return (bundleID: bundleID, name: name)
                            }
                            apps.append(contentsOf: newApps)
                            if !apps.isEmpty {
                                generateSuggestions(apps)
                            }
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                            Text(apps.isEmpty ? L("Pick Apps...") : L("Add..."))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    
                    ForEach(apps, id: \.bundleID) { app in
                            HStack(spacing: 4) {
                                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                                } else { Image(systemName: "app.fill").frame(width: 16, height: 16).foregroundColor(.secondary) }
                                Text(app.name).font(.caption).lineLimit(1)
                            }.padding(.horizontal, 8).padding(.vertical, 4).background(Color.secondary.opacity(0.1)).cornerRadius(6)
                        }
                    }
                }.padding(.horizontal).padding(.vertical, 8)
            Divider()
            if isGenerating {
                VStack(spacing: 16) { ProgressView().controlSize(.large); Text(L("AI is generating assistant suggestions...")).foregroundColor(.secondary).font(.subheadline) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundColor(.orange)
                    Text(error).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                    Button(L("Retry")) { generateSuggestions() }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        if suggestions.isEmpty && !isGenerating {
                            VStack(spacing: 12) {
                                Image(systemName: "hand.tap")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary)
                                Text(L("No apps selected. Please choose apps first."))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.top, 80)
                        } else {
                            ForEach($suggestions) { $suggestion in
                                HStack(alignment: .top, spacing: 12) {
                                    Toggle("", isOn: $suggestion.isSelected).toggleStyle(.checkbox).labelsHidden().padding(.top, 4)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(suggestion.name).font(.system(.body, weight: .semibold))
                                        Text(suggestion.system).font(.caption).foregroundColor(.secondary).lineLimit(4)
                                    }
                                    Spacer()
                                }.padding(12).background(RoundedRectangle(cornerRadius: 8).fill(suggestion.isSelected ? Color.accentColor.opacity(0.08) : Color.clear)).overlay(RoundedRectangle(cornerRadius: 8).stroke(suggestion.isSelected ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: 1)).contentShape(Rectangle()).onTapGesture { suggestion.isSelected.toggle() }
                            }
                        }
                    }.padding()
                }
            }
            Divider()
            HStack {
                if !isGenerating && !suggestions.isEmpty {
                    Menu {
                        ForEach(ResponseStyle.allCases) { style in
                            Button {
                                currentStyle = style
                                PromptStore.shared.lastUsedResponseStyle = style.rawValue
                                generateSuggestions(apps)
                            } label: {
                                if currentStyle == style {
                                    Label(style.localizedName, systemImage: "checkmark")
                                } else {
                                    Text(style.localizedName)
                                }
                            }
                        }
                    } label: { Label(L("Regenerate"), systemImage: "arrow.clockwise").font(.subheadline) }.menuStyle(.borderedButton)
                }
                
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Add Selected")) {
                    let selected = suggestions.filter(\.isSelected)
                    let bundleIDs = apps.map(\.bundleID)
                    let prompts = selected.map { s in Prompt(id: UUID().uuidString, name: s.name, system: s.system, apps: bundleIDs) }
                    onAdd(prompts)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(suggestions.filter(\.isSelected).isEmpty)
            }.padding()
        }.frame(width: 520, height: 480).onAppear {
            self.apps = initialApps
            if !initialApps.isEmpty {
                generateSuggestions(initialApps)
            } else {
                isGenerating = false
            }
        }
    }
    
    private func generateSuggestions(_ targetApps: [(bundleID: String, name: String)]? = nil) {
        let activeApps = targetApps ?? self.apps
        if activeApps.isEmpty { return }
        
        isGenerating = true; errorMessage = nil; suggestions = []
        let appDescriptions = activeApps.map { "\($0.name) (\($0.bundleID))" }.joined(separator: ", ")
        let appLang = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let lang = Self.promptLanguageName(for: appLang)
        let systemPrompt = """
Objective: Design 2-3 professional AI assistant personas specifically for the provided applications.
CRITICAL: ALL OUTPUT (NAMES AND SYSTEM INSTRUCTIONS) MUST BE IN \(lang.uppercased()).

Persona Style: \(currentStyle.generationHint).

STRICT RULES:
1. LANGUAGE: Use ONLY \(lang). 
2. DISTINCT NAMES: The name MUST reflect the chosen persona style. 
   - SERIOUS style: Use formal, cold, or academic names (e.g., '逻辑核验', '技术审计', '文法把关'). 
   - LIVELY style: Use warm, energetic, or creative names (e.g., '灵感推手', '效率飞升', '文笔大咖').
3. SHORT NAMES: Use extremely short role names (1-3 words/characters).
4. DESIGN PERSONAS: Do not describe the app. Create a functional assistant role.
5. STRICTLY NO ACTIONS: The assistant MUST NOT claim to manage, operate, automate, or control the system or applications. They are PURELY for text-based Q&A, generation, and analysis.
6. NO SMALL TALK: Be direct and practical. Focus strictly on task-specific content.
7. JSON FORMAT: Only respond with [{\"name\": \"...\", \"system\": \"...\"}].
"""
        let userMessage = "Applications selected: \(appDescriptions). Please design practical, role-based AI assistant configurations specifically for use within these applications' context."
        let client = LLMClient()
        client.sendRequest(systemPrompt: systemPrompt, messages: [ChatMessage(role: "user", content: userMessage)], onUpdate: { _ in }) { response in
            var jsonStr = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if jsonStr.hasPrefix("```") {
                if let firstNewline = jsonStr.firstIndex(of: "\n") { jsonStr = String(jsonStr[jsonStr.index(after: firstNewline)...]) }
                if let lastFence = jsonStr.range(of: "```", options: .backwards) { jsonStr = String(jsonStr[..<lastFence.lowerBound]) }
                jsonStr = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            struct RawSuggestion: Codable { let name: String; let system: String }
            guard let data = jsonStr.data(using: .utf8), let raw = try? JSONDecoder().decode([RawSuggestion].self, from: data) else {
                errorMessage = L("Failed to parse AI response. Please try again."); isGenerating = false; return
            }
            suggestions = raw.map { PromptSuggestion(name: $0.name, system: $0.system) }; isGenerating = false
        }
    }

    private static func promptLanguageName(for appLang: String) -> String {
        let identifier = appLang == "system" ? (Locale.preferredLanguages.first ?? "en") : appLang
        let lowercased = identifier.lowercased()
        if lowercased.hasPrefix("zh") { return "Chinese" }
        if lowercased.hasPrefix("ja") { return "Japanese" }
        if lowercased.hasPrefix("ko") { return "Korean" }
        if lowercased.hasPrefix("de") { return "German" }
        if lowercased.hasPrefix("fr") { return "French" }
        if lowercased.hasPrefix("es") { return "Spanish" }
        if lowercased.hasPrefix("it") { return "Italian" }
        return "English"
    }
}
