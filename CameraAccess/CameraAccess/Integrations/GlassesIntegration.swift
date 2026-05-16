//
//  GlassesIntegration.swift
//
//  既存の VisionServiceManager と DATLink モジュールを繋ぐブリッジ。
//  既存コードは一切変更せず、追加だけで動く。
//

import Foundation
import SwiftUI
import UIKit

/// 既存 `AIVisionEngine` を DATLink の `SceneAnalyzing` 形に変換するアダプタ。
///
/// - `VLMPrompt.sceneDescription` を投げて JSON を要求
/// - JSON が返ってこなければ先頭 12/40 文字でフォールバック SceneDescription を組み立てる
/// - 元の AnalysisOverlayView の自然文表示フローは変更しない
@MainActor
final class CameraAccessSceneAnalyzer: SceneAnalyzing {
    private let manager: VisionServiceManager
    private let parser: SceneDescriptionParser

    init() {
        self.manager = VisionServiceManager.shared
        self.parser = SceneDescriptionParser()
    }

    init(manager: VisionServiceManager, parser: SceneDescriptionParser = SceneDescriptionParser()) {
        self.manager = manager
        self.parser = parser
    }

    func analyze(imageData: Data) async throws -> SceneDescription {
        guard let image = UIImage(data: imageData) else {
            throw GlassesIntegrationError.imageDecodingFailed
        }
        return try await analyze(image: image)
    }

    func analyze(image: UIImage) async throws -> SceneDescription {
        let raw = try await manager.currentEngine.analyzeImage(
            image,
            prompt: VLMPrompt.sceneDescription
        )
        if let parsed = try? parser.parse(raw) {
            return parsed
        }
        return Self.fallback(from: raw)
    }

    private static func fallback(from raw: String) -> SceneDescription {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let titlePart = trimmed.prefix(12)
        let summaryPart = trimmed.prefix(40)
        return SceneDescription(
            title: titlePart.isEmpty ? "シーン" : String(titlePart),
            summary: summaryPart.isEmpty ? "はっきり分かりません" : String(summaryPart),
            tags: [],
            confidence: trimmed.isEmpty ? 0.0 : 0.4,
            rawText: raw
        )
    }
}

enum GlassesIntegrationError: LocalizedError {
    case imageDecodingFailed

    var errorDescription: String? {
        switch self {
        case .imageDecodingFailed: return "画像のデコードに失敗しました"
        }
    }
}

/// グラス表示パイプライン全体を保持する EnvironmentObject。
///
/// 出力先は `client: any GlassesDisplayClient`。CameraAccessApp で:
///   - シミュレータ → MockGlassesDisplayClient
///   - 実機         → DATGlassesDisplayClient（MWDATDisplay 経由で実グラスへ）
/// を選んで注入する。
///
/// `currentPayload` は iPhone 側の擬似 HUD プレビュー用。
/// 自動クリアは `durationSeconds` 経過後にこのクラスがスケジュールする
/// （Mock/DAT クライアント側の挙動に依存しない）。
@MainActor
final class GlassesPipelineEnvironment: ObservableObject {
    let analyzer: CameraAccessSceneAnalyzer
    let formatter: DisplayFormatter
    private let clientFactory: @MainActor () -> any GlassesDisplayClient
    private lazy var client: any GlassesDisplayClient = clientFactory()

    @Published private(set) var currentPayload: DisplayPayload?
    @Published private(set) var lastDescription: SceneDescription?
    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var lastError: String?

    private var clearTask: Task<Void, Never>?

    init() {
        self.clientFactory = { MockGlassesDisplayClient() }
        self.analyzer = CameraAccessSceneAnalyzer()
        self.formatter = DisplayFormatter()
    }

    init(clientFactory: @escaping @MainActor () -> any GlassesDisplayClient) {
        self.clientFactory = clientFactory
        self.analyzer = CameraAccessSceneAnalyzer()
        self.formatter = DisplayFormatter()
    }

    /// MVP の一発処理: image → SceneDescription → DisplayPayload → glasses。
    func describeAndShow(image: UIImage) async {
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }
        do {
            let description = try await analyzer.analyze(image: image)
            lastDescription = description
            await present(formatter.format(description))
        } catch {
            lastError = error.localizedDescription
            await present(formatter.errorPayload(message: error.localizedDescription))
        }
    }

    func clear() async {
        clearTask?.cancel()
        currentPayload = nil
        try? await client.clear()
    }

    private func present(_ payload: DisplayPayload) async {
        currentPayload = payload
        scheduleAutoClear(after: payload.durationSeconds)
        do {
            try await client.show(payload: payload)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func scheduleAutoClear(after seconds: Int) {
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
            if Task.isCancelled { return }
            self?.currentPayload = nil
            try? await self?.client.clear()
        }
    }
}
