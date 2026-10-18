// Speech to text through the Google AI (Gemini) API — the optional second recognizer.
//
// The request shapes, the endpoint quirks and the FLAC step are taken from Jot
// (https://github.com/ammaarreshi/jot, JotCore/Sources/TranscriptionClient), Copyright 2026 Google LLC,
// licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).
// Changed for Klavko: one file, no retry queue or cleanup pass, the model is picked from the key's catalog.

import AVFoundation
import Foundation
import KlavkoCore
import Security

/// Recognizes a finished recording with Google AI. Audio leaves the Mac only when the user turned this on
/// and entered their own API key.
final class GeminiTranscriber: @unchecked Sendable {
    enum Failure: LocalizedError {
        case noKey, rejectedKey(String?), unreachable, quota, noModel, server(String)

        var errorDescription: String? {
            switch self {
            case .noKey: tr("Немає ключа Google AI.", "No Google AI key.")
            case .rejectedKey(let detail): tr("Google не прийняв ключ.", "Google rejected the key.") + (detail.map { " " + $0 } ?? "")
            case .unreachable: tr("Немає з’єднання з Google AI.", "Can’t reach Google AI.")
            case .quota: tr("Вичерпано ліміт ключа Google AI.", "The Google AI key is out of quota.")
            case .noModel: tr("Цьому ключу недоступна модель розпізнавання мовлення.", "No speech recognition model is available to this key.")
            case .server(let detail): detail
            }
        }
    }

    private static let endpoint = URL(string: "https://generativelanguage.googleapis.com")!
    /// Last resort only: the model is normally picked from what the key can reach (models get renamed).
    static let fallbackModel = "gemini-3.5-transcribe"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    // MARK: - Transcribing

    /// The text of `file` (the recording, CAF). `smart`: the model drops fillers ("ну", "е-е") and
    /// self-corrections; otherwise word for word. `vocabulary`: words to recognize as written.
    func transcribe(file: URL, key: String, model: String, smart: Bool, vocabulary: [String]) async throws -> String {
        guard !key.isEmpty else { throw Failure.noKey }
        let flac = try Self.flac(from: file)
        let duration = (try? AVAudioFile(forReading: file)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 10
        let deadline = 30 + duration / 4
        do {
            return try await interaction(flac, key: key, model: model, smart: smart, vocabulary: vocabulary, deadline: deadline)
        } catch Failure.server(let detail) where detail.hasPrefix("interactions") {
            // The newer endpoint isn't open to this key: the older one, word for word only.
            return try await generateContent(flac, key: key, model: model, vocabulary: vocabulary, deadline: deadline)
        }
    }

    /// `POST v1beta/interactions`: the only endpoint where smart mode works. The model is named in the body.
    /// (Never send `language_codes` with smart mode: the API then silently answers word for word.)
    private func interaction(_ flac: Data, key: String, model: String, smart: Bool, vocabulary: [String],
                             deadline: TimeInterval) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "input": [["type": "audio", "mime_type": "audio/flac", "data": flac.base64EncodedString()]],
        ]
        var config: [String: Any] = [:]
        if smart { config["mode"] = "smart" }
        if !vocabulary.isEmpty { config["custom_vocabulary"] = vocabulary }
        if !config.isEmpty { body["generation_config"] = ["transcription_config": config] }
        let data = try await post("v1beta/interactions", body: body, key: key, deadline: deadline, modelInPath: false)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.server("unparseable response")
        }
        guard (json["status"] as? String) == "completed" else {
            throw Failure.server(((json["error"] as? [String: Any])?["message"] as? String) ?? "status \(json["status"] ?? "?")")
        }
        return ((json["steps"] as? [[String: Any]]) ?? [])
            .filter { ($0["type"] as? String) == "model_output" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `:generateContent`, word for word. Transcribe models need `wordTimestamp: true` here, or the text comes back empty.
    private func generateContent(_ flac: Data, key: String, model: String, vocabulary: [String],
                                 deadline: TimeInterval) async throws -> String {
        var audio: [String: Any] = ["wordTimestamp": true, "diarization": false]
        if !vocabulary.isEmpty { audio["customVocabulary"] = vocabulary }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["inline_data": ["mime_type": "audio/flac", "data": flac.base64EncodedString()]]]]],
            "generationConfig": ["temperature": 0, "audioTranscriptionConfig": audio],
        ]
        let data = try await post("v1beta/models/\(model):generateContent", body: body, key: key, deadline: deadline)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["candidates"] as? [[String: Any]])?.first else { throw Failure.server("no candidates") }
        let parts = (first["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Key and model

    /// Checks the key and picks the speech model it can reach: one named "…transcribe", newest first.
    func check(key: String) async throws -> String {
        var request = URLRequest(url: Self.endpoint.appendingPathComponent("v1beta/models")
            .appending(queryItems: [URLQueryItem(name: "pageSize", value: "1000")]))
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            throw Failure.unreachable
        }
        // A bad key is 400 API_KEY_INVALID here, not 401.
        guard http.statusCode == 200 else {
            if (500...599).contains(http.statusCode) { throw Failure.unreachable }
            throw Failure.rejectedKey(Self.errorMessage(data))
        }
        let names = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] ?? [])
            .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
        let speech = names.filter { $0.contains("transcribe") }
        guard let model = speech.sorted(by: { Self.isNewer($0, than: $1) }).first
                ?? (names.contains(Self.fallbackModel) ? Self.fallbackModel : nil) else { throw Failure.noModel }
        return model
    }

    /// "gemini-3.5-transcribe" before "gemini-3-transcribe"; a stable name before a "-preview" one.
    private static func isNewer(_ a: String, than b: String) -> Bool {
        func version(_ name: String) -> [Int] {
            name.split(separator: "-").dropFirst().first.map { $0.split(separator: ".").compactMap { Int($0) } } ?? []
        }
        if version(a) != version(b) { return version(b).lexicographicallyPrecedes(version(a)) }
        return !a.contains("preview") && b.contains("preview")
    }

    // MARK: - Transport

    private func post(_ path: String, body: [String: Any], key: String, deadline: TimeInterval,
                      modelInPath: Bool = true, retried: Bool = false) async throws -> Data {
        var request = URLRequest(url: Self.endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The key goes in a header, never in the URL (query strings end up in logs).
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = deadline
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
        switch http.statusCode {
        case 200: return data
        case 401: throw Failure.rejectedKey(Self.errorMessage(data))
        case 403, 404:
            // On interactions this is about the endpoint, not the model.
            throw modelInPath ? Failure.noModel : Failure.server("interactions unavailable (\(http.statusCode))")
        case 429:
            // A per-minute limit says how long to wait ("retryDelay": "2s"): wait once if it's short.
            if !retried, let delay = Self.retryDelay(data, http), delay <= 8 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await post(path, body: body, key: key, deadline: deadline, modelInPath: modelInPath, retried: true)
            }
            throw Failure.quota
        case 400: throw Failure.rejectedKey(Self.errorMessage(data))
        default: throw Failure.server(Self.errorMessage(data) ?? "HTTP \(http.statusCode)")
        }
    }

    private static func retryDelay(_ data: Data, _ http: HTTPURLResponse) -> Double? {
        if let header = http.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header) { return seconds }
        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: #""retryDelay"\s*:\s*"[0-9.]+s""#, options: .regularExpression) else { return nil }
        return Double(text[range].drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." })
    }

    /// `{"error":{"message"}}` from generateContent, `[{"error":{"message"}}]` from interactions.
    private static func errorMessage(_ data: Data) -> String? {
        let root = try? JSONSerialization.jsonObject(with: data)
        let object = (root as? [String: Any]) ?? (root as? [[String: Any]])?.first
        return (object?["error"] as? [String: Any])?["message"] as? String
    }

    /// The recording as FLAC: several times smaller than the raw audio, so it uploads fast.
    private static func flac(from file: URL) throws -> Data {
        let url = file.deletingPathExtension().appendingPathExtension("flac")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try AVAudioFile(forReading: file, commonFormat: .pcmFormatInt16, interleaved: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: reader.processingFormat.sampleRate,
            AVNumberOfChannelsKey: reader.processingFormat.channelCount,
        ]
        // The writer finishes the file when it goes away: keep it in its own scope.
        do {
            let writer = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 65_536) else {
                throw Failure.server("audio buffer")
            }
            // read(into:) may throw at the very end with an Int16 format: stop by position instead.
            while reader.framePosition < reader.length {
                try reader.read(into: chunk)
                if chunk.frameLength == 0 { break }
                try writer.write(from: chunk)
            }
        }
        return try Data(contentsOf: url)
    }
}

/// The Google AI key, kept in the login Keychain (not in the settings file).
enum GeminiKey {
    private static let service = "app.klavko.Klavko.google-ai"

    static func load() -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
