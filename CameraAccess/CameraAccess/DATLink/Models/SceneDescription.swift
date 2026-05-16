import Foundation

/// VLM/LLM が返す画像説明結果。
/// JSON で `{"title","summary","tags","confidence"}` を期待。
/// `rawText` はデバッグ/ログ用にパース元のテキストを保持する。
public struct SceneDescription: Codable, Hashable, Sendable {
    public var title: String
    public var summary: String
    public var tags: [String]
    public var confidence: Double
    public var rawText: String?

    public init(
        title: String,
        summary: String,
        tags: [String],
        confidence: Double,
        rawText: String? = nil
    ) {
        self.title = title
        self.summary = summary
        self.tags = tags
        self.confidence = confidence
        self.rawText = rawText
    }
}
