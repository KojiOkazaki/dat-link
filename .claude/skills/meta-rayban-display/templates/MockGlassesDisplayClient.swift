import Foundation
import Combine

/// In-process stub for the glasses HUD. Logs to NSLog, publishes the
/// active payload for SwiftUI previews, and auto-clears after the
/// payload's duration. No SDK or hardware needed.
@MainActor
public final class MockGlassesDisplayClient: ObservableObject, GlassesDisplayClient {
    @Published public private(set) var currentPayload: DisplayPayload?
    @Published public private(set) var lastShownAt: Date?

    private var clearTask: Task<Void, Never>?

    public init() {}

    public func show(payload: DisplayPayload) async throws {
        clearTask?.cancel()
        currentPayload = payload
        lastShownAt = Date()
        NSLog("[GlassesHUD][mock] [\(payload.priority.rawValue)] \(payload.title) | \(payload.body) | chips=\(payload.chips) | dur=\(payload.durationSeconds)s")

        let duration = max(1, payload.durationSeconds)
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
            if Task.isCancelled { return }
            self?.currentPayload = nil
        }
    }

    public func clear() async throws {
        clearTask?.cancel()
        currentPayload = nil
    }
}
