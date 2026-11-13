import MWDATCore
import SwiftUI

@main
struct ChessLensApp: App {
  @StateObject private var glasses: GlassesController

  init() {
    do {
      try Wearables.configure()
    } catch {
      NSLog("[ChessLens] Failed to configure the Wearables SDK: \(error)")
    }
    _glasses = StateObject(wrappedValue: GlassesController(wearables: Wearables.shared))
  }

  var body: some Scene {
    WindowGroup {
      RootView(glasses: glasses)
        // The way back from the Meta AI app after registration and permission flows.
        // Filtered so unrelated deep links are never handed to the SDK.
        .onOpenURL { url in
          guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
          else {
            return
          }
          Task { @MainActor in
            do {
              _ = try await Wearables.shared.handleUrl(url)
            } catch {
              glasses.report("Meta AI could not finish the request: \(error.localizedDescription)")
            }
          }
        }
    }
  }
}
