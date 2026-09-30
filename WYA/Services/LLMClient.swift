import Foundation
import WYACore

enum LLMError: Error {
    case missingKey
    case badURL
    case empty
    case status(Int)
}

struct LLMClient: Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        session = URLSession(configuration: configuration)
    }

    func extract(query: String, secrets: AppSecrets) async throws -> ParsedTripQuery {
        let content = try await complete(
            secrets: secrets,
            system: """
            Extract the trip origin and destination from the rider message. \
            Reply with JSON only: {"origin": string or null, "destination": string or null}. \
            Use null for origin when they mean the current location, including "here", "me", or "from here". \
            Do not invent places. Do not include times or routes.
            """,
            user: query
        )
        guard let data = jsonObject(in: content),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw LLMError.empty }
        return ParsedTripQuery(
            origin: place(object["origin"]),
            destination: place(object["destination"])
        )
    }

    func narrate(plan: TripPlan, secrets: AppSecrets) async throws -> String {
        let payload = narrationPayload(plan)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        let text = try await complete(
            secrets: secrets,
            system: """
            You are WYA, a concise NYC transit guide. Narrate the trip using only the JSON facts. \
            Do not invent routes, stops, transfers, or times. Use 2 to 4 sentences. \
            Mention the total minutes and the walking. If a wait is not live, call it a typical estimate.
            """,
            user: json
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.empty }
        return trimmed
    }

    private func complete(secrets: AppSecrets, system: String, user: String) async throws -> String {
        guard secrets.hasLLM else { throw LLMError.missingKey }
        var base = secrets.llmBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { throw LLMError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secrets.llmKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": secrets.llmModel,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.status(-1) }
        guard http.statusCode == 200 else { throw LLMError.status(http.statusCode) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw LLMError.empty }
        return content
    }

    private func narrationPayload(_ plan: TripPlan) -> [String: Any] {
        let legs = plan.legs.map { leg -> [String: Any] in
            var item: [String: Any] = [
                "kind": leg.kind.rawValue,
                "minutes": DurationMath.roundedMinutes(leg.seconds),
                "title": leg.title,
                "detail": leg.detail,
                "live": leg.live
            ]
            if let route = leg.routeID { item["route"] = route }
            return item
        }
        return [
            "origin": plan.originName,
            "destination": plan.destinationName,
            "totalMinutes": plan.displayMinutes,
            "legs": legs
        ]
    }

    private func jsonObject(in text: String) -> Data? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed.replacingOccurrences(of: "```json", with: "")
            trimmed = trimmed.replacingOccurrences(of: "```", with: "")
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else { return nil }
        return String(trimmed[start...end]).data(using: .utf8)
    }

    private func place(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.lowercased()
        if trimmed.isEmpty || ["null", "here", "me", "my location", "current location"].contains(folded) {
            return nil
        }
        return trimmed
    }
}
