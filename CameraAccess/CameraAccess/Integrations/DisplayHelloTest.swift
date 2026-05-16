//
//  DisplayHelloTest.swift
//
//  Camera, Gemma4, registration を完全バイパスして
//  Wearables.shared → DeviceSession → addDisplay → display.send
//  だけを直接叩く診断用最小コード。
//
//  目的: Issue #180 で報告されている datAppOnTheGlassesUpdateRequired や
//  DisplayError.deviceDisconnected が我々の環境でも出るか確認する。
//

import Foundation
import MWDATCore
import MWDATDisplay
import SwiftUI

@MainActor
final class DisplayHelloTestRunner: ObservableObject {
  @Published private(set) var status: String = "idle"

  private var session: DeviceSession?
  private var display: Display?

  func run() async {
    // Always tear down any previous run first so we don't trip
    // sessionAlreadyExists on a re-tap.
    await teardown()

    status = "creating session..."
    NSLog("[DisplayHello] start")
    do {
      let wearables = Wearables.shared
      // Filter to devices that actually advertise display support.
      // Without this filter, AutoDeviceSelector may pick a glasses
      // that the SDK doesn't consider a Display device, returning
      // noEligibleDevice from createSession.
      let selector = AutoDeviceSelector(
        wearables: wearables,
        filter: { $0.supportsDisplay() }
      )
      let session = try wearables.createSession(deviceSelector: selector)
      self.session = session
      NSLog("[DisplayHello] session created, state=\(session.state)")
      status = "starting session..."

      try session.start()
      NSLog("[DisplayHello] session.start() ok, state=\(session.state)")

      status = "adding display..."
      let display = try session.addDisplay()
      self.display = display
      NSLog("[DisplayHello] addDisplay ok, display.state=\(display.state)")

      status = "starting display..."
      await display.start()
      NSLog("[DisplayHello] display.start() ok, state=\(display.state)")

      status = "sending view..."
      let view = FlexBox(
        direction: .column,
        spacing: 8,
        padding: EdgeInsets(all: 16)
      ) {
        Text("Hello", style: .heading, color: .primary)
        Text("from CameraAccess", style: .body, color: .secondary)
      }
      .background(.card)

      try await display.send(view)
      NSLog("[DisplayHello] send ok")
      status = "✅ sent — check the glasses"
    } catch let error as DeviceSessionError {
      NSLog("[DisplayHello] DeviceSessionError: \(error)")
      status = "❌ DeviceSessionError: \(error.localizedDescription)"
      await teardown()
    } catch let error as DisplayError {
      NSLog("[DisplayHello] DisplayError: \(error)")
      status = "❌ DisplayError: \(error.description)"
      await teardown()
    } catch {
      NSLog("[DisplayHello] other error: \(error)")
      status = "❌ \(error.localizedDescription)"
      await teardown()
    }
  }

  private func teardown() async {
    if let display {
      await display.stop()
    }
    self.display = nil
    self.session = nil
    try? await Task.sleep(nanoseconds: 200_000_000)
  }
}

struct DisplayHelloTestButton: View {
  @StateObject private var runner = DisplayHelloTestRunner()

  var body: some View {
    VStack(spacing: 8) {
      Button {
        Task { await runner.run() }
      } label: {
        Label("Display Hello (diag)", systemImage: "sparkles.tv")
          .font(.headline)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(Color.orange.opacity(0.9))
          .foregroundColor(.white)
          .clipShape(RoundedRectangle(cornerRadius: 10))
      }
      Text(runner.status)
        .font(.caption)
        .foregroundColor(.white.opacity(0.8))
        .lineLimit(2)
        .multilineTextAlignment(.center)
    }
  }
}
