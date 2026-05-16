import Foundation
import Combine

/// 実 DAT SDK が無い状態で開発を進めるための Mock。
///
/// - コンソールに表示内容をログ出力する
/// - `currentPayload` を Publish するので、iPhone 側の `GlassesPreviewView`
///   から擬似 HUD として可視化できる
/// - `durationSeconds` 経過後に自動でクリアする
///
/// 実 DAT 接続時の差し替えポイントは TODO: コメントに集約してある。
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
        Self.log(payload)

        // TODO(DAT): 実 SDK 接続時はここで DAT の表示 API を呼ぶ。
        //   try await datSession.displayService.show(
        //       title: payload.title,
        //       body: payload.body,
        //       chips: payload.chips,
        //       duration: .seconds(payload.durationSeconds)
        //   )

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
        // TODO(DAT): 実 SDK 接続時はここで DAT の clear API を呼ぶ。
        //   try await datSession.displayService.clear()
    }

    private static func log(_ p: DisplayPayload) {
        print("[GlassesHUD] [\(p.priority.rawValue)] \(p.title) | \(p.body) | chips=\(p.chips) | dur=\(p.durationSeconds)s")
    }
}
