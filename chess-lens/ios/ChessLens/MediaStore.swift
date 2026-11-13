import Foundation

/// Pixels on their way from the glasses to the web view.
///
/// The web side never receives image bytes over the JS bridge; it is told a URL
/// (`/__native/photo/<id>`, `/__native/frame`) and fetches it through the app's
/// scheme handler, which reads from here. Written from the SDK's listener threads,
/// read on the main thread, hence the lock.
final class MediaStore: @unchecked Sendable {
  private let lock = NSLock()
  private var photos: [(id: String, data: Data)] = []
  private var frame: Data?
  private let maxPhotos = 4

  func storePhoto(id: String, data: Data) {
    lock.lock()
    defer { lock.unlock() }
    photos.removeAll { $0.id == id }
    photos.append((id, data))
    if photos.count > maxPhotos {
      photos.removeFirst(photos.count - maxPhotos)
    }
  }

  func photo(id: String) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return photos.first { $0.id == id }?.data
  }

  func setFrame(_ data: Data?) {
    lock.lock()
    defer { lock.unlock() }
    frame = data
  }

  func latestFrame() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return frame
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    photos.removeAll()
    frame = nil
  }
}

/// Lets through at most one event per `interval`. Used to turn the camera stream
/// into ~2 preview frames per second without encoding every frame.
final class Throttle: @unchecked Sendable {
  private let lock = NSLock()
  private let interval: TimeInterval
  private var last: TimeInterval = 0

  init(interval: TimeInterval) {
    self.interval = interval
  }

  func shouldEmit() -> Bool {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    defer { lock.unlock() }
    guard now - last >= interval else { return false }
    last = now
    return true
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    last = 0
  }
}
