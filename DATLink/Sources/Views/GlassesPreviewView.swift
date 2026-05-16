import SwiftUI

/// iPhone 画面上に Ray-Ban Display 風の擬似 HUD を表示するプレビュー。
/// `MockGlassesDisplayClient.currentPayload` を観測して描画する。
///
/// 実 DAT 接続時はこの View 自体はそのまま開発用プレビューとして残してよい。
/// 本番のグラス表示は DATGlassesDisplayClient が担当する。
public struct GlassesPreviewView: View {
    @ObservedObject var client: MockGlassesDisplayClient

    public init(client: MockGlassesDisplayClient) {
        self.client = client
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black)

            if let payload = client.currentPayload {
                VStack(alignment: .leading, spacing: 6) {
                    Text(payload.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(payload.body)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                    if !payload.chips.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(payload.chips, id: \.self) { chip in
                                Text(chip)
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.18))
                                    .clipShape(Capsule())
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)
            } else {
                Text("(no display)")
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .frame(height: 140)
        .animation(.easeInOut(duration: 0.2), value: client.currentPayload)
        .overlay(alignment: .topTrailing) {
            Text("Ray-Ban Display preview")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
                .padding(6)
            }
    }
}
