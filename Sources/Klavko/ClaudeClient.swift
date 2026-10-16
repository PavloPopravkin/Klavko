import Foundation
import KlavkoCore

/// Sends one request to the Claude Messages API (raw HTTP: there is no official Swift SDK).
enum ClaudeClient {
    enum Failure: LocalizedError {
        case noKey
        case http(status: Int, message: String)
        case refused
        case empty
        case network(String)

        var errorDescription: String? {
            switch self {
            case .noKey:
                "Не задано API-ключ Anthropic. Додайте його в налаштуваннях Klavko, розділ «ШІ»."
            case .http(401, _):
                "API-ключ не прийнято. Перевірте його в налаштуваннях."
            case .http(429, _):
                "Забагато запитів або вичерпано ліміт. Спробуйте трохи пізніше."
            case .http(let status, let message):
                "Помилка сервера (\(status)): \(message)"
            case .refused:
                "Модель відмовилася обробляти цей текст."
            case .empty:
                "Модель повернула порожню відповідь."
            case .network(let message):
                "Немає зв'язку з Anthropic: \(message)"
            }
        }
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// The text of Claude's reply to `instruction` applied to `text`.
    static func edit(text: String, instruction: String, model: AIModel, apiKey: String?) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw Failure.noKey }

        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 16000,
            // Quick edits of short text: low effort keeps them fast.
            "output_config": ["effort": "low"],
            "system": AIPrompt.system,
            "messages": [["role": "user", "content": AIPrompt.message(instruction: instruction, text: text)]],
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if model.supportsFallback {
            // If the model's safeguards decline, the API retries on a suitable model within the same call.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "невідома помилка"
            throw Failure.http(status: status, message: message)
        }
        if json["stop_reason"] as? String == "refusal" { throw Failure.refused }

        // Thinking blocks come back too; only the text blocks are the answer.
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }
        return text
    }
}
