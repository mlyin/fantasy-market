import SwiftUI

/// Create a league: one "wins the league" contract per team, everyone starts with $10,000.
/// On success the invite bubble is staged in the chat so the group can tap in.
struct NewMarketView: View {
    let store: MarketStore
    let host: ConversationHost
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var name = "Fantasy 2026"
    @State private var teams = "Matthew\nMax\nAarush\nKarthik\nAshil"
    @State private var error: String?
    @State private var creating = false

    private var teamList: [String] {
        teams.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: "New market", onClose: onCancel)
                Text("Each team gets a contract that pays $1.00 if it wins the league. You are the commissioner: you settle it at the end.")
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.muted)
                LabeledField(label: "League name") {
                    TextField("League name", text: $name)
                        .textFieldStyle(.plain)
                        .fieldStyle()
                }
                LabeledField(label: "Teams, one per line (\(teamList.count))") {
                    TextEditor(text: $teams)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 150)
                        .fieldStyle()
                }
                if let error {
                    Text(error).font(Theme.body(15)).foregroundStyle(Theme.ask)
                }
                Button(creating ? "Opening…" : "Open the market", action: create)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(creating || teamList.count < 2 || name.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Opening the market drops an invite bubble into this chat. Send it and everyone can tap in.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted)
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func create() {
        guard !creating else { return }
        creating = true
        error = nil
        Task {
            defer { creating = false }
            do {
                let league = try await store.createLeague(name: name.trimmingCharacters(in: .whitespaces), teams: teamList)
                if let card = MarketMessage.snapshot(from: store, headline: "Market open · tap to trade") {
                    let message = MarketMessage.make(
                        invite: MarketInvite(league: league),
                        card: card,
                        caption: "\(host.senderToken) opened \(league.name)",
                        subcaption: "Tap to join with $10,000 of play money",
                        summary: "\(league.name) market is open",
                        session: nil)
                    host.stage(message, collapseAfter: false)
                }
                store.flash("Market open · invite \(league.invite_code)")
                onDone()
            } catch {
                self.error = error.marketMessage
            }
        }
    }
}
