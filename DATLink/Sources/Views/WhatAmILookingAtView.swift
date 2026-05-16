import SwiftUI

/// iPhone 側 UI。
/// 「What am I looking at?」ボタン + 解析中スピナー + 結果カード。
/// `imageProvider` クロージャから現在のカメラ画像 (JPEG/PNG Data) を取得する。
/// 既存の画像取得処理（Ray-Ban Meta / Display 由来）をそのまま渡せばよい。
public struct WhatAmILookingAtView: View {
    @ObservedObject var viewModel: WhatAmILookingAtViewModel
    let imageProvider: () async -> Data?

    public init(
        viewModel: WhatAmILookingAtViewModel,
        imageProvider: @escaping () async -> Data?
    ) {
        self.viewModel = viewModel
        self.imageProvider = imageProvider
    }

    public var body: some View {
        VStack(spacing: 16) {
            captureButton

            switch viewModel.state {
            case .idle:
                Text("ボタンを押して解析開始")
                    .foregroundStyle(.secondary)
            case .analyzing:
                ProgressView("解析中…")
            case .shown(let payload):
                payloadCard(payload)
            case .failed(let message):
                Text("失敗: \(message)")
                    .foregroundStyle(.red)
            }

            if let desc = viewModel.lastDescription {
                rawCard(desc)
            }

            Spacer(minLength: 0)
        }
        .padding()
    }

    private var captureButton: some View {
        Button {
            Task { await capture() }
        } label: {
            Label("What am I looking at?", systemImage: "eye")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(viewModel.state == .analyzing)
    }

    private func capture() async {
        guard let data = await imageProvider() else { return }
        await viewModel.describeWhatIAmLookingAt(imageData: data)
    }

    private func payloadCard(_ p: DisplayPayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.title).font(.title3.bold())
            Text(p.body).font(.body)
            if !p.chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(p.chips, id: \.self) { chip in
                        Text(chip)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func rawCard(_ d: SceneDescription) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("VLM 結果").font(.caption).foregroundStyle(.secondary)
            Text(d.summary).font(.footnote)
            Text("confidence: \(String(format: "%.2f", d.confidence))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
