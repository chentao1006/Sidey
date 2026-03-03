import Foundation
import Combine

public struct Interaction: Codable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var appBundleID: String
    public var appName: String
    public var promptName: String
    public var systemPrompt: String
    public var userMessage: String
    public var aiResponse: String
    
    public init(id: UUID = UUID(), timestamp: Date = Date(), appBundleID: String, appName: String, promptName: String, systemPrompt: String, userMessage: String, aiResponse: String) {
        self.id = id
        self.timestamp = timestamp
        self.appBundleID = appBundleID
        self.appName = appName
        self.promptName = promptName
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.aiResponse = aiResponse
    }
}

public class HistoryStore: ObservableObject {
    public static let shared = HistoryStore()
    
    @Published public var interactions: [Interaction] = []
    
    private let fileURL: URL
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("Sidey", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: appDir.path) {
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        self.fileURL = appDir.appendingPathComponent("history.json")
        loadHistory()
    }
    
    public func addInteraction(_ interaction: Interaction) {
        DispatchQueue.main.async {
            self.interactions.insert(interaction, at: 0)
            
            // Retain up to 2000 records to prevent infinite file size growth
            if self.interactions.count > 2000 {
                self.interactions.removeLast(self.interactions.count - 2000)
            }
            
            self.saveHistory()
        }
    }
    
    private func loadHistory() {
        if !FileManager.default.fileExists(atPath: fileURL.path) { return }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([Interaction].self, from: data)
            DispatchQueue.main.async {
                self.interactions = decoded
            }
        } catch {
            print("Failed to load interaction history: \(error)")
        }
    }
    
    public func saveHistory() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = .prettyPrinted
            let data = try enc.encode(interactions)
            try data.write(to: fileURL)
        } catch {
            print("Failed to save interaction history: \(error)")
        }
    }
    
    public func clearHistory() {
        DispatchQueue.main.async {
            self.interactions.removeAll()
            self.saveHistory()
        }
    }
}
