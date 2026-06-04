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
    var attachments: [Attachment]?
}

enum AttachmentType: String, Codable {
    case clipboard
    case selection
    
    var icon: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        case .selection: return "selection.pin.in.out"
        }
    }
    
    var labelKey: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .selection: return "Selection"
        }
    }
}

struct Attachment: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    let type: AttachmentType
    var content: String
    var isSelected: Bool = true
    var isLoading: Bool = false
    
    static func == (lhs: Attachment, rhs: Attachment) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content && lhs.isSelected == rhs.isSelected && lhs.isLoading == rhs.isLoading
    }
}

struct AssistantWindow: View {
    private let hidesDockingControl: Bool
    
    @ObservedObject private var contextDetector = ContextDetector.shared
    @ObservedObject private var promptStore = PromptStore.shared
    @ObservedObject private var historyStore = HistoryStore.shared
    @ObservedObject private var dockingManager = DockingManager.shared
    @ObservedObject private var permissionManager = PermissionManager.shared
    @StateObject private var llmClient = LLMClient()
    @Environment(\.openWindow) private var openWindow
    
    @AppStorage("alwaysOnTop") private var alwaysOnTop = true
    @AppStorage("settingsSelectedTab") private var settingsSelectedTab = "prompts"
    @AppStorage("windowOpacity") private var windowOpacity: Double = 1.0
    @AppStorage("sendBehavior") private var sendBehavior = "return"
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("assistantWindowType") private var assistantWindowType = "menuBarPopover"
    @AppStorage("hasDismissedAccessibilityTip") private var hasDismissedAccessibilityTip = false
    
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
    @State private var attachments: [Attachment] = []
    @State private var lastFinishedExchangeID: UUID? = nil
    @State private var lastSentMessage: String = ""
    
    // Auto Creator
    @State private var appsToAutoCreate: [(bundleID: String, name: String)] = []
    
    struct AutoCreateContext: Identifiable {
        let id = UUID()
        let apps: [(bundleID: String, name: String)]
    }
    @State private var autoCreateContext: AutoCreateContext?
    @State private var previewedAttachment: Attachment?
    
    init(hidesDockingControl: Bool = false) {
        self.hidesDockingControl = hidesDockingControl
    }
    
    var body: some View {
        let currentLocale = appLanguage == "system" ? Locale.current : Locale(identifier: appLanguage)
        ZStack(alignment: .bottom) {
            VStack(spacing: 10) {
                if !permissionManager.isAccessibilityGranted && !hasDismissedAccessibilityTip {
                    discoveryTip
                }
                appContextHeader
                promptList
                inputArea
                responseArea
            }
            .padding()
        }
        .environment(\.locale, currentLocale)
        .id(appLanguage)
        .frame(minWidth: 300, idealWidth: 300, minHeight: 520, idealHeight: 520)
        .background(WindowAccessor(window: $window))

        .onChangeCompatible(of: alwaysOnTop) { newValue in
            window?.level = newValue ? .floating : .normal
            AppDelegate.shared.updateMenuBarAssistantPopoverBehavior()
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
        .onChangeCompatible(of: promptStore.allPrompts) { _ in
            syncSelectedPromptWithStore()
        }
        .onAppear {
            contextDetector.refresh()
            let targetPrompt = bestPrompt(for: contextDetector.currentBundleID)
            switchTo(bundleID: contextDetector.currentBundleID, prompt: targetPrompt)
            refreshContext()
            
            DispatchQueue.main.async {
                consumePendingAssistantSwitchIfNeeded(source: "onAppear")
                consumePendingSelectedTextIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            contextDetector.refresh()
            
            let availablePrompts = promptStore.getPrompts(for: contextDetector.currentBundleID)
            if selectedPrompt == nil || !availablePrompts.contains(where: { $0.id == selectedPrompt?.id }) {
                let targetPrompt = bestPrompt(for: contextDetector.currentBundleID)
                switchTo(bundleID: contextDetector.currentBundleID, prompt: targetPrompt)
            }
            
            refreshContext()
            DispatchQueue.main.async {
                consumePendingSelectedTextIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SideySendSelectionToAssistant"))) { notification in
            if let selection = notification.object as? String {
                AppDelegate.shared.queueSelectedTextForAssistant(selection)
                AppDelegate.shared.showAssistant()
                DispatchQueue.main.async {
                    consumePendingSelectedTextIfNeeded()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NotificationCenter.default.post(name: Notification.Name("SideyPendingSelectionAvailable"), object: nil)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SideyPendingSelectionAvailable"))) { _ in
            consumePendingSelectedTextIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CXAISwitchSession"))) { notification in
            if let userInfo = notification.userInfo,
               let targetBundleID = userInfo["bundleID"] as? String,
               let targetPromptID = userInfo["promptID"] as? String {
                handleAssistantSwitch(bundleID: targetBundleID, promptID: targetPromptID, source: "notification")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SideyRefreshContext"))) { _ in
            refreshContext()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SideyDirectSend"))) { notification in
            if let userInfo = notification.userInfo,
               let targetBundleID = userInfo["bundleID"] as? String,
               let targetPromptID = userInfo["promptID"] as? String {
                
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
                    }
                    
                    switchTo(bundleID: targetBundleID, prompt: prompt)
                    
                    // Refresh context but don't auto-send
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        refreshContext(force: true)
                    }
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
    
    @ViewBuilder
    private var discoveryTip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cursorarrow.and.square.on.square.dashed")
                    .foregroundColor(.green)
                    .font(.system(size: 16))
                    .padding(.top, 2)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Enable Selection Support"))
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Text(L("Get AI context by selecting text in any app."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
                
                Button(action: {
                    withAnimation {
                        hasDismissedAccessibilityTip = true
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            HStack {
                Spacer()
                Button(L("Enable Now")) {
                    permissionManager.checkAccessibility(prompt: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)
            }

        }
        .padding(10)
        .background(Color.green.opacity(0.1))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.green.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 2)

    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private var appContextHeader: some View {
        HStack(spacing: 8) {
            Button(action: {
                if !contextDetector.currentBundleID.isEmpty {
                    activateOrOpenApp(bundleID: contextDetector.currentBundleID)
                }
            }) {
                HStack(spacing: 8) {
                    if let icon = contextDetector.currentAppIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "app.fill")
                            .resizable()
                            .frame(width: 24, height: 24)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text(contextDetector.currentAppName.isEmpty ? L("No App") : contextDetector.currentAppName)
                            .font(.headline)
                            .fontWeight(.medium)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(contextDetector.currentAppName.isEmpty ? "" : L("Back to App"))
            
            if !hidesDockingControl {
                Button {
                    dockingManager.isAdsorptionEnabled.toggle()
                } label: {
                    Image(systemName: "dock.arrow.down.rectangle")
                        .rotationEffect(.degrees(90))
                        .foregroundColor(dockingManager.isAdsorptionEnabled ? .accentColor : .secondary)
                        .font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(.plain)
                .help(dockingManager.isAdsorptionEnabled ? L("Disable Docking") : L("Enable Docking"))
            }
            
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
                                    activateOrOpenApp(bundleID: appCtx.bundleID)
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
                                    if let bundleID = app.bundleIdentifier {
                                        activateOrOpenApp(bundleID: bundleID)
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
                AppDelegate.shared.toggleAssistantWindowType()
            } label: {
                Image(systemName: assistantWindowType == "regularWindow" ? "menubar.rectangle" : "macwindow")
            }
            .buttonStyle(.plain)
            .help(assistantWindowType == "regularWindow" ? L("Switch to Menu Bar Popover") : L("Switch to Regular Window"))
            
            Button {
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
                ScrollViewReader { promptProxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(availablePrompts) { prompt in
                                Button(action: {
                                    self.switchTo(bundleID: contextDetector.currentBundleID, prompt: prompt)
                                }) {
                                    let sessionKey = "\(contextDetector.currentBundleID)|\(prompt.id)"
                                    
                                    HStack(spacing: 4) {
                                        Text(prompt.name)
                                            .font(.subheadline)
                                        if llmClient.loadingStates[sessionKey] == true {
                                            ProgressView()
                                                .controlSize(.small)
                                                .scaleEffect(0.6)
                                        }
                                    }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(selectedPrompt?.id == prompt.id ? Color.accentColor : Color.secondary.opacity(0.15))
                                        .foregroundColor(selectedPrompt?.id == prompt.id ? .white : .primary)
                                        .cornerRadius(6)
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
                                .id(prompt.id)
                            }
                        }
                    }
                    .onChangeCompatible(of: selectedPrompt) { newValue in
                        if let id = newValue?.id {
                            withAnimation(.spring()) {
                                promptProxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
            
            if let selected = selectedPrompt {
                HStack(spacing: 4) {
                    Text(selected.system.replacingOccurrences(of: "\n", with: " "))
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
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                MacTextEditor(text: $userInput, textToInsert: $textToInsert, sendBehavior: sendBehavior, onSend: sendMessage)
                
                if !inputPlaceholder.isEmpty {
                    Text(inputPlaceholder.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: NSFont.systemFontSize))
                        .foregroundColor(Color(NSColor.placeholderTextColor))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .padding(.horizontal, 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 20, idealHeight: 30, maxHeight: 40)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            
            HStack(spacing: 8) {
                if !userInput.isEmpty || !currentExchanges.isEmpty {
                    Button(action: {
                        self.userInput = ""
                        self.currentExchanges = []
                        if !currentSessionKey.isEmpty {
                            promptStates[currentSessionKey] = SessionState(exchanges: [])
                        }
                    }) {
                        Image(systemName: "eraser")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Clear Input"))
                }
                
                historyMenu
                
                Spacer()
                
                // Attachments now share the same row for maximum space efficiency
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach($attachments) { $attachment in
                            AttachmentItemView(attachment: $attachment, previewedAttachment: $previewedAttachment)
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: 160, alignment: .trailing) // Prevent it from taking over the whole row and align to right
                
                if llmClient.loadingStates[currentSessionKey] == true {
                    Button(action: {
                        llmClient.stopRequest(sessionKey: currentSessionKey)
                        if userInput.isEmpty { userInput = lastSentMessage }
                        if let index = currentExchanges.lastIndex(where: { $0.aiResponse == L("Thinking...") }) {
                            currentExchanges[index].aiResponse = ""
                        }
                    }) {
                        HStack {
                            Image(systemName: "stop.fill")
                            Text(L("Stop"))
                                .fontWeight(.bold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(white: 0.35))
                    .foregroundColor(.white)
                    .help(L("Stop"))
                } else {
                    Button(action: sendMessage) {
                        HStack {
                            Text("\(L("Send")) (\(sendBehavior == "cmdReturn" ? "⌘↵" : "↵"))")
                                .fontWeight(.bold)
                        }
                    }
                    .keyboardShortcut(.return, modifiers: sendBehavior == "cmdReturn" ? [.command] : [])
                    .disabled((userInput.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty && attachments.filter { $0.isSelected && !$0.content.isEmpty }.isEmpty) || selectedPrompt == nil)
                    .help(L("Send"))
                }
            }
            .padding(.top, 2)
            .overlay(alignment: .top) {
                if let preview = previewedAttachment {
                    Text(preview.content.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 2)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1), lineWidth: 0.5))
                        .offset(y: -40)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }
    
    private var inputPlaceholder: String {
        guard userInput.isEmpty,
              let clipboard = attachments.first(where: { $0.type == .clipboard && $0.isSelected && !$0.content.isEmpty }) else {
            return ""
        }
        return clipboard.content
    }
    
    @ViewBuilder
    private var historyMenu: some View {
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
                        self.userInput = ""
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
    
    @ViewBuilder
    private var responseArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            
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
                                            let lines = exchange.aiResponse.components(separatedBy: .newlines)
                                            VStack(alignment: .leading, spacing: 0) {
                                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                                    ResponseLineView(line: line, onCopy: { text in
                                                        NSPasteboard.general.clearContents()
                                                        NSPasteboard.general.setString(text, forType: .string)
                                                        
                                                        // Back to App
                                                        if !contextDetector.currentBundleID.isEmpty,
                                                           let app = NSRunningApplication.runningApplications(withBundleIdentifier: contextDetector.currentBundleID).first {
                                                            app.activate(options: .activateIgnoringOtherApps)
                                                        }
                                                    })
                                                }
                                            }
                                            .padding(.vertical, 8)
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
                    
                    Button(action: {
                        retryLastExchange(style: nil)
                    }) {
                        Label(L("Retry"), systemImage: "arrow.clockwise")
                    }
                    .help(L("Retry"))
                    
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
        
        var messageParts: [String] = []
        let trimmedInput = userInput.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !trimmedInput.isEmpty {
            messageParts.append(trimmedInput)
        }
        
        for attachment in attachments where attachment.isSelected && !attachment.content.isEmpty {
            messageParts.append("\n---\n\(attachment.content)")
        }
        
        if messageParts.isEmpty { return }
        let messageToSend = messageParts.joined(separator: "\n")
        
        performSend(messageToSend: messageToSend, prompt: prompt)
        
        // Clear non-persistent attachments or just deselect them
        for i in 0..<attachments.count {
            attachments[i].isSelected = false
        }
    }
    
    private func performSend(messageToSend: String, prompt: Prompt, style: ResponseStyle? = nil) {
        let newExchangeID = UUID()
        let newExchange = MessageExchange(id: newExchangeID, userMessage: messageToSend, aiResponse: "Thinking...")
        self.currentExchanges.append(newExchange)
        self.lastSentMessage = self.userInput // Save before clearing
        self.userInput = ""
        
        let currentBundleID = contextDetector.currentBundleID
        let currentAppName = contextDetector.currentAppName
        let promptName = prompt.name
        var systemPrompt = prompt.system
        
        // Apply personality constraints
        systemPrompt += "\n\nCore Constraints: You are a practical, text-based AI assistant. Focus on content output. Be simple, clear, and direct. Avoid flamboyant small talk. Do not claim to be 'omnipotent' or 'omniscient'."
        
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
        
        llmClient.sendRequest(systemPrompt: systemPrompt, messages: allMessages, sessionKey: sessionKey, onUpdate: { response in
            // If this is still the active session, update UI state
            if self.currentSessionKey == sessionKey {
                if let index = self.currentExchanges.firstIndex(where: { $0.id == newExchangeID }) {
                    // Only update if we have content, to keep "Thinking..." visible until then
                    if !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.currentExchanges[index].aiResponse = response
                    }
                }
            }
        }) { response in
            // Update the stored state first (persistence)
            if var state = self.promptStates[sessionKey] {
                if let index = state.exchanges.firstIndex(where: { $0.id == newExchangeID }) {
                    state.exchanges[index].aiResponse = response
                    self.promptStates[sessionKey] = state
                }
            }
            
            let isBackgroundCompletion = self.shouldNotifyForCompletedTask(bundleID: currentBundleID, promptID: promptID)
            
            // If this is still the active session, update UI state
            if !isBackgroundCompletion {
                if let index = self.currentExchanges.firstIndex(where: { $0.id == newExchangeID }) {
                    self.currentExchanges[index].aiResponse = response
                    self.lastFinishedExchangeID = newExchangeID
                }
            } else {
                // Background session completed
                self.unreadSessions.insert(sessionKey)
                DebugLogger.shared.log("Background task completed, sending notification for \(currentBundleID)|\(promptID).", type: .info)
                NotificationManager.shared.sendNotification(
                    title: String(format: L("Assistant Response Completed Format"), promptName),
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
    
    private func shouldNotifyForCompletedTask(bundleID: String, promptID: String) -> Bool {
        !AppDelegate.shared.isAssistantVisible || contextDetector.currentBundleID != bundleID || selectedPrompt?.id != promptID
    }
    
    private func consumePendingAssistantSwitchIfNeeded(source: String) {
        guard let target = AppDelegate.shared.consumePendingAssistantSwitch() else { return }
        handleAssistantSwitch(bundleID: target.bundleID, promptID: target.promptID, source: source)
    }
    
    private func handleAssistantSwitch(bundleID: String, promptID: String, source: String) {
        let availablePrompts = promptStore.getPrompts(for: bundleID)
        guard let prompt = availablePrompts.first(where: { $0.id == promptID }) else {
            DebugLogger.shared.log("Assistant switch ignored: prompt \(promptID) not found for \(bundleID) from \(source).", type: .error)
            return
        }
        
        DebugLogger.shared.log("Switching assistant from \(source) to \(bundleID)|\(promptID).", type: .info)
        
        lastPromptIDPerApp[bundleID] = promptID
        contextDetector.currentBundleID = bundleID
        updateDisplayedAppContext(bundleID: bundleID)
        switchTo(bundleID: bundleID, prompt: prompt)
    }
    
    private func updateDisplayedAppContext(bundleID: String) {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            contextDetector.currentAppName = app.localizedName ?? bundleID
            if let url = app.bundleURL {
                contextDetector.currentAppIcon = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                contextDetector.currentAppIcon = nil
            }
        } else if bundleID == "com.apple.finder" {
            contextDetector.currentAppName = "Finder"
            contextDetector.currentAppIcon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        } else if bundleID == "*" {
            contextDetector.currentAppName = L("All Apps (*)")
            contextDetector.currentAppIcon = nil
        } else {
            contextDetector.currentAppName = bundleID
            contextDetector.currentAppIcon = nil
        }
    }
    
    private func consumePendingSelectedTextIfNeeded() {
        guard window?.isVisible == true,
              let selection = AppDelegate.shared.consumeSelectedTextForAssistant(),
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        applySelectionToInput(selection)
    }
    
    private func applySelectionToInput(_ selection: String) {
        userInput = selection
        let newAttachment = Attachment(type: .selection, content: selection)
        if !attachments.contains(where: { $0.content == selection }) {
            attachments.append(newAttachment)
        }
    }
    
    private func switchTo(bundleID: String, prompt: Prompt?) {
        let oldSessionKey = self.currentSessionKey
        let oldBundleID = oldSessionKey.split(separator: "|").first.map(String.init)
        
        if !oldSessionKey.isEmpty {
            promptStates[oldSessionKey] = SessionState(
                exchanges: currentExchanges,
                lastScrollID: nil, // Reverting for now for stability
                attachments: attachments
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
        
        // Carry over attachments if switching assistants (prompts) for the same application.
        // This ensures context like clipboard stays available when changing the AI personality.
        if !oldSessionKey.isEmpty && bundleID == oldBundleID {
            // Keep current memory-resident attachments if we're in the same app context
            if self.attachments.isEmpty {
                self.attachments = state?.attachments ?? []
            }
        } else {
            self.attachments = state?.attachments ?? []
        }
    }
    
    private func syncSelectedPromptWithStore() {
        let bundleID = contextDetector.currentBundleID
        let availablePrompts = promptStore.getPrompts(for: bundleID)
        
        guard let selected = selectedPrompt else {
            if !availablePrompts.isEmpty {
                switchTo(bundleID: bundleID, prompt: bestPrompt(for: bundleID))
            }
            return
        }
        
        if let refreshed = availablePrompts.first(where: { $0.id == selected.id }) {
            if refreshed != selected {
                selectedPrompt = refreshed
                lastPromptIDPerApp[bundleID] = refreshed.id
            }
        } else {
            switchTo(bundleID: bundleID, prompt: bestPrompt(for: bundleID))
        }
    }
    
    @State private var lastRefreshTime: Date = Date.distantPast
    
    private func refreshContext(force: Bool = false, completion: (() -> Void)? = nil) {
        // Prevent redundant refreshes (debounce)
        if !force && Date().timeIntervalSince(lastRefreshTime) < 1.0 {
            completion?()
            return
        }
        lastRefreshTime = Date()
        
        self.attachments = []
        let group = DispatchGroup()
        
        // 1. Clipboard
        if let clip = NSPasteboard.general.string(forType: .string), !clip.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            self.attachments.append(Attachment(type: .clipboard, content: clip, isSelected: true))
        }
        
        if let completion = completion {
            group.notify(queue: .main) {
                completion()
            }
        }
    }
    
    private func bestPrompt(for bundleID: String) -> Prompt? {
        let available = promptStore.getPrompts(for: bundleID)
        if let lastID = lastPromptIDPerApp[bundleID], let last = available.first(where: { $0.id == lastID }) {
            return last
        }
        return available.first
    }
    
    private func activateOrOpenApp(bundleID: String) {
        let runningApp = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
        let targetScreen = runningApp.flatMap { AppDelegate.shared.screenForApp($0) }
        
        if let runningApp = runningApp, targetScreen != nil {
            activateAppAndSwitchSpace(bundleID: bundleID, app: runningApp)
            focusAppThenReshowAssistant(bundleID: bundleID, app: runningApp, targetScreen: targetScreen, delay: 0.7)
            return
        }
        
        if let appURL = runningApp?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, _ in
                focusAppThenReshowAssistant(bundleID: bundleID, app: app, targetScreen: targetScreen, delay: 0.7)
            }
            return
        }
        
        if let runningApp = runningApp {
            activateAppAndSwitchSpace(bundleID: bundleID, app: runningApp)
        }
        focusAppThenReshowAssistant(bundleID: bundleID, app: runningApp, targetScreen: targetScreen)
    }
    
    private func activateAppAndSwitchSpace(bundleID: String, app: NSRunningApplication) {
        AppDelegate.shared.closeMenuBarAssistantPopoverIfNeeded()
        if let appURL = app.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }
        app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    }
    
    private func focusAppThenReshowAssistant(bundleID: String, app: NSRunningApplication? = nil, targetScreen: NSScreen?, delay: TimeInterval = 0.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let focusedApp = app ?? NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
            let screen = focusedApp.flatMap { AppDelegate.shared.screenForApp($0) } ?? targetScreen
            if let focusedApp {
                activateAppAndSwitchSpace(bundleID: bundleID, app: focusedApp)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                AppDelegate.shared.showAssistant(targetScreen: screen, reopenMenuBarPopover: true)
            }
        }
    }

    private var hasAnyOtherUnread: Bool {
        // Show dot if there are any unread sessions NOT currently being viewed
        unreadSessions.contains { $0 != currentSessionKey }
    }

    private var hasAnyOtherLoading: Bool {
        llmClient.loadingStates.contains { key, isLoading in
            isLoading && key != currentSessionKey
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


    private func cleanPreview(_ text: String) -> String {
        return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct AttachmentItemView: View {
    @Binding var attachment: Attachment
    @Binding var previewedAttachment: Attachment?
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 4) {
            Toggle("", isOn: $attachment.isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
            
            HStack(spacing: 4) {
                if attachment.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: attachment.type.icon)
                        .font(.system(size: 10))
                }
                
                Text(L(attachment.type.labelKey))
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundColor(attachment.isSelected ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(isHovered ? 0.15 : 0.1))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .highPriorityGesture(TapGesture().onEnded {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                attachment.isSelected.toggle()
            }
        })
        .onChangeCompatible(of: isHovered) { newValue in
            if newValue {
                if !attachment.content.isEmpty && !attachment.isLoading {
                    // Small delay to make it feel like a tooltip and avoid jitter
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if isHovered {
                            withAnimation(.easeOut(duration: 0.2)) {
                                previewedAttachment = attachment
                            }
                        }
                    }
                }
            } else {
                // Clear the shared preview state when mouse leaves
                if previewedAttachment?.id == attachment.id {
                    withAnimation(.easeIn(duration: 0.15)) {
                        previewedAttachment = nil
                    }
                }
            }
        }

    }
}

struct ResponseLineView: View {
    let line: String
    let onCopy: (String) -> Void
    
    @State private var isHovered = false
    @State private var showCheckmark = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                Color.clear.frame(height: 8)
            } else {
                Markdown(line)
                    .markdownTheme(.lineTheme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .overlay(alignment: .bottomTrailing) {
                        if isHovered {
                            HStack(spacing: 4) {
                                Button(action: {
                                    onCopy(line)
                                    withAnimation {
                                        showCheckmark = true
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        withAnimation {
                                            showCheckmark = false
                                        }
                                    }
                                }) {
                                    Image(systemName: showCheckmark ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(showCheckmark ? .green : .primary.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                                .help(L("Copy and back to App"))
                                .onHover { inside in
                                    if inside {
                                        NSCursor.pointingHand.set()
                                    } else {
                                        NSCursor.arrow.set()
                                    }
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)
                            .shadow(color: Color.black.opacity(0.1), radius: 2)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                            .padding(.bottom, 2)
                            .padding(.trailing, 2)
                        }
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

extension Theme {
    static let lineTheme = Theme()
        .paragraph {
            $0.label
                .markdownMargin(top: 0, bottom: 0)
        }
        .codeBlock {
            $0.label
                .markdownMargin(top: 0, bottom: 0)
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
            if !textView.hasMarkedText() {
                textView.string = text
            }
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
                    if textView.hasMarkedText() {
                        return false
                    }
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
