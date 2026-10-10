import SwiftUI

struct ClaimTeamView: View {
    let store: MarketStore
    let onClose: () -> Void
    @State private var selected: UUID?
    @State private var claiming = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: "Which team is yours?", onClose: onClose)
                Text("Choose yourself in \(store.league?.name ?? "this league"). Each team can be claimed by one person.")
                    .font(Theme.body(15)).foregroundStyle(Theme.muted)
                ForEach(store.rosterTeams) { team in
                    Button { selected = team.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(team.manager_name ?? "").font(Theme.display(20))
                                Text(team.name).font(Theme.body(14)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            if team.claimed_by != nil {
                                Text("Claimed").font(Theme.body(13)).foregroundStyle(Theme.muted)
                            } else {
                                Image(systemName: selected == team.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected == team.id ? Theme.gold : Theme.muted)
                            }
                        }.padding(12).background(Theme.turf, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(claiming || team.claimed_by != nil)
                }
                if let error { Text(error).font(Theme.body(14)).foregroundStyle(Theme.ask) }
                Button(claiming ? "Claiming…" : "This is my team") {
                    guard let team = store.rosterTeams.first(where: { $0.id == selected }) else { return }
                    claiming = true
                    Task {
                        defer { claiming = false }
                        do { try await store.claimTeam(team) }
                        catch { self.error = error.marketMessage; await store.refresh(); selected = nil }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(claiming || selected == nil || store.rosterTeams.first(where: { $0.id == selected })?.claimed_by != nil)
                Text("Pick carefully. Use this iPhone for the beta; moving your team to another device or changing your selection is not supported yet.")
                    .font(Theme.body(13)).foregroundStyle(Theme.muted)
            }.padding(16).foregroundStyle(Theme.chalk)
        }.refreshable { await store.refresh() }
    }
}
