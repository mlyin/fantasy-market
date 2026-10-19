import SwiftUI

struct NewMarketView: View {
    let store: MarketStore
    let host: ConversationHost
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var roster: [RosterEntry] = []
    @State private var reviewed = false
    @State private var error: String?
    @State private var creating = false

    private var valid: Bool {
        (2...32).contains(roster.count) && roster.allSatisfy(\.isComplete) &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reviewed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: "Your league roster", onClose: onCancel)
                Text("Enter your teams and managers, review the roster, then let everyone choose who they are when they join.")
                    .font(Theme.body(15)).foregroundStyle(Theme.muted)
                LabeledField(label: "League name") {
                    TextField("League name", text: $name, prompt: Text("e.g. Fantasy 2026").foregroundStyle(Theme.muted))
                        .textFieldStyle(.plain).fieldStyle()
                        .accessibilityIdentifier("roster.leagueName")
                }
                if !roster.isEmpty {
                    Text("Review \(roster.count) teams").font(Theme.display(22))
                }
                ForEach($roster) { $entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Team and manager").font(Theme.body(13)).foregroundStyle(Theme.muted)
                            Spacer()
                            Button { roster.removeAll { $0.id == entry.id } } label: {
                                Image(systemName: "minus.circle")
                            }.accessibilityLabel("Remove \(entry.team.isEmpty ? "team" : entry.team)")
                        }
                        TextField("Team name", text: $entry.team, prompt: Text("Team name").foregroundStyle(Theme.muted))
                            .textFieldStyle(.plain).fieldStyle()
                        TextField("Manager name", text: $entry.manager, prompt: Text("Manager name").foregroundStyle(Theme.muted))
                            .textFieldStyle(.plain).fieldStyle()
                    }.padding(12).background(Theme.turf, in: RoundedRectangle(cornerRadius: 12))
                }
                Button("Add team") { roster.append(RosterEntry(team: "", manager: "")) }
                    .buttonStyle(GhostButtonStyle()).disabled(roster.count >= 32 || creating)
                if !roster.isEmpty {
                    Toggle("I checked the names and team count", isOn: $reviewed)
                        .font(Theme.body(15)).tint(Theme.bid)
                }
                if let error { Text(error).font(Theme.body(15)).foregroundStyle(Theme.ask) }
                Button(creating ? "Opening…" : "Open the market", action: create)
                    .buttonStyle(PrimaryButtonStyle()).disabled(creating || !valid)
                Text("Each team gets a contract that pays $1.00 if it wins. Everyone starts with $10,000 of play money. Opening stages an invite in Messages for you to send.")
                    .font(Theme.body(13)).foregroundStyle(Theme.muted)
            }.padding(16).foregroundStyle(Theme.chalk).disabled(creating)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: roster) { _, _ in reviewed = false }
    }

    private func create() {
        guard !creating, valid else { return }
        creating = true
        error = nil
        Task {
            defer { creating = false }
            do {
                let league = try await store.createRosterLeague(name: name.trimmingCharacters(in: .whitespacesAndNewlines), roster: roster)
                if let card = MarketMessage.snapshot(from: store, headline: "Market open · choose your team") {
                    host.stage(MarketMessage.make(
                        invite: MarketInvite(league: league), card: card,
                        caption: "\(host.senderToken) opened \(league.name)",
                        subcaption: "Tap to choose your team and join",
                        summary: "\(league.name) market is open", session: nil), collapseAfter: false)
                }
                onDone()
            } catch { self.error = error.marketMessage }
        }
    }
}
