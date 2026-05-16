import Foundation
import SwiftUI

/// 「What am I looking at?」ユースケースのオーケストレータ。
///
/// 画像 → SceneAnalyzing → SceneDescription → DisplayFormatter → DisplayPayload
/// → iPhone UI（state）+ GlassesDisplayClient（HUD）
///
/// 既存の VLM 呼び出しコードは `SceneAnalyzing` を満たすアダプタにくるんで注入する。
/// iPhone 画面表示とグラス表示は別々の出力先として扱われる:
///   - iPhone 表示: `state` を SwiftUI が観測
///   - グラス表示:  `glassesDisplay.show(payload:)` で別出力先へ送る
@MainActor
public final class WhatAmILookingAtViewModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case analyzing
        case shown(DisplayPayload)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastDescription: SceneDescription?

    private let analyzer: SceneAnalyzing
    private let formatter: DisplayFormatter
    private let glassesDisplay: GlassesDisplayClient

    public init(
        analyzer: SceneAnalyzing,
        formatter: DisplayFormatter = DisplayFormatter(),
        glassesDisplay: GlassesDisplayClient
    ) {
        self.analyzer = analyzer
        self.formatter = formatter
        self.glassesDisplay = glassesDisplay
    }

    public func describeWhatIAmLookingAt(imageData: Data) async {
        state = .analyzing
        lastDescription = nil
        do {
            let description = try await analyzer.analyze(imageData: imageData)
            lastDescription = description
            let payload = formatter.format(description)
            try await glassesDisplay.show(payload: payload)
            state = .shown(payload)
        } catch {
            let payload = formatter.errorPayload()
            try? await glassesDisplay.show(payload: payload)
            state = .failed(error.localizedDescription)
        }
    }

    public func clearGlasses() async {
        try? await glassesDisplay.clear()
        state = .idle
    }
}
