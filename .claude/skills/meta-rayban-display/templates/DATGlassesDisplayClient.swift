//
// DAT 0.7 real-glasses implementation of GlassesDisplayClient.
// Sends a FlexBox{Text, Text, chips} to Meta Ray-Ban Display via MWDATDisplay.
//
// Flow:
//   Wearables.shared
//     → AutoDeviceSelector(filter: supportsDisplay())
//       → wearables.createSession(deviceSelector:)
//         → session.start()
//         → session.addDisplay()
//           → display.start()
//           → try await display.send(FlexBox{...})
//

import Foundation
import MWDATCore
import MWDATDisplay

@MainActor
public final class DATGlassesDisplayClient: GlassesDisplayClient {
    private let wearables: any WearablesInterface
    private let selector: AutoDeviceSelector
    private var session: DeviceSession?
    private var display: Display?

    public init(wearables: any WearablesInterface) {
        self.wearables = wearables
        self.selector = AutoDeviceSelector(
            wearables: wearables,
            filter: { $0.supportsDisplay() }
        )
    }

    public func show(payload: DisplayPayload) async throws {
        try await ensureReady()
        guard let display else {
            throw DisplayError.connectionNotAvailable
        }
        try await display.send(makeView(for: payload))
    }

    public func clear() async throws {
        try? await display?.send(FlexBox(direction: .column) { })
    }

    private func ensureReady() async throws {
        if display != nil { return }
        let session = try wearables.createSession(deviceSelector: selector)
        try session.start()
        let display = try session.addDisplay()
        await display.start()
        self.session = session
        self.display = display
    }

    private func makeView(for payload: DisplayPayload) -> FlexBox {
        FlexBox(
            direction: .column,
            spacing: 6,
            padding: EdgeInsets(all: 12)
        ) {
            Text(payload.title, style: .heading, color: .primary)
            Text(payload.body, style: .body, color: .primary)
            if !payload.chips.isEmpty {
                FlexBox(direction: .row, spacing: 6) {
                    for chip in payload.chips.prefix(3) {
                        Text(chip, style: .meta, color: .secondary)
                    }
                }
            }
        }
        .background(.card)
    }
}
