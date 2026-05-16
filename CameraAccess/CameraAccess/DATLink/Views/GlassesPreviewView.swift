import SwiftUI

/// iPhone 画面上に Ray-Ban Display 風の擬似 HUD を表示するプレビュー。
/// 引数の `payload` をそのまま描画する純粋な View。実 DAT 接続の有無に関わらず、
/// 親から `glassesEnv.currentPayload` を流して常時プレビューできる。
public struct GlassesPreviewView: View {
    public let payload: DisplayPayload?

    public init(payload: DisplayPayload?) {
        self.payload = payload
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black)

            if let payload {
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
        .animation(.easeInOut(duration: 0.2), value: payload)
        .overlay(alignment: .topTrailing) {
            Text("Ray-Ban Display preview")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
                .padding(6)
        }
    }
}
