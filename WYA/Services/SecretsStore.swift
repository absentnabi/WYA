import Foundation

struct AppSecrets: Equatable, Sendable {
    var subwayKey: String
    var busKey: String
    var llmKey: String
    var llmBaseURL: String
    var llmModel: String

    var hasSubway: Bool { !subwayKey.isEmpty }
    var hasBus: Bool { !busKey.isEmpty }
    var hasLLM: Bool { !llmKey.isEmpty }

    static let empty = AppSecrets(
        subwayKey: "",
        busKey: "",
        llmKey: "",
        llmBaseURL: "https://api.openai.com/v1",
        llmModel: "gpt-4o-mini"
    )

    static func load(bundle: Bundle = .main) -> AppSecrets {
        guard let url = bundle.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return .empty }

        func value(_ key: String) -> String {
            (raw[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let base = value("LLMBaseURL")
        let model = value("LLMModel")
        return AppSecrets(
            subwayKey: value("MTASubwayAPIKey"),
            busKey: value("MTABusAPIKey"),
            llmKey: value("LLMAPIKey"),
            llmBaseURL: base.isEmpty ? AppSecrets.empty.llmBaseURL : base,
            llmModel: model.isEmpty ? AppSecrets.empty.llmModel : model
        )
    }
}
