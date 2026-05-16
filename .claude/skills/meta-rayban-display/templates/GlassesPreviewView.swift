import SwiftUI

/// iPhone-side simulated HUD. Hand it the current `DisplayPayload?`
/// from your environment (e.g. a `@Published` property the analyzer
/// updates whenever it sends to the glasses) and it renders the same
/// `title / body / chips` layout the real display would show.
///
/// Useful for:
/// - Developing without real glasses
/// - Side-by-side comparison while the firmware-side fix is pending
/// - QA: confirming the formatter output before it leaves the phone
public struct GlassesPreviewView: View {
    public let payload: DisplayPayload?

    public init(payload: DisplayPayload?) {
        self.payload = payload
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color.black)

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
                Text("(no display)").foregroundColor(.white.opacity(0.3))
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
