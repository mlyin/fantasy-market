import SwiftUI

/// The expanded trading screen, laid out like the reference League Market page:
/// header with equity, one row per team with a bid/ask cell, then your orders,
/// positions, standings and the tape.
struct BoardView: View {
    let store: MarketStore
    let host: ConversationHost
    let onBack: () -> Void

    @State private var ticket: Contract?
    @State private var showSets = false
    @State private var showSettle = false
    @State private var settling = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let league = store.league {
                    if league.isSettled, let winner = league.winning_contract_id.flatMap(store.contract(id:)) {
                        Banner(text: "\(winner.name) won. Contracts have paid out, final standings are below.")
                    }
                    board
                    Text("Each cell is bid / ask in cents with the mark underneath. Tap one to see the book and trade.")
                        .font(Theme.body(13)).foregroundStyle(Theme.muted)
                        .padding(.top, 8)
                    BoardSection(title: "Your open orders") { ordersList }
                    BoardSection(title: "Your positions") { positionsList }
                    BoardSection(title: "Standings") { standingsList }
                    BoardSection(title: "Recent trades") { tape }
                    if store.isCommissioner && league.isOpen { commissioner }
                } else {
                    ProgressView("Opening market…")
                        .tint(Theme.chalk)
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .refreshable { await store.refresh() }
        .sheet(item: $ticket) { contract in
            OrderTicketView(store: store, host: host, contract: contract)
        }
        .sheet(isPresented: $showSets) {
            CompleteSetsView(store: store)
        }
        .confirmationDialog("Who won the league?", isPresented: $showSettle, titleVisibility: .visible) {
            ForEach(store.contracts) { contract in
                Button(contract.name) { settle(winner: contract) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Winning contracts pay $1.00, the rest pay $0, and every open order is cancelled. This cannot be undone.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.chalk)
                    .frame(width: 34, height: 34)
                    .background(Theme.turf, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to your markets")
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(store.league?.name ?? "League")
                    .font(Theme.display(30))
                    .foregroundStyle(Theme.chalk)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("Where does each team finish? Contracts pay $1.00.")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.muted)
                    Circle().fill(store.isLive ? Theme.bid : Theme.muted).frame(width: 8, height: 8)
                        .accessibilityLabel(store.isLive ? "Live" : "Not live")
                }
                if let league = store.league {
                    HStack(spacing: 8) {
                        Text("Invite \(league.invite_code)")
                            .font(Theme.display(14, weight: .semibold))
                            .foregroundStyle(Theme.gold)
                        Button(action: shareInvite) {
                            Label("Share in chat", systemImage: "arrow.up.message")
                                .font(Theme.body(13, weight: .semibold))
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.money(store.myEquity))
                    .font(Theme.display(28))
                    .foregroundStyle(Theme.chalk)
                Text("equity").font(Theme.body(12)).foregroundStyle(Theme.muted)
                if let me = store.me {
                    Text("cash \(Fmt.money(me.availableCash))")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.top, 10)
    }

    // MARK: Board

    private var board: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Team").frame(maxWidth: .infinity, alignment: .leading)
                Text("Win").frame(width: 84)
            }
            .font(Theme.body(13)).foregroundStyle(Theme.muted)
            .padding(.vertical, 8)
            Divider().overlay(Theme.line)
            ForEach(store.contracts) { contract in
                let quote = store.quote(for: contract)
                let position = store.position(for: contract)
                let won = store.league?.isSettled == true && store.league?.winning_contract_id == contract.id
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contract.name)
                            .font(Theme.display(21, weight: .semibold))
                            .foregroundStyle(Theme.chalk)
                            .lineLimit(1)
                        positionLine(position: position, volume: quote.volume)
                    }
                    Spacer(minLength: 0)
                    Button {
                        guard store.league?.isOpen == true else { store.flash("Market is settled"); return }
                        ticket = contract
                    } label: {
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                Text(quote.bestBid.map(String.init) ?? "–").foregroundStyle(Theme.bid)
                                Text("/").foregroundStyle(Theme.muted).fontWeight(.regular)
                                Text(quote.bestAsk.map(String.init) ?? "–").foregroundStyle(Theme.ask)
                            }
                            .font(Theme.display(19, weight: .semibold))
                            Text(Fmt.cents(store.mark(for: contract)))
                                .font(Theme.display(12, weight: .medium))
                                .foregroundStyle(Theme.muted)
                        }
                        .frame(width: 84, height: 50)
                        .background(Theme.turf, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(won ? Theme.gold : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 8)
                Divider().overlay(Theme.line)
            }
        }
        .padding(.top, 14)
    }

    @ViewBuilder
    private func positionLine(position: Position?, volume: Int) -> some View {
        if let position, position.quantity > 0 {
            (Text("you ") + Text(Fmt.signed(position.quantity)).foregroundColor(Theme.gold).fontWeight(.semibold) + Text(" to win"))
                .font(Theme.body(12.5)).foregroundStyle(Theme.muted)
        } else if volume > 0 {
            Text("\(Fmt.n(volume)) traded").font(Theme.body(12.5)).foregroundStyle(Theme.muted)
        } else {
            Text("no trades yet").font(Theme.body(12.5)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Lists

    @ViewBuilder
    private var ordersList: some View {
        let orders = store.myOpenOrders
        if orders.isEmpty {
            EmptyRow(text: store.league?.isSettled == true ? "The market is settled." : "No open orders. Tap a price above to place one.")
        } else {
            ForEach(orders) { order in
                let team = store.contract(id: order.contract_id)?.name ?? "Team"
                ListItem {
                    HStack(spacing: 4) {
                        Text(order.isBuy ? "Buy" : "Sell").foregroundStyle(order.isBuy ? Theme.bid : Theme.ask)
                        Text("\(team) to win")
                    }
                } detail: {
                    Text("\(Fmt.n(order.remaining)) of \(Fmt.n(order.quantity)) left at \(order.price_cents)¢")
                } trailing: {
                    Button("Cancel") { cancel(order) }.buttonStyle(GhostButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private var positionsList: some View {
        let positions = store.myPositions
        if positions.isEmpty {
            EmptyRow(text: "Flat. No positions yet.")
        } else {
            ForEach(positions, id: \.contract_id) { position in
                if let contract = store.contract(id: position.contract_id) {
                    let mark = store.mark(for: contract)
                    let value = Int((Double(position.quantity) * mark).rounded())
                    ListItem {
                        Text("\(contract.name) to win")
                    } detail: {
                        Text("long \(Fmt.n(position.quantity)), marked \(Fmt.cents(mark))")
                    } trailing: {
                        Text(Fmt.money(value)).font(Theme.display(19, weight: .semibold)).foregroundStyle(Theme.chalk)
                    }
                }
            }
        }
        if store.league?.isOpen == true {
            Button("Buy complete sets to short a team") { showSets = true }
                .buttonStyle(GhostButtonStyle())
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var standingsList: some View {
        let rows = store.standings
        if rows.isEmpty {
            EmptyRow(text: "Nobody here yet.")
        } else {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                let isMe = row.member.user_id == store.userID
                let delta = row.equity - (store.league?.starting_cash ?? 0)
                ListItem {
                    HStack(spacing: 0) {
                        Text("\(index + 1)").foregroundStyle(Theme.muted).frame(width: 26, alignment: .leading)
                        Text(row.member.name).foregroundStyle(isMe ? Theme.gold : Theme.chalk)
                    }
                } detail: {
                    Text("cash \(Fmt.money(row.member.cash_balance))")
                } trailing: {
                    Text(Fmt.money(row.equity))
                        .font(Theme.display(20, weight: .semibold))
                        .foregroundStyle(delta < 0 ? Theme.ask : delta > 0 ? Theme.bid : Theme.chalk)
                }
            }
        }
    }

    @ViewBuilder
    private var tape: some View {
        if store.trades.isEmpty {
            EmptyRow(text: "Nothing has traded yet. First print gets bragging rights.")
        } else {
            ForEach(store.trades.prefix(25)) { trade in
                let team = store.contract(id: trade.contract_id)?.name ?? "Team"
                ListItem {
                    HStack(spacing: 6) {
                        Text("\(team) to win")
                        Text("\(trade.price_cents)¢").foregroundStyle(Theme.gold)
                        Text("× \(Fmt.n(trade.quantity))").foregroundStyle(Theme.muted).font(Theme.body(14))
                    }
                } detail: {
                    let when = trade.createdAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
                    Text("\(store.name(of: trade.buyer_id)) bought from \(store.name(of: trade.seller_id))\(when.isEmpty ? "" : ", \(when)")")
                } trailing: {
                    EmptyView()
                }
            }
        }
    }

    private var commissioner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Commissioner").font(Theme.display(22, weight: .semibold)).foregroundStyle(Theme.chalk)
                .padding(.top, 34)
            Text("When the season is over, pick the winner. Winning contracts pay $1.00, the rest pay $0, every order is cancelled, and a results bubble goes to the chat.")
                .font(Theme.body(13)).foregroundStyle(Theme.muted)
            Button(settling ? "Settling…" : "Settle market") { showSettle = true }
                .buttonStyle(GhostButtonStyle())
                .disabled(settling)
        }
    }

    // MARK: Actions

    private func cancel(_ order: Order) {
        Task {
            do { try await store.cancel(order: order); store.flash("Order cancelled") }
            catch { store.errorMessage = error.marketMessage }
        }
    }

    private func settle(winner: Contract) {
        settling = true
        Task {
            defer { settling = false }
            do {
                try await store.settle(winner: winner)
                if let league = store.league,
                   let card = MarketMessage.snapshot(from: store, headline: "\(winner.name) won the league") {
                    let message = MarketMessage.make(
                        invite: MarketInvite(league: league),
                        card: card,
                        caption: "\(host.senderToken) settled \(league.name): \(winner.name) won",
                        subcaption: "Tap to see the final standings",
                        summary: "\(league.name) settled, \(winner.name) won",
                        session: host.session(for: league.id))
                    host.stage(message)
                }
                store.flash("Market settled")
            } catch {
                store.errorMessage = error.marketMessage
            }
        }
    }

    private func shareInvite() {
        guard let league = store.league,
              let card = MarketMessage.snapshot(from: store, headline: "Tap to trade") else { return }
        let message = MarketMessage.make(
            invite: MarketInvite(league: league),
            card: card,
            caption: "\(host.senderToken) shared \(league.name)",
            subcaption: "Tap to join with $10,000 of play money",
            summary: "\(league.name) market",
            session: host.session(for: league.id))
        host.stage(message)
    }
}

// MARK: - List chrome

struct BoardSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Theme.display(22, weight: .semibold))
                .foregroundStyle(Theme.chalk)
                .padding(.top, 34)
                .padding(.bottom, 10)
            Divider().overlay(Theme.line)
            content
        }
    }
}

struct ListItem<Title: View, Detail: View, Trailing: View>: View {
    @ViewBuilder var title: Title
    @ViewBuilder var detail: Detail
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    title.font(Theme.display(19, weight: .semibold)).foregroundStyle(Theme.chalk)
                    detail.font(Theme.body(14)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.vertical, 11)
            Divider().overlay(Theme.line)
        }
    }
}

struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.body(15))
            .foregroundStyle(Theme.muted)
            .padding(.vertical, 14)
    }
}

struct Banner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.body(15, weight: .semibold))
            .foregroundStyle(Theme.chalk)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.turf2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 18)
    }
}
