import SwiftUI
@main
struct FantasyMarketApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 20) {
                Text("Fantasy Market").font(.largeTitle.bold())
                Text("A play-money prediction market for your fantasy league.")
                    .font(.title3)
                Text("1. Open your league's conversation in Messages.")
                Text("2. Tap +, scroll down, and choose Fantasy Market.")
                Text("3. Import your league standings, or join with an invite code and choose your team.")
                Text("No deposits, prizes, withdrawals, or real-money payouts.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("During the beta, use the same iPhone. Team selection and account recovery across devices aren't supported yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(24)
        }
    }
}
