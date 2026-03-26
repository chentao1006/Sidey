import Foundation
import CryptoKit

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatRequest: Codable {
    let model: String
    let messages: [ChatMessage]
}

struct ChatResponse: Codable {
    struct Choice: Codable {
        let message: ChatMessage
    }
    let choices: [Choice]
}


class LLMClient: ObservableObject {
    @Published var loadingStates: [String: Bool] = [:]
    
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
    

    func sendRequest(systemPrompt: String, messages: [ChatMessage], sessionKey: String = "", completion: @escaping (String) -> Void) {
        performRequest(systemPrompt: systemPrompt, messages: messages, sessionKey: sessionKey, retryCount: 1, completion: completion)
    }
    
    private func performRequest(systemPrompt: String, messages: [ChatMessage], sessionKey: String, retryCount: Int, completion: @escaping (String) -> Void) {
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
            messages: fullMessages
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
        
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                let nsError = error as NSError
                // URLError.networkConnectionLost (-1005) or POSIXError.ECONNRESET
                if retryCount > 0 && (nsError.code == NSURLErrorNetworkConnectionLost || nsError.code == NSURLErrorCannotConnectToHost) {
                    DebugLogger.shared.log("Network error (code: \(nsError.code)), retrying... \(nsError.localizedDescription)", type: .error)
                    self.performRequest(systemPrompt: systemPrompt, messages: messages, sessionKey: sessionKey, retryCount: retryCount - 1, completion: completion)
                    return
                }
                
                DebugLogger.shared.log("Network error: \(nsError.localizedDescription) (Code: \(nsError.code))", type: .error)
                DispatchQueue.main.async {
                    self.loadingStates[sessionKey] = false
                    completion("Network error: \(error.localizedDescription)")
                }
                return
            }
            
            DebugLogger.shared.log("Received response (status: \((response as? HTTPURLResponse)?.statusCode ?? 0))", type: .response)
            
            let finishLoading = {
                DispatchQueue.main.async {
                    self.loadingStates[sessionKey] = false
                }
            }
            
            guard let data = data else {
                DispatchQueue.main.async {
                    completion("No data received from API.")
                    finishLoading()
                }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                let statusMessage = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                let body = String(data: data, encoding: .utf8) ?? "No body"
                DebugLogger.shared.log("API Error (\(httpResponse.statusCode)): \(body)", type: .error)
                DispatchQueue.main.async {
                    completion("API Error (\(httpResponse.statusCode) \(statusMessage)): \(body)")
                    finishLoading()
                }
                return
            }
            
            do {
                let responseDecoded = try JSONDecoder().decode(ChatResponse.self, from: data)
                if let firstResponse = responseDecoded.choices.first?.message.content {
                    DispatchQueue.main.async {
                        completion(firstResponse)
                        finishLoading()
                    }
                } else {
                    DispatchQueue.main.async {
                        completion("No content in response.")
                        finishLoading()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if let rawResponse = String(data: data, encoding: .utf8) {
                        completion("Parsing failed. Raw response: \(rawResponse)")
                    } else {
                        completion("Failed to decode response: \(error.localizedDescription)")
                    }
                    finishLoading()
                }
            }
        }
        task.resume()
    }
}
