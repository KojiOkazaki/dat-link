import Foundation

/// 既存のローカル VLM/LLM 解析処理をラップするためのアダプタ protocol。
///
/// 既存コードを直接書き換えず、薄いアダプタ型でこの protocol に準拠させて
/// ViewModel に注入することで、画像解析パイプラインに接続する。
///
/// 例:
/// ```
/// public struct LocalVLMAdapter: SceneAnalyzing {
///     let vlm: ExistingVLM
///     public func analyze(imageData: Data) async throws -> SceneDescription {
///         let raw = try await vlm.run(prompt: VLMPrompt.sceneDescription, image: imageData)
///         return try SceneDescriptionParser().parse(raw)
///     }
/// }
/// ```
public protocol SceneAnalyzing: Sendable {
    func analyze(imageData: Data) async throws -> SceneDescription
}
