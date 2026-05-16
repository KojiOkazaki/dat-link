/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// DebugMenuViewModel.swift
//
// Debug-only view model that provides access to mock devices for development and testing.
// This enables developers to test DAT SDK streaming functionality without physical Meta
// wearable devices. Mock devices simulate the behavior of real devices, allowing for
// comprehensive testing of streaming, photo capture, and error handling workflows.
//

#if DEBUG

import MWDATMockDevice
import SwiftUI

@MainActor
class DebugMenuViewModel: ObservableObject {
  @Published public var showDebugMenu: Bool
  @Published public var mockDeviceKitViewModel: MockDeviceKitView.ViewModel

  init(mockDeviceKit: MockDeviceKitInterface) {
    // Note: do not call mockDeviceKit.enable() here. Enabling the mock kit
    // eagerly can interfere with real-device registration state on launch.
    // enable() is deferred until the user actually pairs a mock device
    // (see MockDeviceKitView.ViewModel.pairRaybanMeta()).
    self.mockDeviceKitViewModel = MockDeviceKitView.ViewModel(mockDeviceKit: mockDeviceKit)
    self.showDebugMenu = false
  }
}

#endif
