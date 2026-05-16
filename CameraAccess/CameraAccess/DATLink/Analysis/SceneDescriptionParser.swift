import Foundation

public enum SceneDescriptionParseError: Error, Sendable {
    case noJSONFound
    case decodingFailed(Error)
}

/// VLM の生テキストから SceneDescription を取り出すパーサ。
/// 素の JSON、```json``` フェンスで囲まれた JSON、前後に説明文が
/// 付いた JSON の 3 パターンに対応する。
public struct SceneDescriptionParser: Sendable {
    public init() {}

    public func parse(_ rawText: String) throws -> SceneDescription {
        let jsonString = try extractJSON(from: rawText)
        guard let data = jsonString.data(using: .utf8) else {
            throw SceneDescriptionParseError.noJSONFound
        }
        do {
            var description = try JSONDecoder().decode(SceneDescription.self, from: data)
            description.rawText = rawText
            return description
        } catch {
            throw SceneDescriptionParseError.decodingFailed(error)
        }
    }

    private func extractJSON(from text: String) throws -> String {
        let fencePattern = "```(?:json)?\\s*([\\s\\S]*?)\\s*```"
        if let regex = try? NSRegularExpression(pattern: fencePattern),
           let match = regex.firstMatch(
               in: text,
               range: NSRange(text.startIndex..., in: text)
           ),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            throw SceneDescriptionParseError.noJSONFound
        }
        return String(text[start...end])
    }
}
