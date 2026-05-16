//
//  DATGlassesDisplayClient.swift
//
//  Meta Wearables DAT SDK v0.7 の MWDATDisplay モジュールを使う実機向けクライアント。
//  GlassesDisplayClient protocol に準拠しているので、Mock と差し替え可能。
//
//  Flow:
//    Wearables.shared
//      → AutoDeviceSelector
//        → DeviceSession (createSession + start)
//          → Display (addDisplay + start)
//            → display.send(FlexBox { Text(title), Text(body), ... })
//

import Foundation
import MWDATCore
import MWDATDisplay

@MainActor
final class DATGlassesDisplayClient: GlassesDisplayClient {
    private let wearables: any WearablesInterface
    private let selector: AutoDeviceSelector
    private var session: DeviceSession?
    private var display: Display?

    init(wearables: any WearablesInterface) {
        self.wearables = wearables
        self.selector = AutoDeviceSelector(wearables: wearables)
    }

    func show(payload: DisplayPayload) async throws {
        try await ensureReady()
        guard let display else {
            throw DisplayError.connectionNotAvailable
        }
        try await display.send(makeFlexBox(for: payload))
    }

    func clear() async throws {
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

    private func makeFlexBox(for payload: DisplayPayload) -> FlexBox {
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
