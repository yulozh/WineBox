import Foundation

/// AI Agent：调用任意 OpenAI 兼容的 Chat Completions 接口（OpenAI / DeepSeek / 其他）。
/// API Key 存 Keychain，不在请求日志中暴露。
final class AIService {

    struct AIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 非流式对话。messages 中的 system 用于约束 AI 的角色与行为。
    func chat(messages: [ChatMessage], config: AIConfig, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else { throw AIError(message: "请先在设置中配置 API Key") }

        // 组装 OpenAI 兼容请求体
        let body: [String: Any] = [
            "model": config.model,
            "messages": messages.map(\.apiDict),
            "temperature": 0.2
        ]
        guard let url = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw AIError(message: "baseURL 不合法")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "HTTP 错误"
            throw AIError(message: text)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError(message: "响应格式无法解析")
        }
        return content
    }

    /// 从 AI 回复中抽取首个 ``` 代码块的内容；若无代码块则返回原文。
    func extractCodeBlock(_ text: String) -> (code: String, language: String?) {
        let pattern = #"```([a-zA-Z0-9_+-]*)\n([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return (text, nil)
        }
        if let langRange = Range(match.range(at: 1), in: text),
           let codeRange = Range(match.range(at: 2), in: text) {
            let lang = String(text[langRange])
            return (String(text[codeRange]), lang.isEmpty ? nil : lang)
        }
        return (text, nil)
    }
}