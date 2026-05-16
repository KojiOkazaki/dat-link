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
  private var startSessionInProgress: Bool = false

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
    let selector = self.deviceSelector
    deviceMonitorTask = Task { @MainActor [weak self] in
      for await device in selector.activeDeviceStream() {
        self?.hasActiveDevice = device != nil
      }
    }
  }

  func handleStartStreaming() async {
    NSLog("[CameraAccess] handleStartStreaming called (already in progress: \(startSessionInProgress))")
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
    if startSessionInProgress {
      NSLog("[CameraAccess] startSession SKIPPED (already in progress)")
      return
    }
    if session != nil {
      NSLog("[CameraAccess] startSession SKIPPED (session already exists)")
      return
    }
    startSessionInProgress = true
    defer { startSessionInProgress = false }

    // Tear down any previous session/stream first so we don't trip
    // DeviceSessionError.sessionAlreadyExists on retry.
    await teardownExistingSession()

    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      self.session = session
      NSLog("[CameraAccess] createSession ok, state=\(session.state)")

      try session.start()
      NSLog("[CameraAccess] session.start() returned, state=\(session.state)")

      // Some SDK 0.7 + iOS 26 combinations report state .starting for a few
      // hundred ms after start() returns. Polling for a started/idle-equiv.
      // state gives addStream a better chance of succeeding.
      for _ in 0..<10 {
        let s = "\(session.state)"
        if !s.contains("starting") && !s.contains("stopping") { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      NSLog("[CameraAccess] after settle, state=\(session.state)")

      guard let stream = try session.addStream(config: streamConfig) else {
        NSLog("[CameraAccess] addStream nil. final state=\(session.state)")
        showError("Stream capability is not available on this device. (Mock or device may not support streaming in DAT 0.7.)")
        return
      }
      NSLog("[CameraAccess] stream obtained, state=\(stream.state)")

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
          // Tear down so the user can retry. Without this, our reentry
          // guard keeps skipping startSession because session != nil.
          await self.teardownExistingSession()
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

      self.stream = stream
      updateStatusFromState(stream.state)
      await stream.start()
    } catch {
      NSLog("[CameraAccess] startSession threw: \(error)")
      showError("Failed to start streaming: \(error.localizedDescription)")
    }
  }

  func stopSession() async {
    await teardownExistingSession()
  }

  private func teardownExistingSession() async {
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
    if let stream {
      await stream.stop()
    }
    stream = nil
    session = nil
    // Give the SDK a brief moment to release its internal session
    // bookkeeping before any retry. Without this, immediate retries
    // can race with the in-flight teardown and trip sessionAlreadyExists.
    try? await Task.sleep(nanoseconds: 200_000_000)
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
      // Free the Swift-side session/stream so the user can retry.
      Task { @MainActor in
        await self.teardownExistingSession()
      }
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
    case .thermalEmergency:
      return "Device thermal emergency. Streaming stopped."
    case .peakPowerShutdown:
      return "Device power shutdown. Streaming stopped."
    case .batteryCritical:
      return "Battery critical. Streaming stopped."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    @unknown default:
      return "Streaming error: \(error.localizedDescription)"
    }
  }
}
