import SwiftUI

/// The compact strip you see in the iMessage app drawer: your markets as tiles, plus
/// "New" and "Join". The same view lays out as a grid when expanded.
struct DrawerView: View {
    let store: MarketStore
    let host: ConversationHost
    let onOpen: (League) -> Void
    let onNew: () -> Void
    let onJoin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Fantasy Market")
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.chalk)
                Spacer()
                Text(store.memberships.isEmpty ? "Play money only" : "\(store.memberships.count) market\(store.memberships.count == 1 ? "" : "s")")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if host.isExpanded {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        tiles
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        tiles
                    }
                    .padding(.horizontal, 16)
                }
            }
            Spacer(minLength: 0)
        }
        .task { await store.loadMyLeagues() }
    }

    @ViewBuilder
    private var tiles: some View {
        ForEach(store.memberships) { membership in
            Button { onOpen(membership.leagues) } label: {
                LeagueTile(membership: membership)
            }
            .buttonStyle(.plain)
        }
        Button(action: onNew) {
            ActionTile(symbol: "plus", title: "New market", subtitle: "Pick the teams")
        }
        .buttonStyle(.plain)
        Button(action: onJoin) {
            ActionTile(symbol: "number", title: "Join", subtitle: "Enter an invite code")
        }
        .buttonStyle(.plain)
    }
}

struct LeagueTile: View {
    let membership: MembershipWithLeague

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(membership.leagues.name)
                    .font(Theme.display(19, weight: .semibold))
                    .foregroundStyle(Theme.chalk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                StatusPill(status: membership.leagues.status)
            }
            Spacer(minLength: 0)
            Text(Fmt.money(membership.cash_balance - membership.reserved_cash))
                .font(Theme.display(22))
                .foregroundStyle(Theme.chalk)
            Text("cash · invite \(membership.leagues.invite_code)")
                .font(Theme.body(11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(12)
        .frame(width: 160, height: 118, alignment: .topLeading)
        .background(Theme.turf, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
    }
}

struct ActionTile: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.field)
                .frame(width: 34, height: 34)
                .background(Theme.gold, in: Circle())
            Spacer(minLength: 0)
            Text(title)
                .font(Theme.display(19, weight: .semibold))
                .foregroundStyle(Theme.chalk)
            Text(subtitle)
                .font(Theme.body(11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(12)
        .frame(width: 160, height: 118, alignment: .topLeading)
        .background(Theme.turf.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

struct StatusPill: View {
    let status: String

    var body: some View {
        Text(status == "settled" ? "SETTLED" : status == "closed" ? "CLOSED" : "LIVE")
            .font(Theme.display(11, weight: .bold))
            .foregroundStyle(status == "open" ? Theme.field : Theme.chalk)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(status == "open" ? Theme.bid : Theme.turf2, in: Capsule())
    }
}
