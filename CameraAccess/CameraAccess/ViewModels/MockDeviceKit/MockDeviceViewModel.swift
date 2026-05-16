/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// MockDeviceViewModel.swift
//
// View model for individual mock devices used in development and testing of DAT SDK features.
// This controls mock device behaviors like power states, physical states (folded/unfolded),
// and media content (camera feeds and captured images).
//

#if DEBUG

import Foundation
import MWDATMockDevice

extension MockDeviceCardView {
  @MainActor
  final class ViewModel: ObservableObject {
    let device: MockDevice
    @Published var hasCameraFeed: Bool = false
    @Published var hasCapturedImage: Bool = false

    init(device: MockDevice, hasCameraFeed: Bool = false, hasCapturedImage: Bool = false) {
      self.device = device
      self.hasCameraFeed = hasCameraFeed
      self.hasCapturedImage = hasCapturedImage
    }

    var id: String { device.deviceIdentifier }

    // Display name for the mock device in the UI
    var deviceName: String {
      if device is MockRaybanMeta {
        return "RayBan Meta Glasses"
      }
      return "Device"
    }

    func powerOn() {
      device.powerOn()
    }

    func powerOff() {
      device.powerOff()
    }

    func don() {
      device.don()
    }

    func doff() {
      device.doff()
    }

    func unfold() {
      if let rayBanDevice = device as? MockDisplaylessGlasses {
        rayBanDevice.unfold()
      }
    }

    func fold() {
      if let rayBanDevice = device as? MockDisplaylessGlasses {
        rayBanDevice.fold()
      }
    }

    // Load mock video content
    // TODO(DAT-0.7): API renamed in 0.7 — `MockDisplaylessGlasses.getCameraKit()` is gone.
    // Stubbed out until the new accessor is identified. Verify against
    // MWDATMockDevice.swiftinterface (look for `cameraKit`, `services`, or
    // `MockDisplaylessGlassesServices`).
    func selectVideo(from url: URL) {
      _ = url
    }

    // Load mock image content
    // TODO(DAT-0.7): same as selectVideo.
    func selectImage(from url: URL) {
      _ = url
    }
  }
}

#endif
