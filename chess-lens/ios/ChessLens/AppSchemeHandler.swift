import Foundation
import UniformTypeIdentifiers
import WebKit

/// The web app's origin inside the app: `chesslens://app/`.
enum AppScheme {
  static let name = "chesslens"
  static let host = "app"
  static let startURL = URL(string: "chesslens://app/index.html")!
  static let nativePrefix = "/__native/"
}

/// Serves the bundled web app (`Bundle.main/web/**`) and native media
/// (`/__native/photo/<id>`, `/__native/frame`) to the web view.
///
/// A custom scheme rather than `file://` so ES modules, `fetch` and
/// `localStorage` behave as they do on a real origin.
@MainActor
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
  private let webRoot: URL?
  private let media: MediaStore

  init(media: MediaStore) {
    self.media = media
    self.webRoot = Bundle.main.url(forResource: "web", withExtension: nil)?
      .resolvingSymlinksInPath()
      .standardizedFileURL
    super.init()
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url else {
      urlSchemeTask.didFailWithError(URLError(.badURL))
      return
    }
    let reply = response(for: url)
    var headers = reply.headers
    headers["Content-Type"] = reply.contentType
    headers["Content-Length"] = String(reply.body.count)
    guard
      let http = HTTPURLResponse(
        url: url,
        statusCode: reply.status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
      )
    else {
      urlSchemeTask.didFailWithError(URLError(.badServerResponse))
      return
    }
    urlSchemeTask.didReceive(http)
    urlSchemeTask.didReceive(reply.body)
    urlSchemeTask.didFinish()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
    // Every request is answered synchronously in `start`, so there is nothing to cancel.
  }

  // MARK: - Routing

  private struct Reply {
    var status: Int
    var contentType: String
    var headers: [String: String]
    var body: Data

    static func notFound(_ what: String) -> Reply {
      Reply(
        status: 404,
        contentType: "text/plain; charset=utf-8",
        headers: ["Cache-Control": "no-store"],
        body: Data("Not found: \(what)".utf8)
      )
    }
  }

  private func response(for url: URL) -> Reply {
    guard url.scheme?.lowercased() == AppScheme.name, url.host?.lowercased() == AppScheme.host else {
      return .notFound(url.absoluteString)
    }
    // `path` is already percent-decoded.
    let path = url.path.isEmpty ? "/" : url.path
    if path.hasPrefix(AppScheme.nativePrefix) {
      return nativeMedia(path: path)
    }
    return bundledFile(path: path)
  }

  private func nativeMedia(path: String) -> Reply {
    let rest = String(path.dropFirst(AppScheme.nativePrefix.count))
    let noStore = ["Cache-Control": "no-store"]

    if rest == "frame" {
      guard let frame = media.latestFrame() else { return .notFound(path) }
      return Reply(status: 200, contentType: "image/jpeg", headers: noStore, body: frame)
    }
    if rest.hasPrefix("photo/") {
      let id = String(rest.dropFirst("photo/".count))
      guard !id.isEmpty, let photo = media.photo(id: id) else { return .notFound(path) }
      return Reply(status: 200, contentType: "image/jpeg", headers: noStore, body: photo)
    }
    return .notFound(path)
  }

  private func bundledFile(path: String) -> Reply {
    guard let webRoot else { return .notFound("web bundle") }

    // Reject anything that tries to climb out of the bundle before touching the disk.
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !components.contains(where: { $0 == ".." || $0 == "." || $0.contains("\0") || $0.contains("\\") }) else {
      return .notFound(path)
    }

    var fileURL = webRoot
    for component in components {
      fileURL.appendPathComponent(component)
    }

    var isDirectory: ObjCBool = false
    if components.isEmpty
      || (FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    {
      fileURL.appendPathComponent("index.html")
    }

    // And check again after resolving symlinks: the file must still be inside the bundle.
    let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
    let rootPath = webRoot.path.hasSuffix("/") ? webRoot.path : webRoot.path + "/"
    guard resolved.path.hasPrefix(rootPath) else { return .notFound(path) }

    guard let data = try? Data(contentsOf: resolved) else { return .notFound(path) }
    return Reply(
      status: 200,
      contentType: Self.mimeType(forExtension: resolved.pathExtension),
      // The bundle only changes with the app, but the web view must never hold on to
      // a stale copy across an app update.
      headers: ["Cache-Control": "no-cache"],
      body: data
    )
  }

  private static let mimeTypes: [String: String] = [
    "html": "text/html; charset=utf-8",
    "htm": "text/html; charset=utf-8",
    "js": "text/javascript; charset=utf-8",
    "mjs": "text/javascript; charset=utf-8",
    "css": "text/css; charset=utf-8",
    "json": "application/json; charset=utf-8",
    "map": "application/json; charset=utf-8",
    "webmanifest": "application/manifest+json; charset=utf-8",
    "txt": "text/plain; charset=utf-8",
    "svg": "image/svg+xml",
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "gif": "image/gif",
    "webp": "image/webp",
    "ico": "image/x-icon",
    "bin": "application/octet-stream",
    "wasm": "application/wasm",
    "woff": "font/woff",
    "woff2": "font/woff2",
    "ttf": "font/ttf",
  ]

  static func mimeType(forExtension ext: String) -> String {
    let key = ext.lowercased()
    if let known = mimeTypes[key] {
      return known
    }
    return UTType(filenameExtension: key)?.preferredMIMEType ?? "application/octet-stream"
  }
}
