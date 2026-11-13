// Drives the glasses through the Meta Wearables Device Access Toolkit: registration,
// one DeviceSession, its Camera stream and (on display glasses) its Display.
//
// This file must not import SwiftUI: MWDATDisplay and SwiftUI both define `Text`,
// `Button` and `Image`.

import AVFoundation
import Combine
import Foundation
import MWDATCamera
import MWDATCore
import MWDATDisplay
import MWDATMockDevice
import UIKit

/// Where native messages for the web app go (`window.ChessLensNative.receive`).
@MainActor
protocol WebMessageSink: AnyObject {
  func sendToWeb(_ message: [String: Any])
}

@MainActor
final class GlassesController: ObservableObject {
  // MARK: - State the phone UI reads

  /// Whether the native "what the lens shows" panel is up (simulated glasses only).
  @Published var lensPreviewVisible = false
  @Published private(set) var mockEnabled = false

  // MARK: - Collaborators

  let media = MediaStore()
  weak var sink: WebMessageSink?

  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector

  // MARK: - SDK handles

  private var deviceSession: DeviceSession?
  private var camera: MWDATCamera.Camera?
  private var display: MWDATDisplay.Display?
  private var mockGlasses: (any MockGlasses)?

  private let sessionTokens = ListenerTokenBag()
  private let streamTokens = ListenerTokenBag()
  private let displayTokens = ListenerTokenBag()

  private var registrationTask: Task<Void, Never>?
  private var deviceMonitorTask: Task<Void, Never>?
  private var displayFallbackTask: Task<Void, Never>?
  private var captureTimeoutTask: Task<Void, Never>?
  private var resultTimeoutTask: Task<Void, Never>?

  // MARK: - Mirrored SDK state

  private var registrationState: RegistrationState
  private var sessionState: DeviceSessionState = .idle
  private var streamState: MWDATCamera.StreamState = .stopped
  private var displayStateName = "stopped"
  private var activeDeviceId: DeviceIdentifier?
  private var lastError: String?

  // MARK: - Flow state

  /// Bumped for every new session, so a late event from an ended session (the hop to
  /// the main actor is asynchronous) is never applied to its successor.
  private var sessionGeneration = 0
  private var isConnecting = false
  private var isChangingMock = false
  private var pendingConnect = false
  private var mockFeedReady = false
  /// A stream is born `.stopped`; only one that was up and went down has ended.
  private var streamWasActive = false
  private var pendingCaptureId: String?
  private var awaitingResultId: String?
  private var lensCard: LensCard = .idle
  private var lensDirty = false
  private var lensSending = false
  private var didOfferGlassesAppUpdate = false

  private let frameThrottle = Throttle(interval: 0.5)

  private static let mockDefaultsKey = "chesslens.mockGlasses"

  // MARK: - Init

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.registrationState = wearables.registrationState
    // Created up front: the selector fills its active device asynchronously from the
    // device stream, so one built at the moment of the tap would still be empty.
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    observeRegistration()
    observeActiveDevice()

    if Self.storedMockPreference() {
      Task { await self.setMock(true, persist: false) }
    }
  }

  private static func storedMockPreference() -> Bool {
    if UserDefaults.standard.object(forKey: mockDefaultsKey) != nil {
      return UserDefaults.standard.bool(forKey: mockDefaultsKey)
    }
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }

  // MARK: - Web → native entry points

  /// The page finished loading: tell it where things stand.
  func webIsReady() {
    publishStatus()
  }

  func connect() async {
    guard !isConnecting, !isChangingMock else { return }
    guard !hasSession else {
      publishStatus()
      return
    }
    isConnecting = true
    defer { isConnecting = false }
    lastError = nil
    didOfferGlassesAppUpdate = false
    publishStatus()

    // 1. The app must be registered with Meta AI. Registration switches to the Meta AI
    //    app; the outcome arrives on the registration stream, which resumes the connect.
    //    Read fresh: the stream may not have delivered a just-made change yet.
    registrationState = wearables.registrationState
    if registrationState != .registered {
      guard registrationState != .registering else { return }
      pendingConnect = true
      do {
        try await wearables.startRegistration()
      } catch {
        pendingConnect = false
        report(error.localizedDescription)
      }
      return
    }

    // 2. Simulated glasses crash the kit if asked to stream without a camera feed.
    if mockEnabled {
      await prepareMockCameraFeed()
    }

    // 3. A device has to be reachable before a session can be created.
    guard await waitForDevice(timeout: .seconds(6)) else {
      report(
        mockEnabled
          ? "The simulated glasses did not come up. Turn simulated glasses off and on again."
          : "No glasses found. Open the Meta AI app, check that your glasses are connected and unfolded, then try again."
      )
      return
    }

    // 4. Session. Camera and display are attached from the session's `.started`.
    startSession()
  }

  func disconnect() async {
    pendingConnect = false
    await endSessionAndWait()
    lastError = nil
    publishStatus()
  }

  /// Scan from the glasses' point of view. Shared by the web `capture` message and the
  /// lens "Scan" button.
  func capture() {
    guard pendingCaptureId == nil else { return }
    guard hasSession else {
      report("Connect your glasses first.")
      return
    }

    if let stream = camera?.stream, streamState == .streaming {
      let id = Self.makeId()
      pendingCaptureId = id
      lastError = nil
      showOnLens(.scanning)

      // `false` means no capture was started, so no photo event will arrive.
      if stream.capturePhoto(format: .jpeg) {
        captureTimeoutTask?.cancel()
        captureTimeoutTask = Task { [weak self] in
          try? await Task.sleep(for: .seconds(6))
          guard let self, !Task.isCancelled, self.pendingCaptureId == id else { return }
          self.deliverFallbackFrame(id: id, why: "The photo did not arrive from the glasses.")
        }
      } else {
        deliverFallbackFrame(id: id, why: "The glasses could not take a photo right now.")
      }
      return
    }

    // Simulated glasses with no camera behind them (the iOS Simulator): hand over the
    // bundled sample page so the scan → lens loop can still be exercised.
    if mockEnabled, let sample = Self.bundledSamplePhoto() {
      let id = Self.makeId()
      pendingCaptureId = id
      lastError = nil
      showOnLens(.scanning)
      deliverPhoto(id: id, jpeg: sample)
      return
    }

    let reason = "The glasses camera is not streaming yet."
    report(reason)
    showOnLens(.failure(reason: reason))
  }

  /// The web app finished recognising a photo.
  func handleScanResult(_ message: [String: Any]) {
    let id = message["id"] as? String
    if id == nil || id == awaitingResultId {
      awaitingResultId = nil
      resultTimeoutTask?.cancel()
    }
    let ok = (message["ok"] as? Bool) ?? false
    if ok {
      guard
        let png = message["boardPng"] as? String,
        let board = LensCards.boardImage(fromBase64PNG: png)
      else {
        report("The scan result had no board image.")
        showOnLens(.failure(reason: "Scan finished, but the board could not be drawn."))
        return
      }
      let summary = (message["summary"] as? String) ?? ""
      showOnLens(.result(board: board, summary: summary))
    } else {
      let reason = (message["reason"] as? String) ?? "No board found."
      showOnLens(.failure(reason: reason))
    }
  }

  /// The position was changed on the phone (flipped, corrected): refresh the lens if it
  /// is showing a result.
  func handlePosition(_ message: [String: Any]) {
    guard lensCard.isResult else { return }
    guard
      let png = message["boardPng"] as? String,
      let board = LensCards.boardImage(fromBase64PNG: png)
    else { return }
    let summary = (message["summary"] as? String) ?? ""
    showOnLens(.result(board: board, summary: summary))
  }

  func setLensPreview(visible: Bool) {
    lensPreviewVisible = visible && mockGlasses != nil
  }

  /// A fresh preview view of the simulated display, or nil without simulated glasses.
  func makeLensPreviewView() -> UIView? {
    mockGlasses?.services.display.createPreviewView()
  }

  /// A failure outside this class (URL callbacks, the web bridge) that the web app
  /// should show.
  func report(_ message: String) {
    lastError = message
    publishStatus()
  }

  // MARK: - Simulated glasses (MockDeviceKit)

  func setMock(_ enabled: Bool, persist: Bool = true) async {
    if persist {
      UserDefaults.standard.set(enabled, forKey: Self.mockDefaultsKey)
    }
    guard !isChangingMock else { return }
    guard enabled != mockEnabled else {
      publishStatus()
      return
    }
    isChangingMock = true
    defer { isChangingMock = false }
    pendingConnect = false

    // The kit swaps the SDK's registration and device providers live, but it does not
    // end a session bound to a device the swap is about to take away.
    await endSessionAndWait()
    lastError = nil

    if enabled {
      do {
        let glasses = try pairMockGlasses()
        mockGlasses = glasses
        mockEnabled = true
        mockFeedReady = false
        try await waitUntilDeviceIsReady(glasses.deviceIdentifier)
      } catch {
        mockGlasses = nil
        mockEnabled = false
        await MockDeviceKit.shared.disable()
        lastError = "Simulated glasses could not start: \(error.localizedDescription)"
      }
    } else {
      lensPreviewVisible = false
      if let glasses = mockGlasses {
        await MockDeviceKit.shared.unpairDevice(glasses)
      }
      mockGlasses = nil
      mockEnabled = false
      mockFeedReady = false
      await MockDeviceKit.shared.disable()
    }
    publishStatus()
  }

  /// Enables the kit and pairs display glasses, powered, unfolded and worn. Synchronous
  /// on purpose, as in Meta's samples.
  private func pairMockGlasses() throws -> any MockGlasses {
    let kit = MockDeviceKit.shared
    kit.enable()
    let glasses = try kit.pairGlasses(model: .metaRayBanDisplay)
    glasses.powerOn()
    glasses.unfold()
    glasses.don()
    configureMockCapturedImage(glasses)
    return glasses
  }

  private func setMockCameraFeedToBackCamera(_ glasses: any MockGlasses) {
    glasses.services.camera.setCameraFeed(cameraFacing: .back)
  }

  private static func bundledSampleURL() -> URL? {
    guard
      let url = Bundle.main.url(forResource: "web", withExtension: nil)?
        .appendingPathComponent("samples/book-page.jpg"),
      FileManager.default.fileExists(atPath: url.path)
    else { return nil }
    return url
  }

  private static func bundledSamplePhoto() -> Data? {
    guard let url = bundledSampleURL() else { return nil }
    return try? Data(contentsOf: url)
  }

  /// The image a simulated photo capture returns, when the web bundle ships one.
  private func configureMockCapturedImage(_ glasses: any MockGlasses) {
    guard let url = Self.bundledSampleURL() else { return }
    glasses.services.camera.setCapturedImage(fileURL: url)
  }

  /// Points the simulated glasses' camera at the phone's back camera. The kit refuses
  /// (fatally) to stream from a pair whose feed was never set, so the camera stream is
  /// only started once this succeeded.
  private func prepareMockCameraFeed() async {
    guard let glasses = mockGlasses, !mockFeedReady else { return }
    #if targetEnvironment(simulator)
    setMockCameraFeedToBackCamera(glasses)
    mockFeedReady = true
    #else
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    var granted = status == .authorized
    if status == .notDetermined {
      granted = await AVCaptureDevice.requestAccess(for: .video)
    }
    guard granted else {
      lastError = "Allow camera access for Chess Lens in Settings to use the phone camera as the simulated glasses camera."
      return
    }
    setMockCameraFeedToBackCamera(glasses)
    mockFeedReady = true
    #endif
  }

  private func waitUntilDeviceIsReady(_ identifier: DeviceIdentifier) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while !isDeviceReady(identifier) {
      guard clock.now < deadline else { throw MockSetupError.deviceReadinessTimedOut }
      try await clock.sleep(for: .milliseconds(50))
    }
  }

  private func isDeviceReady(_ identifier: DeviceIdentifier) -> Bool {
    guard let device = wearables.deviceForIdentifier(identifier) else { return false }
    return device.linkState == .connected && device.compatibility() == .compatible
  }

  // MARK: - Observation of the SDK

  private func observeRegistration() {
    registrationTask = Task { [weak self] in
      guard let wearables = self?.wearables else { return }
      for await state in wearables.registrationStateStream() {
        guard let self, !Task.isCancelled else { return }
        self.handleRegistration(state)
      }
    }
  }

  private func handleRegistration(_ state: RegistrationState) {
    registrationState = state
    switch state {
    case .registered:
      if pendingConnect {
        pendingConnect = false
        Task { await self.connect() }
      }
    case .available, .unavailable:
      // Unregistered (or never registered): a running session is no longer ours.
      if hasSession {
        endSession()
      }
    default:
      break
    }
    publishStatus()
  }

  private func observeActiveDevice() {
    deviceMonitorTask = Task { [weak self] in
      guard let selector = self?.deviceSelector else { return }
      for await deviceId in selector.activeDeviceStream() {
        guard let self, !Task.isCancelled else { return }
        self.activeDeviceId = deviceId
        self.publishStatus()
      }
    }
  }

  /// Simulated glasses are addressed by the identifier they were paired with; real
  /// glasses are whichever pair the auto selector currently considers active.
  private var currentDeviceId: DeviceIdentifier? {
    mockGlasses?.deviceIdentifier ?? activeDeviceId
  }

  private func waitForDevice(timeout: Duration) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
      if let mockId = mockGlasses?.deviceIdentifier {
        if isDeviceReady(mockId) { return true }
      } else if activeDeviceId != nil {
        return true
      }
      guard clock.now < deadline else { return false }
      try? await clock.sleep(for: .milliseconds(100))
    }
  }

  private var activeDevice: Device? {
    guard let currentDeviceId else { return nil }
    return wearables.deviceForIdentifier(currentDeviceId)
  }

  // MARK: - Session

  private var hasSession: Bool {
    guard deviceSession != nil else { return false }
    switch sessionState {
    case .starting, .started, .paused, .stopping:
      return true
    default:
      return false
    }
  }

  private func startSession() {
    guard deviceSession == nil else { return }
    do {
      let session: DeviceSession
      if let mockId = mockGlasses?.deviceIdentifier {
        session = try wearables.createSession(deviceSelector: SpecificDeviceSelector(device: mockId))
      } else {
        session = try wearables.createSession(deviceSelector: deviceSelector)
      }
      sessionGeneration += 1
      deviceSession = session
      // Subscribe before start() so no initial transition is missed.
      observeSession(session)
      sessionState = .starting
      publishStatus()
      try session.start()
    } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
      cleanupSession()
      sessionState = .idle
      offerGlassesAppUpdate()
    } catch {
      cleanupSession()
      sessionState = .idle
      report("Could not start a glasses session: \(error.localizedDescription)")
    }
  }

  private func observeSession(_ session: DeviceSession) {
    let generation = sessionGeneration
    session.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleSessionState(state, generation: generation) }
    }.store(in: sessionTokens)
    session.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleSessionError(error, generation: generation) }
    }.store(in: sessionTokens)
  }

  private func handleSessionState(_ state: DeviceSessionState, generation: Int) {
    guard deviceSession != nil, generation == sessionGeneration else { return }
    sessionState = state
    switch state {
    case .started:
      // Recognition runs in the web view, which only runs while the app is in front.
      UIApplication.shared.isIdleTimerDisabled = true
      Task { await self.startCameraIfNeeded() }
      if mockEnabled {
        // Simulated glasses are there the moment the session is.
        attachDisplayIfNeeded()
      }
      scheduleDisplayFallback()
    case .stopped:
      cleanupSession()
    default:
      // .paused: the device keeps the link; wait for .started or .stopped.
      break
    }
    publishStatus()
  }

  private func handleSessionError(_ error: DeviceSessionError, generation: Int) {
    guard generation == sessionGeneration else { return }
    if error == .datAppOnTheGlassesUpdateRequired {
      offerGlassesAppUpdate()
    } else {
      report(error.localizedDescription)
    }
  }

  private func offerGlassesAppUpdate() {
    lastError = "Your glasses need an app update before Chess Lens can connect. Update them in the Meta AI app, then try again."
    publishStatus()
    guard !didOfferGlassesAppUpdate else { return }
    didOfferGlassesAppUpdate = true
    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.wearables.openDATGlassesAppUpdate()
      } catch {
        // The message above already says what to do by hand.
      }
    }
  }

  /// Stops capabilities child-first, then the session. The session's `.stopped`
  /// drives the cleanup.
  private func endSession() {
    guard let session = deviceSession else { return }
    sessionState = .stopping
    display?.stop()
    camera?.stop()
    session.stop()
    publishStatus()
  }

  private func endSessionAndWait() async {
    guard deviceSession != nil else { return }
    endSession()
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while deviceSession != nil, clock.now < deadline {
      try? await clock.sleep(for: .milliseconds(50))
    }
    if deviceSession != nil {
      // `.stopped` never arrived; do not let a stalled teardown block the next start.
      cleanupSession()
    }
  }

  /// Terminal cleanup, so the next connect creates everything fresh.
  private func cleanupSession() {
    displayFallbackTask?.cancel()
    displayFallbackTask = nil
    captureTimeoutTask?.cancel()
    captureTimeoutTask = nil
    resultTimeoutTask?.cancel()
    resultTimeoutTask = nil
    sessionTokens.clear()
    streamTokens.clear()
    displayTokens.clear()
    deviceSession = nil
    camera = nil
    display = nil
    sessionState = .stopped
    streamState = .stopped
    streamWasActive = false
    displayStateName = "stopped"
    pendingCaptureId = nil
    awaitingResultId = nil
    lensCard = .idle
    lensDirty = false
    media.setFrame(nil)
    frameThrottle.reset()
    UIApplication.shared.isIdleTimerDisabled = false
  }

  // MARK: - Camera

  private func startCameraIfNeeded() async {
    guard let session = deviceSession, session.state == .started, camera == nil else { return }
    if mockEnabled, !mockFeedReady {
      publishStatus()
      return
    }

    // The check is a silent query; the request switches to the Meta AI app and resumes
    // when the person comes back. Connect was their tap, so the switch is expected.
    do {
      if try await wearables.checkPermissionStatus(.camera) != .granted {
        guard try await wearables.requestPermission(.camera) == .granted else {
          report("Camera access for Chess Lens was not allowed in the Meta AI app.")
          return
        }
      }
    } catch {
      report("Could not check camera permission: \(error.localizedDescription)")
      return
    }

    guard let current = deviceSession, current === session, current.state == .started, camera == nil else {
      return
    }
    beginStream(on: current)
  }

  private func beginStream(on session: DeviceSession) {
    // Raw frames so they can be turned into images directly. Low frame rate on purpose:
    // the link compresses less, and the preview only needs a couple of frames a second.
    let config = StreamConfiguration(
      videoCodec: .raw,
      resolution: .high,
      frameRate: 7
    )
    do {
      guard let newCamera = try session.addCamera(config: config) else {
        report("The glasses camera could not be attached. Try again.")
        return
      }
      camera = newCamera
      streamWasActive = false
      // Subscribe before start() so no initial transition is missed.
      observeStream(newCamera.stream)
      streamState = .starting
      publishStatus()
      newCamera.stream.start()
    } catch {
      camera = nil
      report("The glasses camera could not start: \(error.localizedDescription)")
    }
  }

  private func observeStream(_ stream: MWDATCamera.Stream) {
    let generation = sessionGeneration
    stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleStreamState(state, generation: generation) }
    }.store(in: streamTokens)

    let media = self.media
    let throttle = self.frameThrottle
    stream.videoFramePublisher.listen { [weak self] frame in
      // Off the main thread: encode at most two frames a second.
      guard throttle.shouldEmit() else { return }
      guard
        let image = frame.makeUIImage(),
        let jpeg = image.jpegData(compressionQuality: 0.8)
      else { return }
      media.setFrame(jpeg)
      Task { @MainActor in self?.announceFrame() }
    }.store(in: streamTokens)

    stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleStreamError(error, generation: generation) }
    }.store(in: streamTokens)

    stream.photoDataPublisher.listen { [weak self] photo in
      let data = photo.data
      Task { @MainActor in self?.handlePhoto(data, generation: generation) }
    }.store(in: streamTokens)
  }

  private func handleStreamState(_ state: MWDATCamera.StreamState, generation: Int) {
    guard camera != nil, generation == sessionGeneration else { return }
    if state == .stopped, !streamWasActive {
      return
    }
    streamState = state
    switch state {
    case .streaming:
      streamWasActive = true
      // Frames prove the device is really there, which the display needs before it
      // will start.
      attachDisplayIfNeeded()
    case .stopped:
      streamWasActive = false
      streamTokens.clear()
      // Detach so a later addCamera() can register a new one (no-op if already stopped).
      camera?.stop()
      camera = nil
      media.setFrame(nil)
      if let id = pendingCaptureId {
        failCapture(id: id, reason: "The glasses camera stopped.")
      }
    default:
      // waitingForDevice, starting, paused, stopping
      streamWasActive = true
    }
    publishStatus()
  }

  private func handleStreamError(_ error: MWDATCamera.StreamError, generation: Int) {
    guard generation == sessionGeneration else { return }
    report(error.localizedDescription)
  }

  private func announceFrame() {
    guard streamState == .streaming, UIApplication.shared.applicationState == .active else { return }
    let millis = Int(Date().timeIntervalSince1970 * 1000)
    sink?.sendToWeb(["type": "frame", "url": "/__native/frame?t=\(millis)"])
  }

  // MARK: - Photos

  private func handlePhoto(_ data: Data, generation: Int) {
    // A photo nobody asked for through the app (none pending) is not scanned.
    guard generation == sessionGeneration, let id = pendingCaptureId else { return }
    guard let jpeg = Self.jpegData(from: data) else {
      failCapture(id: id, reason: "The photo from the glasses could not be read.")
      return
    }
    deliverPhoto(id: id, jpeg: jpeg)
  }

  /// When the still capture cannot be had, scan the newest stream frame instead: lower
  /// resolution, but the same point of view.
  private func deliverFallbackFrame(id: String, why: String) {
    guard pendingCaptureId == id else { return }
    guard let frame = media.latestFrame() else {
      failCapture(id: id, reason: why)
      return
    }
    deliverPhoto(id: id, jpeg: frame)
  }

  private func deliverPhoto(id: String, jpeg: Data) {
    guard pendingCaptureId == id else { return }
    pendingCaptureId = nil
    captureTimeoutTask?.cancel()
    captureTimeoutTask = nil

    media.storePhoto(id: id, data: jpeg)
    awaitingResultId = id
    sink?.sendToWeb([
      "type": "photo",
      "id": id,
      "url": "/__native/photo/\(id)",
      "source": "glasses",
    ])

    resultTimeoutTask?.cancel()
    resultTimeoutTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(20))
      guard let self, !Task.isCancelled, self.awaitingResultId == id else { return }
      self.awaitingResultId = nil
      self.showOnLens(.failure(reason: "No answer from the phone. Keep Chess Lens open and on screen."))
    }
  }

  private func failCapture(id: String, reason: String) {
    guard pendingCaptureId == id else { return }
    pendingCaptureId = nil
    captureTimeoutTask?.cancel()
    captureTimeoutTask = nil
    report(reason)
    showOnLens(.failure(reason: reason))
  }

  private static func jpegData(from data: Data) -> Data? {
    if data.count > 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 {
      return data
    }
    return UIImage(data: data)?.jpegData(compressionQuality: 0.92)
  }

  private static func makeId() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }

  // MARK: - Display

  /// If the stream never reaches `.streaming` (camera permission refused, for one), the
  /// display is still worth having for scans made with the phone camera.
  private func scheduleDisplayFallback() {
    displayFallbackTask?.cancel()
    displayFallbackTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(4))
      guard let self, !Task.isCancelled else { return }
      self.attachDisplayIfNeeded()
    }
  }

  private func attachDisplayIfNeeded() {
    guard display == nil, let session = deviceSession, session.state == .started else { return }
    guard let device = activeDevice, device.supportsDisplay() else { return }

    let capability: MWDATDisplay.Display
    do {
      capability = try session.addDisplay()
    } catch {
      report("The glasses display could not be attached: \(error.localizedDescription)")
      return
    }
    display = capability
    displayStateName = "starting"
    let generation = sessionGeneration
    capability.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleDisplayState(state, generation: generation) }
    }.store(in: displayTokens)
    capability.start()
    publishStatus()
  }

  private func handleDisplayState(_ state: MWDATDisplay.DisplayState, generation: Int) {
    guard display != nil, generation == sessionGeneration else { return }
    switch state {
    case .starting:
      displayStateName = "starting"
    case .started:
      displayStateName = "started"
      // Whatever card is current — the idle card on first start.
      renderLens()
    case .stopping:
      displayStateName = "stopping"
    case .stopped:
      displayStateName = "stopped"
    default:
      displayStateName = String(describing: state)
    }
    publishStatus()
  }

  private func showOnLens(_ card: LensCard) {
    lensCard = card
    renderLens()
  }

  /// Sends the current card. Sends are serialised and always read the newest card, so a
  /// slow send can never land a stale screen after a newer one.
  private func renderLens() {
    guard display != nil else { return }
    lensDirty = true
    guard !lensSending else { return }
    lensSending = true
    Task { [weak self] in
      while let self, self.lensDirty {
        self.lensDirty = false
        await self.sendCurrentCard()
      }
      self?.lensSending = false
    }
  }

  private func sendCurrentCard() async {
    guard let display else { return }

    // A display that went down (a photo transfer can take it with it) is started again
    // on the way through; start() is only honoured on a stopped capability.
    if display.state != .started {
      display.start()
      for _ in 0..<10 where display.state != .started {
        try? await Task.sleep(for: .milliseconds(300))
      }
    }
    guard display.state == .started else {
      report("The glasses display did not start.")
      return
    }

    let view = LensCards.view(
      for: lensCard,
      onScan: { [weak self] in
        Task { @MainActor in self?.capture() }
      },
      onFlip: { [weak self] in
        Task { @MainActor in self?.requestFlip() }
      }
    )
    do {
      try await display.send(view)
    } catch {
      report("Could not update the glasses display: \((error as? MWDATDisplay.DisplayError)?.description ?? error.localizedDescription)")
    }
  }

  private func requestFlip() {
    sink?.sendToWeb(["type": "command", "name": "flip"])
  }

  // MARK: - Status for the web app

  func publishStatus() {
    let device = activeDevice
    var deviceName: Any = NSNull()
    if let device {
      if mockEnabled {
        deviceName = "Simulated glasses"
      } else {
        deviceName = device.name.isEmpty ? "Meta glasses" : device.name
      }
    }
    let status: [String: Any] = [
      "type": "status",
      "registration": Self.name(of: registrationState),
      "session": Self.name(of: sessionState),
      "camera": Self.name(of: streamState),
      "display": displayStateName,
      "deviceName": deviceName,
      "hasDisplay": device?.supportsDisplay() ?? false,
      "mock": mockEnabled,
      "error": lastError.map { $0 as Any } ?? NSNull(),
    ]
    sink?.sendToWeb(status)
  }

  private static func name(of state: RegistrationState) -> String {
    switch state {
    case .registered: return "registered"
    case .registering: return "registering"
    case .available: return "available"
    case .unavailable: return "unavailable"
    default: return String(describing: state)
    }
  }

  private static func name(of state: DeviceSessionState) -> String {
    switch state {
    case .idle: return "idle"
    case .starting: return "starting"
    case .started: return "started"
    case .paused: return "paused"
    case .stopping: return "stopping"
    case .stopped: return "stopped"
    default: return String(describing: state)
    }
  }

  private static func name(of state: MWDATCamera.StreamState) -> String {
    switch state {
    case .stopped: return "stopped"
    case .waitingForDevice: return "waitingForDevice"
    case .starting: return "starting"
    case .streaming: return "streaming"
    case .paused: return "paused"
    case .stopping: return "stopping"
    default: return String(describing: state)
    }
  }
}

private enum MockSetupError: LocalizedError {
  case deviceReadinessTimedOut

  var errorDescription: String? {
    switch self {
    case .deviceReadinessTimedOut:
      return "Timed out waiting for the simulated glasses to connect."
    }
  }
}
