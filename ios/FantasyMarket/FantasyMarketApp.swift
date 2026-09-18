import SwiftUI
@main
struct FantasyMarketApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("Fantasy Market").font(.largeTitle.bold())
                Text("Open Messages → + → Fantasy Market to trade with your league.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }.padding()
        }
    }
}
