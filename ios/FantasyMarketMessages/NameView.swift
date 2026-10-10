import SwiftUI

/// Establishes the device's session; league identity is chosen from the roster.
struct NameView: View {
    let store: MarketStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your league. Your team.")
                .font(Theme.display(24)).foregroundStyle(Theme.chalk)
            Text("Join a market and choose yourself from its roster, or import your league to start one.")
                .font(Theme.body(15)).foregroundStyle(Theme.muted)
            Button(store.isBusy ? "Opening…" : "Continue") {
                Task { await store.signIn(displayName: "League member") }
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(store.isBusy)
            Text("Play money only. No deposits or payouts.")
                .font(Theme.body(13)).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
