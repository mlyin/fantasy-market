import SwiftUI
import UIKit
import WebKit

/// The full-screen web view that hosts the shared web core, and the JS bridge to it.
///
/// Web → native: `window.webkit.messageHandlers.chessLens.postMessage({type, ...})`
/// Native → web: `window.ChessLensNative.receive({type, ...})`
struct WebContainer: UIViewRepresentable {
  let glasses: GlassesController

  func makeCoordinator() -> WebCoordinator {
    WebCoordinator(glasses: glasses)
  }

  func makeUIView(context: Context) -> WKWebView {
    let coordinator = context.coordinator

    let configuration = WKWebViewConfiguration()
    configuration.allowsInlineMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []
    configuration.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: AppScheme.name)
    configuration.userContentController.add(
      WeakScriptMessageHandler(coordinator),
      name: WebCoordinator.handlerName
    )

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.uiDelegate = coordinator
    webView.navigationDelegate = coordinator
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.scrollView.bounces = false
    webView.allowsLinkPreview = false
    webView.isOpaque = false
    webView.backgroundColor = .systemBackground
    #if DEBUG
    webView.isInspectable = true
    #endif

    coordinator.attach(webView)
    webView.load(URLRequest(url: AppScheme.startURL))
    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {}
}

/// `WKUserContentController` retains its handlers; this keeps the coordinator from
/// being kept alive by the web view it owns.
@MainActor
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  private weak var target: (any WKScriptMessageHandler)?

  init(_ target: any WKScriptMessageHandler) {
    self.target = target
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    target?.userContentController(userContentController, didReceive: message)
  }
}

@MainActor
final class WebCoordinator: NSObject, WebMessageSink {
  static let handlerName = "chessLens"

  let schemeHandler: AppSchemeHandler
  private let glasses: GlassesController
  private weak var webView: WKWebView?

  init(glasses: GlassesController) {
    self.glasses = glasses
    self.schemeHandler = AppSchemeHandler(media: glasses.media)
    super.init()
    glasses.sink = self
  }

  func attach(_ webView: WKWebView) {
    self.webView = webView
  }

  // MARK: - Native → web

  func sendToWeb(_ message: [String: Any]) {
    guard let webView else { return }
    guard
      JSONSerialization.isValidJSONObject(message),
      let data = try? JSONSerialization.data(withJSONObject: message),
      let json = String(data: data, encoding: .utf8)
    else {
      return
    }
    // JSON is a valid JavaScript expression, so it can be passed as a literal.
    webView.evaluateJavaScript(
      "window.ChessLensNative && window.ChessLensNative.receive(\(json));",
      completionHandler: nil
    )
  }

  // MARK: - Web → native

  fileprivate func handle(_ body: [String: Any]) {
    guard let type = body["type"] as? String else { return }
    switch type {
    case "ready":
      glasses.webIsReady()
    case "connect":
      Task { await glasses.connect() }
    case "disconnect":
      Task { await glasses.disconnect() }
    case "capture":
      glasses.capture()
    case "scanResult":
      glasses.handleScanResult(body)
    case "position":
      glasses.handlePosition(body)
    case "setMock":
      let enabled = (body["enabled"] as? Bool) ?? false
      Task { await glasses.setMock(enabled) }
    case "lensPreview":
      glasses.setLensPreview(visible: (body["visible"] as? Bool) ?? false)
    default:
      glasses.report("Unknown message from the web app: \(type)")
    }
  }

  private static func isOurOrigin(_ origin: WKSecurityOrigin) -> Bool {
    origin.protocol.lowercased() == AppScheme.name && origin.host.lowercased() == AppScheme.host
  }
}

// MARK: - WKScriptMessageHandler

extension WebCoordinator: WKScriptMessageHandler {
  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    // Only the bundled app's own top-level page may drive the glasses.
    guard
      message.name == Self.handlerName,
      message.frameInfo.isMainFrame,
      Self.isOurOrigin(message.frameInfo.securityOrigin),
      let body = message.body as? [String: Any]
    else {
      return
    }
    handle(body)
  }
}

// MARK: - WKNavigationDelegate

extension WebCoordinator: WKNavigationDelegate {
  /// The web view only ever shows the bundled app. Anything else (an "open in Lichess"
  /// link, say) goes to the system browser instead of replacing the app.
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
      return .cancel
    }
    if scheme == AppScheme.name || scheme == "about" || scheme == "blob" || scheme == "data" {
      return .allow
    }
    let isTopLevel = navigationAction.targetFrame?.isMainFrame ?? true
    if isTopLevel, scheme == "https" || scheme == "http" || scheme == "mailto" {
      _ = await UIApplication.shared.open(url)
    }
    return .cancel
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
    glasses.report("The app page failed to load: \(error.localizedDescription)")
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    glasses.report("The app page failed to load: \(error.localizedDescription)")
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    // The web process was killed (memory pressure): bring the app page back.
    webView.load(URLRequest(url: AppScheme.startURL))
  }
}

// MARK: - WKUIDelegate

extension WebCoordinator: WKUIDelegate {
  /// `window.open` / `target="_blank"`: never a second web view; external pages go to
  /// the system browser.
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http"
    {
      UIApplication.shared.open(url)
    }
    return nil
  }

  /// The bundled page may use the phone camera (`getUserMedia`) without a second,
  /// per-page prompt on top of the system camera permission. Nothing else may.
  ///
  /// The explicit selector keeps this reachable from WebKit whichever closure
  /// annotations the SDK in use declares on the protocol requirement.
  @objc(webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:)
  func webView(
    _ webView: WKWebView,
    requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo,
    type: WKMediaCaptureType,
    decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
  ) {
    let allowed = Self.isOurOrigin(origin) && frame.isMainFrame && type == .camera
    decisionHandler(allowed ? .grant : .deny)
  }
}
