/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CameraAccessApp.swift
//
// Main entry point for the CameraAccess sample app demonstrating the Meta Wearables DAT SDK.
// This app shows how to connect to wearable devices (like Ray-Ban Meta smart glasses),
// stream live video from their cameras, and capture photos. It provides a complete example
// of DAT SDK integration including device registration, permissions, and media streaming.
//

import Foundation
import MWDATCore
import SwiftUI

#if DEBUG
import MWDATMockDevice
#endif

@main
struct CameraAccessApp: App {
  #if DEBUG
  // Debug menu for simulating device connections during development
  @StateObject private var debugMenuViewModel = DebugMenuViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif
  private let wearables: WearablesInterface
  @StateObject private var wearablesViewModel: WearablesViewModel
  // Ray-Ban Display への表示用パイプライン（Mock 接続）。実 DAT 接続時は
  // GlassesPipelineEnvironment(client: DATGlassesDisplayClient(...)) に差し替え。
  @StateObject private var glassesEnv: GlassesPipelineEnvironment

  init() {
    do {
      try Wearables.configure()
    } catch {
      #if DEBUG
      NSLog("[CameraAccess] Failed to configure Wearables SDK: \(error)")
      #endif
    }
    let wearables = Wearables.shared
    self.wearables = wearables
    self._wearablesViewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
    // Defer the actual glasses-display client construction until the first
    // payload is shown. This keeps app startup cheap and avoids creating an
    // AutoDeviceSelector/Display before the user opts into the Glasses flow.
    #if targetEnvironment(simulator)
    let factory: @MainActor () -> any GlassesDisplayClient = {
      MockGlassesDisplayClient()
    }
    #else
    let factory: @MainActor () -> any GlassesDisplayClient = {
      DATGlassesDisplayClient(wearables: wearables)
    }
    #endif
    self._glassesEnv = StateObject(wrappedValue: GlassesPipelineEnvironment(clientFactory: factory))
  }

  var body: some Scene {
    WindowGroup {
      // Main app view with access to the shared Wearables SDK instance
      // The Wearables.shared singleton provides the core DAT API
      MainAppView(wearables: Wearables.shared, viewModel: wearablesViewModel)
        .environmentObject(glassesEnv)
        // Show error alerts for view model failures
        .alert("Error", isPresented: $wearablesViewModel.showError) {
          Button("OK") {
            wearablesViewModel.dismissError()
          }
        } message: {
          Text(wearablesViewModel.errorMessage)
        }
        #if DEBUG
      .sheet(isPresented: $debugMenuViewModel.showDebugMenu) {
        MockDeviceKitView(viewModel: debugMenuViewModel.mockDeviceKitViewModel)
      }
      .overlay {
        DebugMenuView(debugMenuViewModel: debugMenuViewModel)
      }
        #endif

      // Registration view handles the flow for connecting to the glasses via Meta AI
      RegistrationView(viewModel: wearablesViewModel)
        .onOpenURL { url in
          Task { @MainActor in
            do {
              let handled = try await Wearables.shared.handleUrl(url)
              print("handleUrl:", handled, url)
            } catch {
              print("handleUrl error:", error)
            }
          }
        }
    }
  }
}
