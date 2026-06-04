import Foundation
import CryptoKit
import Combine

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
            let role: String?
        }
        let delta: Delta
        let finish_reason: String?
    }
    let choices: [Choice]
}

struct AnthropicRequest: Codable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [ChatMessage]
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case stream
    }
}

struct GeminiRequest: Codable {
    struct Part: Codable {
        let text: String
    }

    struct Content: Codable {
        let role: String?
        let parts: [Part]
    }

    let systemInstruction: Content
    let contents: [Content]

    enum CodingKeys: String, CodingKey {
        case systemInstruction = "system_instruction"
        case contents
    }
}


class LLMClient: ObservableObject {
    @Published var loadingStates: [String: Bool] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private let decoder = JSONDecoder()
    
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
        // Cancel existing task synchronously to avoid race condition with the new task
        activeTasks[sessionKey]?.cancel()
        activeTasks.removeValue(forKey: sessionKey)
        
        performRequest(systemPrompt: systemPrompt, messages: messages, sessionKey: sessionKey, retryCount: 1, onUpdate: onUpdate, completion: completion)
    }
    
    private func performRequest(systemPrompt: String, messages: [ChatMessage], sessionKey: String, retryCount: Int, onUpdate: @escaping (String) -> Void, completion: @escaping (String) -> Void) {
        let apiKey = UserDefaults.standard.string(forKey: "openAI_APIKey") ?? ""
        let usePublicService = UserDefaults.standard.bool(forKey: "usePublicService")
        let apiFormat = usePublicService ? "openai" : (UserDefaults.standard.string(forKey: "openAI_APIFormat") ?? "openai")
        
        guard usePublicService || apiFormat == "ollama" || !apiKey.isEmpty else {
            completion("Error: API Key not set. Please set it in Settings (Cmd+,).")
            return
        }
        
        let publicServiceURL = Bundle.main.infoDictionary?["PublicServiceURL"] as? String ?? ""
        let model = UserDefaults.standard.string(forKey: "openAI_Model") ?? "gpt-4o-mini"
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
            
            let finalURLStr = requestURLString(baseURL: baseURLStr, model: model, apiFormat: apiFormat)
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
        } else if apiFormat == "anthropic" {
            request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if apiFormat == "gemini" {
            request.addValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        } else if !apiKey.isEmpty {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        
        do {
            request.httpBody = try requestBody(systemPrompt: systemPrompt, messages: messages, model: model, apiFormat: apiFormat)
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
                var isSSE = false
                
                if let httpResponse = response as? HTTPURLResponse {
                    // Use case-insensitive header access
                    let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                    isSSE = contentType.contains("event-stream")
                }
                
                if isSSE {
                    var lineData = Data()
                    let doneBytes1 = Data("data:[DONE]".utf8)
                    let doneBytes2 = Data("data: [DONE]".utf8)
                    
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        
                        lineData.append(byte)
                        
                        // Eagerly check for [DONE] ignoring missing newlines
                        if lineData.suffix(doneBytes1.count) == doneBytes1 || lineData.suffix(doneBytes2.count) == doneBytes2 {
                            DebugLogger.shared.log("Stream finished with [DONE]", type: .info)
                            break
                        }
                        
                        if byte == 10 { // \n
                            if let lineBuffer = String(data: lineData, encoding: .utf8) {
                                let trimmedLine = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                                lineData.removeAll()
                                
                                if trimmedLine.isEmpty { continue }
                                
                                if trimmedLine.hasPrefix("data:") {
                                    let cleanDataStr = trimmedLine.hasPrefix("data: ") ? String(trimmedLine.dropFirst(6)) : String(trimmedLine.dropFirst(5))
                                    let finalStr = cleanDataStr.trimmingCharacters(in: .whitespacesAndNewlines)
                                    
                                    if let content = self.parseStreamContent(finalStr, apiFormat: apiFormat) {
                                        fullResponse += content
                                        DispatchQueue.main.async {
                                            onUpdate(fullResponse)
                                        }
                                    }
                                } else {
                                    DebugLogger.shared.log("Non-data SSE line: \(trimmedLine)", type: .info)
                                }
                            } else {
                                lineData.removeAll() // Clear if bad UTF-8 data
                            }
                        }
                    }
                } else {
                    // Fallback for non-SSE responses - read all data first then process
                    var collectedData = Data()
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        collectedData.append(byte)
                        if apiFormat == "ollama", byte == 10 {
                            if let line = String(data: collectedData, encoding: .utf8),
                               let content = self.parseStreamContent(line.trimmingCharacters(in: .whitespacesAndNewlines), apiFormat: apiFormat) {
                                fullResponse += content
                                collectedData.removeAll()
                                DispatchQueue.main.async {
                                    onUpdate(fullResponse)
                                }
                            }
                        }
                    }
                    
                    if !collectedData.isEmpty {
                        if apiFormat == "ollama" {
                            if let line = String(data: collectedData, encoding: .utf8),
                               let content = self.parseStreamContent(line.trimmingCharacters(in: .whitespacesAndNewlines), apiFormat: apiFormat) {
                                fullResponse += content
                                DispatchQueue.main.async {
                                    onUpdate(fullResponse)
                                }
                            }
                        } else if let content = self.parseResponseContent(collectedData, apiFormat: apiFormat) {
                            fullResponse = content
                            DispatchQueue.main.async {
                                onUpdate(fullResponse)
                            }
                        } else {
                            if let bodyContent = String(data: collectedData, encoding: .utf8) {
                                DebugLogger.shared.log("Non-SSE parse failed for \(apiFormat)", type: .error)
                                fullResponse = bodyContent
                            }
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    if !Task.isCancelled {
                        self.activeTasks.removeValue(forKey: sessionKey)
                        self.loadingStates[sessionKey] = false
                        completion(fullResponse)
                    }
                }
                
            } catch {
                if (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                
                if retryCount > 0 {
                    let nsError = error as NSError
                    if nsError.code == NSURLErrorNetworkConnectionLost || nsError.code == NSURLErrorCannotConnectToHost {
                        DebugLogger.shared.log("Network error, retrying...", type: .error)
                        self.performRequest(systemPrompt: systemPrompt, messages: messages, sessionKey: sessionKey, retryCount: retryCount - 1, onUpdate: onUpdate, completion: completion)
                        return
                    }
                }
                
                DebugLogger.shared.log("Streaming error: \(error.localizedDescription)", type: .error)
                DispatchQueue.main.async {
                    if !Task.isCancelled {
                        self.activeTasks.removeValue(forKey: sessionKey)
                        self.loadingStates[sessionKey] = false
                        completion("Network error: \(error.localizedDescription)")
                    }
                }
            }
        }
        
        activeTasks[sessionKey] = task
    }

    private func requestURLString(baseURL: String, model: String, apiFormat: String) -> String {
        let cleanBaseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch apiFormat {
        case "anthropic":
            let suffix = "/v1/messages"
            return cleanBaseURL.hasSuffix(suffix) ? cleanBaseURL : cleanBaseURL + suffix
        case "gemini":
            let suffix = ":streamGenerateContent?alt=sse"
            if cleanBaseURL.contains(":streamGenerateContent") || cleanBaseURL.contains(":generateContent") {
                return cleanBaseURL
            }
            let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            return cleanBaseURL + "/models/\(encodedModel)" + suffix
        case "ollama":
            let suffix = "/api/chat"
            return cleanBaseURL.hasSuffix(suffix) ? cleanBaseURL : cleanBaseURL + suffix
        default:
            let suffix = "/chat/completions"
            return cleanBaseURL.hasSuffix(suffix) ? cleanBaseURL : cleanBaseURL + suffix
        }
    }

    private func requestBody(systemPrompt: String, messages: [ChatMessage], model: String, apiFormat: String) throws -> Data {
        switch apiFormat {
        case "anthropic":
            let request = AnthropicRequest(
                model: model,
                maxTokens: 4096,
                system: systemPrompt,
                messages: messages,
                stream: true
            )
            return try JSONEncoder().encode(request)
        case "gemini":
            let contents = messages.map { message in
                GeminiRequest.Content(
                    role: message.role == "assistant" ? "model" : "user",
                    parts: [GeminiRequest.Part(text: message.content)]
                )
            }
            let request = GeminiRequest(
                systemInstruction: GeminiRequest.Content(role: nil, parts: [GeminiRequest.Part(text: systemPrompt)]),
                contents: contents
            )
            return try JSONEncoder().encode(request)
        case "ollama":
            var fullMessages = [ChatMessage(role: "system", content: systemPrompt)]
            fullMessages.append(contentsOf: messages)
            let request = ChatRequest(model: model, messages: fullMessages, stream: true)
            return try JSONEncoder().encode(request)
        default:
            var fullMessages = [ChatMessage(role: "system", content: systemPrompt)]
            fullMessages.append(contentsOf: messages)
            let request = ChatRequest(model: model, messages: fullMessages, stream: true)
            return try JSONEncoder().encode(request)
        }
    }

    private func parseStreamContent(_ jsonString: String, apiFormat: String) -> String? {
        guard !jsonString.isEmpty, jsonString != "[DONE]" else { return nil }
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            DebugLogger.shared.log("Stream parsing failed for \(apiFormat): \(jsonString)", type: .error)
            return nil
        }

        switch apiFormat {
        case "anthropic":
            if let delta = object["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                return text
            }
        case "gemini":
            if let candidates = object["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }.joined()
            }
        case "ollama":
            if let message = object["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
        default:
            if let choices = object["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String {
                return content
            }
        }

        return nil
    }

    private func parseResponseContent(_ data: Data, apiFormat: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        switch apiFormat {
        case "anthropic":
            if let content = object["content"] as? [[String: Any]] {
                return content.compactMap { $0["text"] as? String }.joined()
            }
        case "gemini":
            if let candidates = object["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }.joined()
            }
        case "ollama":
            if let message = object["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
        default:
            if let choices = object["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
        }

        return nil
    }
}
