import SwiftUI
import AppKit
import MarkdownUI

struct MessageExchange: Equatable, Identifiable, Codable {
    let id: UUID
    var userMessage: String
    var aiResponse: String
    var isExpanded: Bool = false
}

struct SessionState: Equatable, Codable {
    var exchanges: [MessageExchange]
    var lastScrollID: String?
}

struct AssistantWindow: View {
    @ObservedObject private var contextDetector = ContextDetector.shared
    @ObservedObject private var promptStore = PromptStore.shared
    @ObservedObject private var historyStore = HistoryStore.shared
    @StateObject private var llmClient = LLMClient()
    @Environment(\.openWindow) private var openWindow
    
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @AppStorage("settingsSelectedTab") private var settingsSelectedTab = "general"
    @AppStorage("windowOpacity") private var windowOpacity: Double = 1.0
    @AppStorage("sendBehavior") private var sendBehavior = "return"
    @AppStorage("appLanguage") private var appLanguage = "system"
    
    @State private var window: NSWindow?
    
    @State private var selectedPrompt: Prompt?
    @State private var userInput: String = ""
    @State private var currentExchanges: [MessageExchange] = []
    @State private var copied: Bool = false
    @State private var promptStates: [String: SessionState] = [:] // key -> SessionState
    @State private var lastPromptIDPerApp: [String: String] = [:] // bundleID -> promptID
    @State private var currentSessionKey: String = ""
    @State private var unreadSessions: Set<String> = []
    @State private var textToInsert: String? = nil
    @State private var lastPasteboardChangeCount: Int = NSPasteboard.general.changeCount
    @State private var clipboardContent: String? = nil
    @State private var includeClipboard: Bool = true
    @State private var lastFinishedExchangeID: UUID? = nil
    
    // Auto Creator
    @State private var appsToAutoCreate: [(bundleID: String, name: String)] = []
    
    struct AutoCreateContext: Identifiable {
        let id = UUID()
        let apps: [(bundleID: String, name: String)]
    }
    @State private var autoCreateContext: AutoCreateContext?
    
    var body: some View {
        let currentLocale = appLanguage == "system" ? Locale.current : Locale(identifier: appLanguage)
        ZStack(alignment: .bottom) {
            VStack(spacing: 16) {
                appContextHeader
                promptList
                inputArea
                responseArea
            }
            .padding()
        }
        .environment(\.locale, currentLocale)
        .id(appLanguage)
        .frame(minWidth: 380, idealWidth: 380, minHeight: 520, idealHeight: 520)
        .background(WindowAccessor(window: $window))
        .onChangeCompatible(of: alwaysOnTop) { newValue in
            window?.level = newValue ? .floating : .normal
        }
        .onChangeCompatible(of: windowOpacity) { newValue in
            window?.alphaValue = CGFloat(newValue)
        }
        .onChangeCompatible(of: window) { newWindow in
            if let w = newWindow {
                w.level = alwaysOnTop ? .floating : .normal
                w.alphaValue = CGFloat(windowOpacity)
            }
        }
        // Automatically select the first available prompt on context change
        .onChangeCompatible(of: contextDetector.currentBundleID) { newValue in
            let targetPrompt = bestPrompt(for: newValue)
            switchTo(bundleID: newValue, prompt: targetPrompt)
        }
        .onAppear {
            contextDetector.refresh()
            let targetPrompt = bestPrompt(for: contextDetector.currentBundleID)
            switchTo(bundleID: contextDetector.currentBundleID, prompt: targetPrompt)
            checkClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            contextDetector.refresh()
            if !unreadSessions.isEmpty, let lastSession = unreadSessions.first {
                let parts = lastSession.split(separator: "|")
                if parts.count == 2 {
                    let targetBundleID = String(parts[0])
                    let targetPromptID = String(parts[1])
                    
                    let availablePrompts = promptStore.getPrompts(for: targetBundleID)
                    if availablePrompts.contains(where: { $0.id == targetPromptID }) {
                        NotificationCenter.default.post(
                            name: Notification.Name("CXAISwitchSession"),
                            object: nil,
                            userInfo: ["bundleID": targetBundleID, "promptID": targetPromptID]
                        )
                        return // Skip standard fallback
                    }
                }
            }
            
            let availablePrompts = promptStore.getPrompts(for: contextDetector.currentBundleID)
            if selectedPrompt == nil || !availablePrompts.contains(where: { $0.id == selectedPrompt?.id }) {
                let targetPrompt = bestPrompt(for: contextDetector.currentBundleID)
                switchTo(bundleID: contextDetector.currentBundleID, prompt: targetPrompt)
            }
            
            checkClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CXAISwitchSession"))) { notification in
            if let userInfo = notification.userInfo,
               let targetBundleID = userInfo["bundleID"] as? String,
               let targetPromptID = userInfo["promptID"] as? String {
                // If we are given a prompt to switch to, find it
                let availablePrompts = promptStore.getPrompts(for: targetBundleID)
                if let prompt = availablePrompts.first(where: { $0.id == targetPromptID }) {
                    // Update detector so it matches visually
                    contextDetector.currentBundleID = targetBundleID
                    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == targetBundleID }) {
                        contextDetector.currentAppName = app.localizedName ?? targetBundleID
                        if let url = app.bundleURL {
                            contextDetector.currentAppIcon = NSWorkspace.shared.icon(forFile: url.path)
                        } else {
                            contextDetector.currentAppIcon = nil
                        }
                    } else if targetBundleID == "com.apple.finder" {
                        contextDetector.currentAppName = "Finder"
                        contextDetector.currentAppIcon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
                    } else if targetBundleID == "*" {
                        contextDetector.currentAppName = L("All Apps (*)")
                        contextDetector.currentAppIcon = nil
                    }
                    
                    switchTo(bundleID: targetBundleID, prompt: prompt)
                }
            }
        }
        .sheet(item: $autoCreateContext) { context in
            AutoCreatePromptsSheet(initialApps: context.apps) { newPrompts in
                for prompt in newPrompts {
                    promptStore.allPrompts.append(prompt)
                }
                promptStore.savePrompts()
                
                // Switch to the first newly added prompt
                if let first = newPrompts.first {
                    switchTo(bundleID: contextDetector.currentBundleID, prompt: first)
                }
            }
        }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private var appContextHeader: some View {
        HStack(spacing: 8) {
            Button(action: {
                if !contextDetector.currentBundleID.isEmpty {
                    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: contextDetector.currentBundleID).first {
                        // Snapshot the screen BEFORE activating to avoid Space-switch timing issues
                        let targetScreen = AppDelegate.shared.screenForApp(app)
                        app.activate(options: .activateIgnoringOtherApps)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            AppDelegate.shared.showAssistant(targetScreen: targetScreen)
                        }
                    }
                }
            }) {
                HStack(spacing: 8) {
                    if let icon = contextDetector.currentAppIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 36, height: 36)
                    } else {
                        Image(systemName: "app.fill")
                            .resizable()
                            .frame(width: 36, height: 36)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contextDetector.currentAppName.isEmpty ? L("No App") : contextDetector.currentAppName)
                            .font(.title3)
                            .fontWeight(.medium)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(contextDetector.currentAppName.isEmpty ? "" : L("Back to App"))
            
            Spacer()
            
            ZStack(alignment: .topTrailing) {
                Menu {
                    Text(L("Recent Apps"))
                    let recent = filteredRecentApps
                    if recent.isEmpty {
                        Text(L("No Recent Apps"))
                    } else {
                        ForEach(recent) { appCtx in
                            Button {
                                if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == appCtx.bundleID }) {
                                    let targetScreen = AppDelegate.shared.screenForApp(app)
                                    app.activate(options: .activateIgnoringOtherApps)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        AppDelegate.shared.showAssistant(targetScreen: targetScreen)
                                    }
                                }
                            } label: {
                                let suffix = hasUnreadFor(bundleID: appCtx.bundleID) ? L(" (New Answer)") : (hasLoadingFor(bundleID: appCtx.bundleID) ? L(" (Thinking...)") : "")
                                Text(appCtx.appName + suffix)
                            }
                        }
                    }
                    
                    Divider()
                    Text(L("Running Apps"))
                    let running = filteredRunningApps
                    if running.isEmpty {
                        Text(L("No Running Apps"))
                    } else {
                        ForEach(running, id: \.bundleIdentifier) { app in
                            Button {
                                let targetScreen = AppDelegate.shared.screenForApp(app)
                                app.activate(options: .activateIgnoringOtherApps)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    AppDelegate.shared.showAssistant(targetScreen: targetScreen)
                                }
                            } label: {
                                let suffix = hasUnreadFor(bundleID: app.bundleIdentifier) ? L(" (New Answer)") : (hasLoadingFor(bundleID: app.bundleIdentifier) ? L(" (Thinking...)") : "")
                                let name = app.localizedName ?? (app.bundleIdentifier ?? "Unknown")
                                Text(name + suffix)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.right.arrow.left")
                }
                .menuStyle(BorderlessButtonMenuStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("Recent Apps"))
                
                if hasAnyOtherUnread || hasAnyOtherLoading {
                    Circle()
                        .fill(hasAnyOtherUnread ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                        .offset(x: 2, y: -2)
                        .allowsHitTesting(false)
                }
            }
            
            Button {
                alwaysOnTop.toggle()
            } label: {
                Image(systemName: alwaysOnTop ? "pin.fill" : "pin.slash")
                    .foregroundColor(alwaysOnTop ? .accentColor : .primary)
            }
            .buttonStyle(.plain)
            .help(alwaysOnTop ? L("Unpin Window") : L("Pin Window"))
            
            Button {
                settingsSelectedTab = "general"
                AppDelegate.shared.showSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help(L("Settings"))
        }
    }
    
    @ViewBuilder
    private var promptList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Available Prompts"))
                    .font(.headline)
                Spacer()
                
                let availablePrompts = promptStore.getPrompts(for: contextDetector.currentBundleID)
                let unassignedPrompts = promptStore.allPrompts.filter { prompt in
                    !prompt.apps.contains("*") && !availablePrompts.contains(where: { $0.id == prompt.id })
                }
                
                Menu {
                    if !unassignedPrompts.isEmpty {
                        Text(L("Assign Existing Prompt:"))
                        ForEach(unassignedPrompts) { prompt in
                            Button(prompt.name) {
                                if let idx = promptStore.allPrompts.firstIndex(where: { $0.id == prompt.id }) {
                                    var updatedPrompt = promptStore.allPrompts[idx]
                                    if !contextDetector.currentBundleID.isEmpty {
                                        updatedPrompt.apps.append(contextDetector.currentBundleID)
                                        promptStore.allPrompts[idx] = updatedPrompt
                                        promptStore.savePrompts()
                                        
                                        // Notify to re-render using selectedPrompt if needed
                                        if selectedPrompt == nil {
                                            switchTo(bundleID: contextDetector.currentBundleID, prompt: updatedPrompt)
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                    }
                    
                    Button(action: {
                        let newPrompt = Prompt(id: UUID().uuidString, name: L("New Prompt"), system: L("You are a helpful assistant."), apps: contextDetector.currentBundleID.isEmpty ? [] : [contextDetector.currentBundleID])
                        promptStore.allPrompts.append(newPrompt)
                        promptStore.editingPromptID = newPrompt.id
                        promptStore.savePrompts()
                        
                        // Ensure window is shown
                        settingsSelectedTab = "prompts"
                        AppDelegate.shared.showSettings()
                    }) {
                        Text(L("Create New..."))
                    }
                    
                    Button(action: {
                        contextDetector.refresh()
                        if !contextDetector.currentBundleID.isEmpty {
                            autoCreateContext = AutoCreateContext(apps: [(bundleID: contextDetector.currentBundleID, name: contextDetector.currentAppName)])
                        }
                    }) {
                        Label(L("Auto Create..."), systemImage: "sparkles")
                    }
                    .disabled(contextDetector.currentBundleID.isEmpty || contextDetector.currentBundleID == "*")
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(BorderlessButtonMenuStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("Add Prompt"))
            }
            
            let availablePrompts = promptStore.getPrompts(for: contextDetector.currentBundleID)
            
            if availablePrompts.isEmpty {
                Text(L("No prompts available for this app. Please check prompts.json or select an app with configured prompts."))
                    .foregroundColor(.secondary)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(availablePrompts) { prompt in
                            Button(action: {
                                self.switchTo(bundleID: contextDetector.currentBundleID, prompt: prompt)
                            }) {
                                let sessionKey = "\(contextDetector.currentBundleID)|\(prompt.id)"
                                
                                HStack(spacing: 6) {
                                    Text(prompt.name)
                                    if llmClient.loadingStates[sessionKey] == true {
                                        ProgressView()
                                            .controlSize(.small)
                                            .scaleEffect(0.7)
                                    }
                                }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(selectedPrompt?.id == prompt.id ? Color.accentColor : Color.secondary.opacity(0.2))
                                    .foregroundColor(selectedPrompt?.id == prompt.id ? .white : .primary)
                                    .cornerRadius(8)
                                    .overlay(
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 8, height: 8)
                                            .offset(x: -4, y: 4)
                                            .opacity(unreadSessions.contains(sessionKey) ? 1 : 0),
                                        alignment: .topTrailing
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(prompt.system)
                        }
                    }
                }
            }
            
            if let selected = selectedPrompt {
                HStack(spacing: 4) {
                    Text(selected.system)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    
                    Button(action: {
                        settingsSelectedTab = "prompts"
                        promptStore.editingPromptID = selected.id
                        AppDelegate.shared.showSettings()
                    }) {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Edit Prompt"))
                }
                .padding(.top, 4)
            }
        }
    }
    
    @ViewBuilder
    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Ask AI..."))
                .font(.headline)
            
            MacTextEditor(text: $userInput, textToInsert: $textToInsert, sendBehavior: sendBehavior, onSend: sendMessage)
                .frame(height: clipboardContent == nil ? 60 : 44)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            if let content = clipboardContent {
                HStack(alignment: .top, spacing: 6) {
                    Toggle("", isOn: $includeClipboard)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .controlSize(.small)
                        .padding(.top, 1)
                    
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.top, 3)

                    Text(cleanPreview(content))
                        .font(.caption)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Button(action: {
                        clipboardContent = nil
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .help(L("Clear Clipboard Preview"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    includeClipboard.toggle()
                }
                .onHover { inside in
                    if inside {
                        NSCursor.pointingHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
            }
            
            HStack(spacing: 8) {
                Button(action: {
                    self.userInput = ""
                    self.currentExchanges = []
                    if !currentSessionKey.isEmpty {
                        promptStates[currentSessionKey] = SessionState(exchanges: [])
                    }
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Clear Input"))
                .opacity(userInput.isEmpty && currentExchanges.isEmpty ? 0 : 1)
                
                Spacer()
                
                Button(action: sendMessage) {
                    HStack {
                        if llmClient.loadingStates[currentSessionKey] == true {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 2)
                        }
                        Text("\(L("Send")) (\(sendBehavior == "cmdReturn" ? "⌘↵" : "↵"))")
                            .fontWeight(.bold)
                    }
                }
                .keyboardShortcut(.return, modifiers: sendBehavior == "cmdReturn" ? [.command] : [])
                .disabled((userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(includeClipboard && clipboardContent != nil)) || selectedPrompt == nil || llmClient.loadingStates[currentSessionKey] == true)
                .help(L("Send"))
            }
        }
    }
    
    @ViewBuilder
    private var responseArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("AI Response"))
                    .font(.headline)
                
                Spacer()
                
                Menu {
                    let history = historyStore.interactions.filter { $0.appBundleID == contextDetector.currentBundleID && $0.promptName == selectedPrompt?.name }.prefix(5)
                    if history.isEmpty {
                        Text(L("No History"))
                    } else {
                        ForEach(Array(history)) { interaction in
                            Button(action: {
                                if let prompt = promptStore.allPrompts.first(where: { $0.name == interaction.promptName }) {
                                    self.switchTo(bundleID: contextDetector.currentBundleID, prompt: prompt)
                                }
                                self.userInput = "" // Clear input since we are loading history
                                let exchange = MessageExchange(id: UUID(), userMessage: interaction.userMessage, aiResponse: interaction.aiResponse)
                                self.currentExchanges = [exchange]
                                self.promptStates[self.currentSessionKey] = SessionState(exchanges: [exchange])
                            }) {
                                Text(interaction.userMessage.prefix(30) + (interaction.userMessage.count > 30 ? "..." : ""))
                            }
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(.secondary)
                }
                .menuStyle(BorderlessButtonMenuStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("Recent History"))
            }
            
            ZStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach($currentExchanges) { $exchange in
                                VStack(alignment: .leading, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(exchange.isExpanded ? exchange.userMessage : cleanPreview(exchange.userMessage))
                                            .font(.subheadline)
                                            .lineLimit(exchange.isExpanded ? nil : 3)
                                            .padding(10)
                                            .background(Color.accentColor.opacity(0.1))
                                            .cornerRadius(8)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .onTapGesture {
                                                withAnimation {
                                                    exchange.isExpanded.toggle()
                                                }
                                            }
                                        
                                        if !exchange.isExpanded && (exchange.userMessage.count > 100 || exchange.userMessage.contains("\n")) {
                                            Text(L("Click to expand"))
                                                .font(.caption2)
                                                .foregroundColor(.accentColor)
                                                .padding(.leading, 10)
                                                .onTapGesture {
                                                    withAnimation {
                                                        exchange.isExpanded.toggle()
                                                    }
                                                }
                                        }
                                    }
                                    .padding(.horizontal)
                                    .padding(.top, 12)
                                    
                                    VStack(alignment: .leading, spacing: 0) {
                                        Color.clear.frame(height: 0).id(exchange.id.uuidString + "_top")
                                        if exchange.aiResponse == "Thinking..." {
                                            HStack {
                                                ProgressView()
                                                    .controlSize(.small)
                                                    .padding(.trailing, 4)
                                                Text(L("Thinking..."))
                                            }
                                            .padding()
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        } else {
                                            Markdown(exchange.aiResponse)
                                                .padding()
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                            
                            if currentExchanges.isEmpty {
                                Text(L("Output will appear here..."))
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            
                            Color.clear
                                .frame(height: 1)
                                .id("bottom_anchor")
                        }
                    }
                    .onChangeCompatible(of: currentExchanges) { newValue in
                        if let last = newValue.last, last.aiResponse == "Thinking..." {
                            proxy.scrollTo("bottom_anchor", anchor: .bottom)
                        }
                    }
                    .onChangeCompatible(of: currentSessionKey) { _ in
                        // When switching sessions/prompts, scroll to the top of the last exchange (answer)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { // Increase delay to ensure render
                            if let lastID = currentExchanges.last?.id {
                                withAnimation(.easeInOut(duration: 0.6)) {
                                    proxy.scrollTo(lastID.uuidString + "_top", anchor: .top)
                                }
                            } else {
                                proxy.scrollTo("bottom_anchor", anchor: .bottom)
                            }
                        }
                    }
                    .onChangeCompatible(of: llmClient.loadingStates[currentSessionKey]) { isLoading in
                        if isLoading == false, let lastID = lastFinishedExchangeID {
                            // Finished an answer, scroll to its top
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation(.easeInOut(duration: 0.6)) {
                                    proxy.scrollTo(lastID.uuidString + "_top", anchor: .top)
                                }
                                // Reset after scroll
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                                    self.lastFinishedExchangeID = nil
                                }
                            }
                        }
                    }
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            
            // Action Buttons
            if let lastExchange = currentExchanges.last, lastExchange.aiResponse != "Thinking..." {
                HStack(spacing: 8) {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lastExchange.aiResponse, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copied = false
                        }
                    }) {
                        Label(copied ? L("Copied!") : L("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help(L("Copy"))
                    
                    Menu {
                        ForEach(ResponseStyle.allCases) { style in
                            Button {
                                PromptStore.shared.lastUsedResponseStyle = style.rawValue
                                retryLastExchange(style: style)
                            } label: {
                                if PromptStore.shared.lastUsedResponseStyle == style.rawValue {
                                    Label(style.localizedName, systemImage: "checkmark")
                                } else {
                                    Text(style.localizedName)
                                }
                            }
                        }
                        
                        Divider()
                        
                        Button(L("Retry")) {
                            retryLastExchange(style: nil)
                        }
                    } label: {
                        Label(L("Regenerate"), systemImage: "arrow.clockwise")
                    }
                    .help(L("Regenerate"))
                    
                    if !contextDetector.currentBundleID.isEmpty {
                        Button(action: {
                            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: contextDetector.currentBundleID).first {
                                app.activate(options: .activateIgnoringOtherApps)
                            }
                        }) {
                            Label(String(format: L("Back to %@"), contextDetector.currentAppName.isEmpty ? L("App") : contextDetector.currentAppName), systemImage: "arrow.uturn.backward")
                        }
                        .help(String(format: L("Back to %@"), contextDetector.currentAppName.isEmpty ? L("App") : contextDetector.currentAppName))
                    }
                    
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
    
    private func retryLastExchange(style: ResponseStyle? = nil) {
        guard let prompt = selectedPrompt, !currentExchanges.isEmpty else { return }
        
        let lastUserMessage = currentExchanges.last?.userMessage ?? ""
        if lastUserMessage.isEmpty { return }
        
        // Remove the last exchange to "retry" it
        currentExchanges.removeLast()
        
        // Call performSend (abstracted from sendMessage)
        performSend(messageToSend: lastUserMessage, prompt: prompt, style: style)
    }
    
    private func sendMessage() {
        guard let prompt = selectedPrompt else { return }
        
        var messageToSend = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if includeClipboard, let content = clipboardContent {
            if messageToSend.isEmpty {
                messageToSend = content
            } else {
                messageToSend = "\(messageToSend)\n\n---\n\(content)"
            }
        }
        
        if messageToSend.isEmpty { return }
        performSend(messageToSend: messageToSend, prompt: prompt)
        
        // Deselect clipboard after sending
        self.includeClipboard = false
    }
    
    private func performSend(messageToSend: String, prompt: Prompt, style: ResponseStyle? = nil) {
        let newExchangeID = UUID()
        let newExchange = MessageExchange(id: newExchangeID, userMessage: messageToSend, aiResponse: "Thinking...")
        self.currentExchanges.append(newExchange)
        self.userInput = ""
        
        let currentBundleID = contextDetector.currentBundleID
        let currentAppName = contextDetector.currentAppName
        let promptName = prompt.name
        var systemPrompt = prompt.system
        
        // Apply personality constraints and style
        systemPrompt += "\n\nCore Constraints: You are a practical, text-based AI assistant. Focus on content output. Be simple, clear, and direct. Avoid flamboyant small talk. Do not claim to be 'omnipotent' or 'omniscient'."
        let activeStyle = style ?? ResponseStyle(rawValue: PromptStore.shared.lastUsedResponseStyle) ?? .serious
        systemPrompt += activeStyle.instruction
        
        let promptID = prompt.id
        
        let sessionKey = self.currentSessionKey
        promptStates[sessionKey] = SessionState(exchanges: currentExchanges)
        
        // Prepare full context with "Appropriate Compression" (适当压缩)
        let maxHistoryTurns = 10
        let contextExchanges = currentExchanges.dropLast().suffix(maxHistoryTurns)
        
        let historyMessages = contextExchanges.flatMap { exchange -> [ChatMessage] in
            let compressedUser = exchange.userMessage.count > 2000 ? (String(exchange.userMessage.prefix(2000)) + "... [History Truncated]") : exchange.userMessage
            let compressedAI = exchange.aiResponse.count > 3000 ? (String(exchange.aiResponse.prefix(3000)) + "... [History Truncated]") : exchange.aiResponse
            
            return [
                ChatMessage(role: "user", content: compressedUser),
                ChatMessage(role: "assistant", content: compressedAI)
            ]
        }
        var allMessages = historyMessages
        allMessages.append(ChatMessage(role: "user", content: messageToSend))
        
        llmClient.sendRequest(systemPrompt: systemPrompt, messages: allMessages, sessionKey: sessionKey) { response in
            // Update the stored state first (persistence)
            if var state = self.promptStates[sessionKey] {
                if let index = state.exchanges.firstIndex(where: { $0.id == newExchangeID }) {
                    state.exchanges[index].aiResponse = response
                    self.promptStates[sessionKey] = state
                }
            }
            
            // If this is still the active session, update UI state
            if self.currentSessionKey == sessionKey {
                if let index = self.currentExchanges.firstIndex(where: { $0.id == newExchangeID }) {
                    self.currentExchanges[index].aiResponse = response
                    self.lastFinishedExchangeID = newExchangeID
                }
            } else {
                // Background session completed
                self.unreadSessions.insert(sessionKey)
                NotificationManager.shared.sendNotification(
                    title: "\(promptName) " + L("Response Completed"),
                    body: response,
                    bundleID: currentBundleID,
                    promptID: promptID
                )
            }
            
            // Log interaction
            let interaction = Interaction(
                appBundleID: currentBundleID,
                appName: currentAppName.isEmpty ? "Unknown" : currentAppName,
                promptName: promptName,
                systemPrompt: systemPrompt,
                userMessage: messageToSend,
                aiResponse: response
            )
            HistoryStore.shared.addInteraction(interaction)
        }
    }
    
    private func switchTo(bundleID: String, prompt: Prompt?) {
        if !currentSessionKey.isEmpty {
            promptStates[currentSessionKey] = SessionState(
                exchanges: currentExchanges,
                lastScrollID: nil // Reverting for now for stability
            )
        }
        
        self.selectedPrompt = prompt
        if let p = prompt {
            lastPromptIDPerApp[bundleID] = p.id
        }
        
        let newKey = "\(bundleID)|\(prompt?.id ?? "")"
        self.currentSessionKey = newKey
        self.unreadSessions.remove(newKey)
        
        let state = promptStates[newKey]
        self.currentExchanges = state?.exchanges ?? []
    }
    
    private func checkClipboard() {
        let currentChangeCount = NSPasteboard.general.changeCount
        if let newText = NSPasteboard.general.string(forType: .string),
           !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            
            // Only update if it's new content
            if currentChangeCount != lastPasteboardChangeCount {
                clipboardContent = newText
                includeClipboard = true
                lastPasteboardChangeCount = currentChangeCount
            }
        } else {
            clipboardContent = nil
            lastPasteboardChangeCount = currentChangeCount
        }
    }
    
    private func bestPrompt(for bundleID: String) -> Prompt? {
        let available = promptStore.getPrompts(for: bundleID)
        if let lastID = lastPromptIDPerApp[bundleID], let last = available.first(where: { $0.id == lastID }) {
            return last
        }
        return available.first
    }

    private var hasAnyOtherUnread: Bool {
        unreadSessions.contains { sessionKey in
            let bundleID = String(sessionKey.split(separator: "|").first ?? "")
            return bundleID != "*" && bundleID != contextDetector.currentBundleID
        }
    }

    private var hasAnyOtherLoading: Bool {
        llmClient.loadingStates.contains { key, isLoading in
            if !isLoading { return false }
            let bundleID = String(key.split(separator: "|").first ?? "")
            return bundleID != "*" && bundleID != contextDetector.currentBundleID
        }
    }

    private func hasUnreadFor(bundleID: String?) -> Bool {
        guard let bundleID = bundleID else { return false }
        return unreadSessions.contains { $0.hasPrefix("\(bundleID)|") }
    }

    private func hasLoadingFor(bundleID: String?) -> Bool {
        guard let bundleID = bundleID else { return false }
        return llmClient.loadingStates.contains { key, isLoading in
            isLoading && key.hasPrefix("\(bundleID)|")
        }
    }

    private var filteredRecentApps: [ContextDetector.AppContext] {
        contextDetector.recentApps.filter { $0.bundleID != contextDetector.currentBundleID }
    }

    private var filteredRunningApps: [NSRunningApplication] {
        let recentIDs = Set(filteredRecentApps.map { $0.bundleID })
        return NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return app.activationPolicy == .regular &&
            bundleID != contextDetector.currentBundleID &&
            !recentIDs.contains(bundleID)
        }
        .sorted { (app1, app2) -> Bool in
            let name1 = app1.localizedName ?? ""
            let name2 = app2.localizedName ?? ""
            return name1.localizedCompare(name2) == .orderedAscending
        }
    }

    private var activePIDs: Set<Int32> {
        var pids = Set<Int32>()
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            for window in infoList {
                guard let pid = window[kCGWindowOwnerPID as String] as? Int32 else { continue }
                if let alpha = window[kCGWindowAlpha as String] as? Double, alpha == 0 { continue }
                
                if let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                   let bounds = CGRect(dictionaryRepresentation: boundsDict) {
                    let name = window[kCGWindowName as String] as? String ?? ""
                    let isReasonableSize = bounds.width > 40 && bounds.height > 40
                    if isReasonableSize {
                        if !name.isEmpty || (bounds.width > 120 && bounds.height > 120) {
                            pids.insert(pid)
                        }
                    }
                }
            }
        }
        return pids
    }

    private func cleanPreview(_ text: String) -> String {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// macOS 13+ compatibility wrapper for onChange
extension View {
    @ViewBuilder func onChangeCompatible<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct MacTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var textToInsert: String?
    var sendBehavior: String
    var onSend: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.drawsBackground = false
        textView.allowsUndo = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        
        if let toInsert = textToInsert {
            textView.insertText(toInsert, replacementRange: textView.selectedRange())
            let newText = textView.string
            DispatchQueue.main.async {
                self.text = newText
                self.textToInsert = nil
            }
            return
        }
        
        if textView.string != text {
            textView.string = text
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacTextEditor
        init(_ parent: MacTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.parent.text = textView.string
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if parent.sendBehavior == "return" {
                if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    if NSEvent.modifierFlags.contains(.shift) {
                        textView.insertText("\n", replacementRange: textView.selectedRange())
                        return true
                    } else {
                        parent.onSend()
                        return true
                    }
                }
            }
            return false
        }
    }
}
