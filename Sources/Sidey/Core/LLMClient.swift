import Foundation

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
    
    func sendRequest(systemPrompt: String, userMessage: String, sessionKey: String = "", completion: @escaping (String) -> Void) {
        let apiKey = UserDefaults.standard.string(forKey: "openAI_APIKey") ?? ""
        var baseURLStr = UserDefaults.standard.string(forKey: "openAI_BaseURL") ?? "https://api.openai.com/v1"
        if baseURLStr.isEmpty {
            baseURLStr = "https://api.openai.com/v1"
        }
        
        let suffix = "/chat/completions"
        if baseURLStr.hasSuffix("/") {
            baseURLStr.removeLast()
        }
        let finalURLStr = baseURLStr.hasSuffix(suffix) ? baseURLStr : baseURLStr + suffix
        
        guard !apiKey.isEmpty else {
            completion("Error: API Key not set. Please set it in Settings (Cmd+,).")
            return
        }
        
        guard let url = URL(string: finalURLStr) else {
            completion("Error: Invalid Base URL (\(finalURLStr)).")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120 // 2 minute timeout for generating large completions
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let chatRequest = ChatRequest(
            model: "gpt-4o-mini",
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userMessage)
            ]
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
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.loadingStates[sessionKey] = false
            }
            
            if let error = error {
                DispatchQueue.main.async {
                    completion("Network error: \(error.localizedDescription)")
                }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async {
                    completion("No data received from API.")
                }
                return
            }
            
            do {
                let responseDecoded = try JSONDecoder().decode(ChatResponse.self, from: data)
                if let firstResponse = responseDecoded.choices.first?.message.content {
                    DispatchQueue.main.async {
                        completion(firstResponse)
                    }
                } else {
                    DispatchQueue.main.async {
                        completion("No content in response.")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if let rawResponse = String(data: data, encoding: .utf8) {
                        completion("API Error or parsing failed: \(rawResponse)")
                    } else {
                        completion("Failed to decode response: \(error.localizedDescription)")
                    }
                }
            }
        }
        task.resume()
    }
}
