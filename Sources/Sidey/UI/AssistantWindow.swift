import SwiftUI
import AppKit
import MarkdownUI

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
    @AppStorage("autoPasteClipboard") private var autoPasteClipboard = false
    @AppStorage("appLanguage") private var appLanguage = "system"
    
    @State private var window: NSWindow?
    
    @State private var selectedPrompt: Prompt?
    @State private var userInput: String = ""
    @State private var aiResponse: String = ""
    @State private var copied: Bool = false
    @State private var promptStates: [String: (input: String, response: String)] = [:]
    @State private var currentSessionKey: String = ""
    @State private var unreadSessions: Set<String> = []
    @State private var textToInsert: String? = nil
    @State private var showAutoPasteTip: Bool = false
    @State private var textBeforeAutoPaste: String = ""
    @State private var autoPasteSessionKey: String = ""
    
    @State private var lastPasteboardChangeCount: Int = NSPasteboard.general.changeCount
    
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 16) {
                appContextHeader
                promptList
                inputArea
                responseArea
            }
            .padding()
        }
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
            let availablePrompts = promptStore.getPrompts(for: newValue)
            if !availablePrompts.isEmpty {
                switchTo(bundleID: newValue, prompt: availablePrompts.first)
            } else {
                switchTo(bundleID: newValue, prompt: nil)
            }
        }
        .onAppear {
            let availablePrompts = promptStore.getPrompts(for: contextDetector.currentBundleID)
            if !availablePrompts.isEmpty {
                switchTo(bundleID: contextDetector.currentBundleID, prompt: availablePrompts.first)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
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
                switchTo(bundleID: contextDetector.currentBundleID, prompt: availablePrompts.first)
            }
            
            if autoPasteClipboard {
                let currentChangeCount = NSPasteboard.general.changeCount
                if currentChangeCount != lastPasteboardChangeCount {
                    if let newText = NSPasteboard.general.string(forType: .string),
                       !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        textBeforeAutoPaste = userInput
                        autoPasteSessionKey = currentSessionKey
                        textToInsert = newText
                        withAnimation {
                            showAutoPasteTip = true
                        }
                    }
                    lastPasteboardChangeCount = currentChangeCount
                }
            }
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
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private var appContextHeader: some View {
        HStack(spacing: 8) {
            Button(action: {
                if !contextDetector.currentBundleID.isEmpty {
                    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: contextDetector.currentBundleID).first {
                        app.activate(options: .activateIgnoringOtherApps)
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
            
            Menu {
                Text(L("Recent Apps"))
                let recent = filteredRecentApps
                if recent.isEmpty {
                    Text(L("None"))
                } else {
                    ForEach(recent) { appCtx in
                        Button {
                            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == appCtx.bundleID }) {
                                app.activate(options: .activateIgnoringOtherApps)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    AppDelegate.shared.showAssistant()
                                }
                            }
                        } label: {
                            Text(appCtx.appName)
                        }
                    }
                }
                
                Divider()
                Text(L("Running Apps"))
                let running = filteredRunningApps
                if running.isEmpty {
                    Text(L("None"))
                } else {
                    ForEach(running, id: \.bundleIdentifier) { app in
                        Button {
                            app.activate(options: .activateIgnoringOtherApps)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                AppDelegate.shared.showAssistant()
                            }
                        } label: {
                            if let name = app.localizedName {
                                Text(name)
                            } else {
                                Text(app.bundleIdentifier ?? "Unknown")
                            }
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
                                            .fill(Color.red)
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
                .frame(height: 80)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            
            HStack(spacing: 8) {
                Button(action: {
                    self.userInput = ""
                    self.aiResponse = ""
                    self.showAutoPasteTip = false
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Clear Input"))
                .opacity(userInput.isEmpty && aiResponse.isEmpty ? 0 : 1)
                
                if showAutoPasteTip && autoPasteSessionKey == currentSessionKey {
                    HStack(spacing: 4) {
                        Text(L("Automatically pasted from clipboard"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Button(action: {
                            userInput = textBeforeAutoPaste
                            withAnimation {
                                showAutoPasteTip = false
                            }
                        }) {
                            Text(L("Undo"))
                                .font(.caption)
                                .foregroundColor(.accentColor)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: {
                            withAnimation {
                                showAutoPasteTip = false
                            }
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .transition(.opacity)
                }
                
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
                .disabled(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedPrompt == nil || llmClient.loadingStates[currentSessionKey] == true)
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
                                self.userInput = interaction.userMessage
                                self.aiResponse = interaction.aiResponse
                                self.promptStates[self.currentSessionKey] = (input: interaction.userMessage, response: interaction.aiResponse)
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
                ScrollView {
                    if aiResponse.isEmpty {
                        Text(L("Output will appear here..."))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if aiResponse == "Thinking..." {
                        Text(L("Thinking..."))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Markdown(aiResponse)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
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
            if !aiResponse.isEmpty && aiResponse != "Thinking..." {
                HStack(spacing: 8) {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(aiResponse, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copied = false
                        }
                    }) {
                        Label(copied ? L("Copied!") : L("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help(L("Copy"))
                    
                    Button(action: sendMessage) {
                        Label(L("Retry"), systemImage: "arrow.clockwise")
                    }
                    .help(L("Retry"))
                    
                    if !contextDetector.currentBundleID.isEmpty {
                        Button(action: {
                            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: contextDetector.currentBundleID).first {
                                app.activate(options: .activateIgnoringOtherApps)
                            }
                        }) {
                            Label(L("Back to App"), systemImage: "arrow.uturn.backward")
                        }
                        .help(L("Back to App"))
                    }
                    
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
    
    private func sendMessage() {
        guard let prompt = selectedPrompt else { return }
        
        let messageToSend = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if messageToSend.isEmpty { return }
        
        aiResponse = "Thinking..."
        
        let currentBundleID = contextDetector.currentBundleID
        let currentAppName = contextDetector.currentAppName
        let promptName = prompt.name
        let systemPrompt = prompt.system
        let promptID = prompt.id
        
        let sessionKey = self.currentSessionKey
        promptStates[sessionKey] = (input: userInput, response: aiResponse)
        
        llmClient.sendRequest(systemPrompt: systemPrompt, userMessage: messageToSend, sessionKey: sessionKey) { response in
            var entry = self.promptStates[sessionKey] ?? (input: messageToSend, response: "")
            entry.response = response
            self.promptStates[sessionKey] = entry
            
            if self.currentSessionKey == sessionKey {
                self.aiResponse = response
            } else {
                self.unreadSessions.insert(sessionKey)
                NotificationManager.shared.sendNotification(
                    title: "\(promptName) " + L("Response Completed"),
                    body: response,
                    bundleID: currentBundleID,
                    promptID: promptID
                )
            }
            
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
            promptStates[currentSessionKey] = (input: userInput, response: aiResponse)
        }
        self.selectedPrompt = prompt
        let newKey = "\(bundleID)|\(prompt?.id ?? "")"
        self.currentSessionKey = newKey
        self.unreadSessions.remove(newKey)
        
        let state = promptStates[newKey] ?? (input: "", response: "")
        self.userInput = state.input
        self.aiResponse = state.response
    }
    
    private var activePIDs: Set<Int32> {
        var pids = Set<Int32>()
        if let windowList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for window in windowList {
                if let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                   let pid = window[kCGWindowOwnerPID as String] as? Int32 {
                    if let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                       let bounds = CGRect(dictionaryRepresentation: boundsDict) {
                        if bounds.height > 20 {
                            pids.insert(pid)
                        }
                    }
                }
            }
        }
        return pids
    }
    
    private var filteredRecentApps: [ContextDetector.AppContext] {
        let pids = activePIDs
        let currentID = contextDetector.currentBundleID
        return contextDetector.recentApps.filter { appCtx in
            appCtx.bundleID != currentID &&
            NSWorkspace.shared.runningApplications.contains(where: { 
                $0.bundleIdentifier == appCtx.bundleID && pids.contains($0.processIdentifier) 
            })
        }
    }
    
    private var filteredRunningApps: [NSRunningApplication] {
        let pids = activePIDs
        let recentIDs = Set(filteredRecentApps.map { $0.bundleID })
        let currentID = contextDetector.currentBundleID
        return NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular &&
            app.bundleIdentifier != nil &&
            app.bundleIdentifier != currentID &&
            !recentIDs.contains(app.bundleIdentifier!) &&
            app.bundleIdentifier != Bundle.main.bundleIdentifier &&
            pids.contains(app.processIdentifier)
        }
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
            // If the textView is not the first responder, we might want to make it one 
            // or at least ensure we are inserting at the right place.
            textView.insertText(toInsert, replacementRange: textView.selectedRange())
            
            // Critical: Update the bound text immediately so the next sync doesn't revert it
            let newText = textView.string
            
            DispatchQueue.main.async {
                self.text = newText
                self.textToInsert = nil
            }
            return // Skip the regular sync this time
        }
        
        if textView.string != text {
            textView.string = text
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacTextEditor

        init(_ parent: MacTextEditor) {
            self.parent = parent
        }

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
