import Foundation

/// グラス側ディスプレイへの表示出力を抽象化する protocol。
/// 現在は MockGlassesDisplayClient のみ。実 DAT SDK が利用可能になったら
/// 同じ protocol に準拠する DATGlassesDisplayClient を実装して差し替える。
public protocol GlassesDisplayClient: Sendable {
    func show(payload: DisplayPayload) async throws
    func clear() async throws
}
