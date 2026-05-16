import Foundation

/// SDK-agnostic payload sent to the glasses HUD.
/// Already truncated and safety-checked by `DisplayFormatter`.
public struct DisplayPayload: Codable, Hashable, Sendable {
    public var title: String
    public var body: String
    public var chips: [String]
    public var durationSeconds: Int
    public var priority: DisplayPriority

    public init(
        title: String,
        body: String,
        chips: [String] = [],
        durationSeconds: Int = 5,
        priority: DisplayPriority = .normal
    ) {
        self.title = title
        self.body = body
        self.chips = chips
        self.durationSeconds = durationSeconds
        self.priority = priority
    }
}

public enum DisplayPriority: String, Codable, Hashable, Sendable {
    case low
    case normal
    case high
}
