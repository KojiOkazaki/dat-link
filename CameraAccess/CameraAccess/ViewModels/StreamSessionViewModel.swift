/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Rewritten for DAT SDK 0.7:
//   - StreamSession        → MWDATCamera.Stream
//   - StreamSessionConfig  → StreamConfiguration
//   - StreamSessionState   → StreamState
//   - StreamSessionError   → StreamError
//   - Construction is now DeviceSession.addStream(config:) instead of
//     directly creating a StreamSession.
//

import MWDATCamera
import MWDATCore
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private let streamConfig: StreamConfiguration

  private var session: DeviceSession?
  private var stream: MWDATCamera.Stream?

  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private var deviceMonitorTask: Task<Void, Never>?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    self.streamConfig = StreamConfiguration(
      videoCodec: .raw,
      resolution: .low,
      frameRate: 24)

    // Monitor device availability
    deviceMonitorTask = Task { @MainActor [weak self] in
      for await device in deviceSelector.activeDeviceStream() {
        self?.hasActiveDevice = device != nil
      }
    }
  }

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Permission denied")
    } catch {
      showError("Permission error: \(error.localizedDescription)")
    }
  }

  func startSession() async {
    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      // Register the Stream capability BEFORE starting the session so the
      // session knows it has to bring up streaming. Calling addStream after
      // start() returns nil on some device + SDK 0.7 combinations.
      guard let stream = try session.addStream(config: streamConfig) else {
        showError("Stream capability is not available on this device.")
        return
      }

      stateListenerToken = stream.statePublisher.listen { [weak self] state in
        Task { @MainActor in
          self?.updateStatusFromState(state)
        }
      }
      videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] videoFrame in
        Task { @MainActor in
          guard let self else { return }
          if let image = videoFrame.makeUIImage() {
            self.currentVideoFrame = image
            if !self.hasReceivedFirstFrame {
              self.hasReceivedFirstFrame = true
            }
          }
        }
      }
      errorListenerToken = stream.errorPublisher.listen { [weak self] error in
        Task { @MainActor in
          guard let self else { return }
          let message = self.formatStreamingError(error)
          if message != self.errorMessage {
            self.showError(message)
          }
        }
      }
      photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
        Task { @MainActor in
          guard let self else { return }
          if let uiImage = UIImage(data: photoData.data) {
            self.capturedPhoto = uiImage
            self.showPhotoPreview = true
          }
        }
      }

      try session.start()
      self.session = session
      self.stream = stream
      updateStatusFromState(stream.state)
      await stream.start()
    } catch {
      showError("Failed to start streaming: \(error.localizedDescription)")
    }
  }

  func stopSession() async {
    await stream?.stop()
    stream = nil
    session = nil
  }

  func capturePhoto() {
    _ = stream?.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  // Conservative state mapping: only `.stopped` is reliably named the same
  // across versions. Other states (starting/started/stopping/paused, etc.)
  // are coalesced into waiting/streaming via the default branch.
  private func updateStatusFromState(_ state: StreamState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    default:
      // Any non-stopped state implies the pipeline is active.
      // Once the first frame arrives we'll flip to .streaming via the
      // frame listener; until then keep showing the waiting spinner.
      streamingStatus = hasReceivedFirstFrame ? .streaming : .waiting
    }
  }

  private func formatStreamingError(_ error: StreamError) -> String {
    switch error {
    case .timeout:
      return "The operation timed out. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    case .thermalCritical:
      return "Device is too hot. Please let it cool down and try again."
    @unknown default:
      return "Streaming error: \(error.localizedDescription)"
    }
  }
}
