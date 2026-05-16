import Foundation

/// 既存 VLM が未接続でも MVP を動かすための仮アナライザ。
/// 実装時は SceneAnalyzing を満たす LocalVLMAdapter を作って差し替える。
public struct StubSceneAnalyzer: SceneAnalyzing {
    public init() {}

    public func analyze(imageData: Data) async throws -> SceneDescription {
        try? await Task.sleep(nanoseconds: 600_000_000)
        return SceneDescription(
            title: "机の上",
            summary: "PC、スマホ、コーヒーがあります",
            tags: ["PC", "スマホ", "飲み物"],
            confidence: 0.82,
            rawText: nil
        )
    }
}
