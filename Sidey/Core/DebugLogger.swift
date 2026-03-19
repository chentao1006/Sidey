import Foundation
import SwiftUI

struct LogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let message: String
    let type: LogType
    
    enum LogType: String, Codable {
        case info, error, request, response
    }
}

class DebugLogger: ObservableObject {
    static let shared = DebugLogger()
    
    @Published var logs: [LogEntry] = []
    private let maxLogs = 2000
    private let logFile: URL
    private let queue = DispatchQueue(label: "com.sidey.debuglogger", qos: .background)
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let sideyFolder = appSupport.appendingPathComponent("Sidey", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: sideyFolder.path) {
            try? FileManager.default.createDirectory(at: sideyFolder, withIntermediateDirectories: true)
        }
        
        self.logFile = sideyFolder.appendingPathComponent("debug_logs.json")
        loadLogs()
    }
    
    private func loadLogs() {
        queue.async {
            guard let data = try? Data(contentsOf: self.logFile),
                  let decoded = try? JSONDecoder().decode([LogEntry].self, from: data) else {
                return
            }
            DispatchQueue.main.async {
                self.logs = decoded
            }
        }
    }
    
    private func saveLogs() {
        let logsToSave = self.logs
        queue.async {
            if let data = try? JSONEncoder().encode(logsToSave) {
                try? data.write(to: self.logFile)
            }
        }
    }
    
    func log(_ message: String, type: LogEntry.LogType = .info) {
        DispatchQueue.main.async {
            let entry = LogEntry(id: UUID(), timestamp: Date(), message: message, type: type)
            self.logs.insert(entry, at: 0)
            
            if self.logs.count > self.maxLogs {
                self.logs.removeLast()
            }
            
            self.saveLogs()
            
            // Print to console as well
            print("[\(type.rawValue.uppercased())] \(message)")
        }
    }
    
    func clear() {
        DispatchQueue.main.async {
            self.logs = []
            self.queue.async {
                try? FileManager.default.removeItem(at: self.logFile)
            }
        }
    }
}
