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

/// グラス表示用のパイプライン一式（client + analyzer + formatter）。
/// `@EnvironmentObject` で配って、任意の View から `describeAndShow(image:)` を呼べる。
///
/// TODO(DAT): 実 DAT のディスプレイ API が利用可能になったら、
/// `MockGlassesDisplayClient` の代わりに `DATGlassesDisplayClient` を注入する。
@MainActor
final class GlassesPipelineEnvironment: ObservableObject {
    let client: MockGlassesDisplayClient
    let analyzer: CameraAccessSceneAnalyzer
    let formatter: DisplayFormatter

    @Published private(set) var lastDescription: SceneDescription?
    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var lastError: String?

    init() {
        self.client = MockGlassesDisplayClient()
        self.analyzer = CameraAccessSceneAnalyzer()
        self.formatter = DisplayFormatter()
    }

    init(
        client: MockGlassesDisplayClient,
        analyzer: CameraAccessSceneAnalyzer,
        formatter: DisplayFormatter = DisplayFormatter()
    ) {
        self.client = client
        self.analyzer = analyzer
        self.formatter = formatter
    }

    /// MVP の一発処理: image → SceneDescription → DisplayPayload → glasses。
    func describeAndShow(image: UIImage) async {
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }
        do {
            let description = try await analyzer.analyze(image: image)
            lastDescription = description
            let payload = formatter.format(description)
            try await client.show(payload: payload)
        } catch {
            lastError = error.localizedDescription
            try? await client.show(
                payload: formatter.errorPayload(message: error.localizedDescription)
            )
        }
    }

    func clear() async {
        try? await client.clear()
    }
}
