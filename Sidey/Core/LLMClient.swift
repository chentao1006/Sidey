import Foundation
import CryptoKit

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool?
}

struct ChatResponse: Codable {
    struct Choice: Codable {
        let message: ChatMessage
    }
    let choices: [Choice]
}

struct ChatStreamResponse: Codable {
    struct Choice: Codable {
        struct Delta: Codable {
            let content: String?
        }
        let delta: Delta
        let finish_reason: String?
    }
    let choices: [Choice]
}


class LLMClient: ObservableObject {
    @Published var loadingStates: [String: Bool] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]
    
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()
    
    // The secret is stored in Config.xcconfig and mapped to Info.plist via $(SERVICE_SECRET)
    private var serviceSecret: String {
        return Bundle.main.infoDictionary?["ServiceSecret"] as? String ?? ""
    }
    
    private func getDeviceId() -> String {
        if let id = UserDefaults.standard.string(forKey: "deviceId") {
            return id
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceId")
        return id
    }
    
    private func generateToken(deviceId: String) -> String {
        let hour = Int(Date().timeIntervalSince1970 / 3600)
        let input = serviceSecret + deviceId + "\(hour)"
        let digest = Insecure.MD5.hash(data: input.data(using: .utf8) ?? Data())
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
    
    func stopRequest(sessionKey: String) {
        activeTasks[sessionKey]?.cancel()
        activeTasks.removeValue(forKey: sessionKey)
        DispatchQueue.main.async {
            self.loadingStates[sessionKey] = false
        }
    }

    func sendRequest(systemPrompt: String, messages: [ChatMessage], sessionKey: String = "", onUpdate: @escaping (String) -> Void, completion: @escaping (String) -> Void) {
        performRequest(systemPrompt: systemPrompt, messages: messages, sessionKey: sessionKey, retryCount: 1, onUpdate: onUpdate, completion: completion)
    }
    
    private func performRequest(systemPrompt: String, messages: [ChatMessage], sessionKey: String, retryCount: Int, onUpdate: @escaping (String) -> Void, completion: @escaping (String) -> Void) {
        let apiKey = UserDefaults.standard.string(forKey: "openAI_APIKey") ?? ""
        let usePublicService = UserDefaults.standard.bool(forKey: "usePublicService")
        
        guard usePublicService || !apiKey.isEmpty else {
            completion("Error: API Key not set. Please set it in Settings (Cmd+,).")
            return
        }
        
        let publicServiceURL = Bundle.main.infoDictionary?["PublicServiceURL"] as? String ?? ""
        let finalURL: URL?
        
        if usePublicService {
            let suffix = "/chat/completions"
            var cleanURL = publicServiceURL
            if cleanURL.hasSuffix("/") {
                cleanURL.removeLast()
            }
            finalURL = URL(string: "https://" + cleanURL + suffix)
        } else {
            var baseURLStr = UserDefaults.standard.string(forKey: "openAI_BaseURL") ?? "https://api.openai.com/v1"
            if baseURLStr.isEmpty {
                baseURLStr = "https://api.openai.com/v1"
            }
            
            let suffix = "/chat/completions"
            var cleanBaseURL = baseURLStr
            if cleanBaseURL.hasSuffix("/") {
                cleanBaseURL.removeLast()
            }
            let finalURLStr = cleanBaseURL.hasSuffix(suffix) ? cleanBaseURL : cleanBaseURL + suffix
            finalURL = URL(string: finalURLStr)
            DebugLogger.shared.log("Requesting: \(finalURLStr)", type: .request)
        }
        
        guard let url = finalURL else {
            completion("Error: Invalid URL.")
            return
        }
        
        
        var request = URLRequest(url: url)
        if usePublicService {
            let deviceId = getDeviceId()
            let token = generateToken(deviceId: deviceId)
            request.addValue(deviceId, forHTTPHeaderField: "X-Device-Id")
            request.addValue(token, forHTTPHeaderField: "X-Token")
        } else {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        
        let model = UserDefaults.standard.string(forKey: "openAI_Model") ?? "gpt-4o-mini"
        
        var fullMessages = [ChatMessage(role: "system", content: systemPrompt)]
        fullMessages.append(contentsOf: messages)
        
        let chatRequest = ChatRequest(
            model: model,
            messages: fullMessages,
            stream: true
        )
        
        do {
            request.httpBody = try JSONEncoder().encode(chatRequest)
        } catch {
            completion("Failed to encode request: \(error.localizedDescription)")
            return
        }
        
        DispatchQueue.main.async {
            self.loadingStates[sessionKey] = true
        }
        
        let task = Task {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    var bodyContent = ""
                    for try await line in bytes.lines {
                        bodyContent += line
                    }
                    let statusMessage = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                    DebugLogger.shared.log("API Error (\(httpResponse.statusCode)): \(bodyContent)", type: .error)
                    DispatchQueue.main.async {
                        self.loadingStates[sessionKey] = false
                        completion("API Error (\(httpResponse.statusCode) \(statusMessage)): \(bodyContent)")
                    }
                    return
                }
                
                var fullResponse = ""
                
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    
                    if line.hasPrefix("data: ") {
                        let dataStr = line.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
                        if dataStr == "[DONE]" {
                            break
                        }
                        
                        if let data = dataStr.data(using: .utf8) {
                            do {
                                let streamResponse = try JSONDecoder().decode(ChatStreamResponse.self, from: data)
                                if let content = streamResponse.choices.first?.delta.content {
                                    fullResponse += content
                                    DispatchQueue.main.async {
                                        onUpdate(fullResponse)
                                    }
                                }
                            } catch {
                                // Skip parsing errors for non-json lines
                            }
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.activeTasks.removeValue(forKey: sessionKey)
                    self.loadingStates[sessionKey] = false
                    completion(fullResponse)
                }
                
            } catch {
                if (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                
                if retryCount > 0 {
                    let nsError = error as NSError
                    if nsError.code == NSURLErrorNetworkConnectionLost || nsError.code == NSURLErrorCannotConnectToHost {
                        DebugLogger.shared.log("Network error, retrying... \(error.localizedDescription)", type: .error)
                        self.performRequest(systemPrompt: systemPrompt, messages: messages, sessionKey: sessionKey, retryCount: retryCount - 1, onUpdate: onUpdate, completion: completion)
                        return
                    }
                }
                
                DebugLogger.shared.log("Streaming error: \(error.localizedDescription)", type: .error)
                DispatchQueue.main.async {
                    self.activeTasks.removeValue(forKey: sessionKey)
                    self.loadingStates[sessionKey] = false
                    completion("Network error: \(error.localizedDescription)")
                }
            }
        }
        
        activeTasks[sessionKey] = task
    }
}
