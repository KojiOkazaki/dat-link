import Foundation

/// SceneDescription をグラス表示用に圧縮する純粋関数。
///
/// 表示ルール:
/// - title 最大 12 文字
/// - body  最大 40 文字
/// - chips 最大 3 個
/// - confidence < 0.5 は「はっきり分かりません」に置換
/// - 危険・医療・法律など安全関連キーワードを含む場合は
///   断定せず「確認してください」に置換
public struct DisplayFormatter: Sendable {
    public struct Config: Sendable {
        public var maxTitleCharacters: Int
        public var maxBodyCharacters: Int
        public var maxChips: Int
        public var minConfidence: Double
        public var lowConfidenceMessage: String
        public var safetyFallbackMessage: String
        public var defaultDurationSeconds: Int
        public var safetyKeywords: [String]

        public init(
            maxTitleCharacters: Int = 12,
            maxBodyCharacters: Int = 40,
            maxChips: Int = 3,
            minConfidence: Double = 0.5,
            lowConfidenceMessage: String = "はっきり分かりません",
            safetyFallbackMessage: String = "確認してください",
            defaultDurationSeconds: Int = 5,
            safetyKeywords: [String] = [
                "危険", "医療", "薬", "病気", "診断",
                "法律", "違法", "毒", "投資", "金融"
            ]
        ) {
            self.maxTitleCharacters = maxTitleCharacters
            self.maxBodyCharacters = maxBodyCharacters
            self.maxChips = maxChips
            self.minConfidence = minConfidence
            self.lowConfidenceMessage = lowConfidenceMessage
            self.safetyFallbackMessage = safetyFallbackMessage
            self.defaultDurationSeconds = defaultDurationSeconds
            self.safetyKeywords = safetyKeywords
        }

        public static let `default` = Config()
    }

    public let config: Config

    public init(config: Config = .default) {
        self.config = config
    }

    public func format(_ description: SceneDescription) -> DisplayPayload {
        if description.confidence < config.minConfidence {
            return DisplayPayload(
                title: truncate("？", to: config.maxTitleCharacters),
                body: config.lowConfidenceMessage,
                chips: [],
                durationSeconds: config.defaultDurationSeconds,
                priority: .low
            )
        }

        let hasSafetyKeyword = config.safetyKeywords.contains { keyword in
            description.summary.contains(keyword) || description.title.contains(keyword)
        }
        if hasSafetyKeyword {
            return DisplayPayload(
                title: truncate(description.title, to: config.maxTitleCharacters),
                body: config.safetyFallbackMessage,
                chips: trimmedChips(description.tags),
                durationSeconds: config.defaultDurationSeconds,
                priority: .high
            )
        }

        return DisplayPayload(
            title: truncate(description.title, to: config.maxTitleCharacters),
            body: truncate(description.summary, to: config.maxBodyCharacters),
            chips: trimmedChips(description.tags),
            durationSeconds: config.defaultDurationSeconds,
            priority: .normal
        )
    }

    public func errorPayload(message: String = "解析に失敗しました") -> DisplayPayload {
        DisplayPayload(
            title: "エラー",
            body: truncate(message, to: config.maxBodyCharacters),
            chips: [],
            durationSeconds: config.defaultDurationSeconds,
            priority: .low
        )
    }

    private func truncate(_ s: String, to max: Int) -> String {
        guard s.count > max else { return s }
        guard max > 1 else { return String(s.prefix(max)) }
        return String(s.prefix(max - 1)) + "…"
    }

    private func trimmedChips(_ tags: [String]) -> [String] {
        Array(tags.prefix(config.maxChips))
    }
}
