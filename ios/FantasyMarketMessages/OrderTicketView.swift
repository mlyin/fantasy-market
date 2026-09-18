import SwiftUI

/// The bottom sheet from the reference page: book ladder, buy/sell, price and size
/// steppers with quick chips, a plain-English preview, then place the order and
/// (optionally) drop the result into the chat as a bubble.
struct OrderTicketView: View {
    let store: MarketStore
    let host: ConversationHost
    let contract: Contract

    @Environment(\.dismiss) private var dismiss
    @State private var side: Side = .buy
    @State private var priceText: String
    @State private var quantityText = "100"
    @State private var error: String?
    @State private var submitting = false
    @State private var postToChat = true

    init(store: MarketStore, host: ConversationHost, contract: Contract) {
        self.store = store
        self.host = host
        self.contract = contract
        _priceText = State(initialValue: String(Int(store.quote(for: contract).mark.rounded())))
    }

    private var quote: Quote { store.quote(for: contract) }
    private var price: Int { min(99, max(1, Int(priceText) ?? 0)) }
    private var quantity: Int { min(1_000_000, max(1, Int(quantityText.filter(\.isNumber)) ?? 0)) }
    private var held: Int { store.position(for: contract).map { $0.quantity - $0.reserved_quantity } ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Capsule().fill(Theme.line).frame(width: 40, height: 4).frame(maxWidth: .infinity)

                (Text(contract.name) + Text("  to win").font(Theme.display(20, weight: .medium)).foregroundColor(Theme.muted))
                    .font(Theme.display(28))
                    .foregroundStyle(Theme.chalk)
                Text(subtitle)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.muted)

                ladder
                sideSwitch
                ticket
                Text(preview)
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if side == .sell && quantity > held {
                    shortHint
                }
                if let error {
                    Text(error).font(Theme.body(15)).foregroundStyle(Theme.ask)
                }
                Toggle(isOn: $postToChat) {
                    Text("Post the result in the chat")
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.chalk)
                }
                .tint(Theme.bid)

                Button(submitting ? "Placing…" : (side == .buy ? "Place buy order" : "Place sell order"), action: submit)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(submitting)
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.turf)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Theme.turf)
    }

    // MARK: Pieces

    private var subtitle: String {
        var parts: [String] = []
        if let p = store.position(for: contract), p.quantity > 0 { parts.append("You are long \(Fmt.n(p.quantity)).") }
        if let last = quote.last { parts.append("Last trade \(last)¢, marked \(Fmt.cents(quote.mark)).") }
        else { parts.append("No trades yet, marked \(Fmt.cents(quote.mark)).") }
        return parts.joined(separator: " ")
    }

    private var ladder: some View {
        HStack(alignment: .top, spacing: 16) {
            ladderColumn(title: "Bids", levels: quote.bids, color: Theme.bid)
            ladderColumn(title: "Asks", levels: quote.asks, color: Theme.ask)
        }
    }

    private func ladderColumn(title: String, levels: [Quote.Level], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Theme.body(13)).foregroundStyle(Theme.muted).padding(.bottom, 6)
            if levels.isEmpty {
                HStack { Text("none").font(Theme.body(14)).foregroundStyle(Theme.muted); Spacer() }
                    .padding(.vertical, 5)
                Divider().overlay(Theme.line)
            }
            ForEach(levels.prefix(5), id: \.self) { level in
                HStack {
                    Text("\(level.price)¢").font(Theme.display(19, weight: .semibold)).foregroundStyle(color)
                    Spacer()
                    (Text(level.mine ? "you " : "").foregroundColor(Theme.gold) + Text(Fmt.n(level.quantity)))
                        .font(Theme.body(14)).foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 5)
                Divider().overlay(Theme.line)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var sideSwitch: some View {
        HStack(spacing: 6) {
            ForEach(Side.allCases, id: \.self) { s in
                Button {
                    side = s
                } label: {
                    Text(s == .buy ? "Buy" : "Sell")
                        .font(Theme.display(20, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .foregroundStyle(side == s ? Theme.field : Theme.muted)
                        .background(side == s ? (s == .buy ? Theme.bid : Theme.ask) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var ticket: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                LabeledField(label: "Price (¢)") {
                    StepperField(text: $priceText,
                                 down: { priceText = String(max(1, price - 1)) },
                                 up: { priceText = String(min(99, price + 1)) })
                }
                LabeledField(label: "Contracts") {
                    StepperField(text: $quantityText,
                                 down: { quantityText = String(max(1, quantity - (quantity > 100 ? 100 : 10))) },
                                 up: { quantityText = String(min(1_000_000, quantity + (quantity >= 100 ? 100 : 10))) })
                }
            }
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.label) { chip in
                            Button(chip.label) { priceText = String(chip.price) }
                                .font(Theme.body(14))
                                .foregroundStyle(Theme.chalk)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .overlay(Capsule().stroke(Theme.line))
                        }
                    }
                }
            }
        }
    }

    private struct Chip { let label: String; let price: Int }

    /// Same quick actions as the reference: lift/hit, join, improve by a cent.
    private var chips: [Chip] {
        let b = quote.bestBid, a = quote.bestAsk
        var out: [Chip] = []
        if side == .buy {
            if let a { out.append(Chip(label: "Lift the ask \(a)¢", price: a)) }
            if let b { out.append(Chip(label: "Join the bid \(b)¢", price: b)) }
            if let b, let a, a - b > 1 { out.append(Chip(label: "Improve the bid \(b + 1)¢", price: b + 1)) }
        } else {
            if let b { out.append(Chip(label: "Hit the bid \(b)¢", price: b)) }
            if let a { out.append(Chip(label: "Join the ask \(a)¢", price: a)) }
            if let b, let a, a - b > 1 { out.append(Chip(label: "Improve the ask \(a - 1)¢", price: a - 1)) }
        }
        return out
    }

    private var preview: String {
        let p = price, q = quantity, who = "\(contract.name) wins"
        return side == .buy
            ? "Costs up to \(Fmt.money(p * q)). Pays \(Fmt.money(100 * q)) if \(who), so you'd net \(Fmt.money((100 - p) * q))."
            : "Collects \(Fmt.money(p * q)) now. If \(who) you pay \(Fmt.money(100 * q)), a net loss of \(Fmt.money((100 - p) * q)). Otherwise you keep it all."
    }

    private var shortHint: some View {
        let needed = quantity - held
        return VStack(alignment: .leading, spacing: 8) {
            Text(held > 0
                 ? "You can sell \(Fmt.n(held)) right now. To sell \(Fmt.n(quantity)) you need \(Fmt.n(needed)) more."
                 : "You hold no \(contract.name) contracts. Buy complete sets (one of every team for $1.00 a set) and sell the ones you think are rich.")
                .font(Theme.body(14))
                .foregroundStyle(Theme.gold)
                .fixedSize(horizontal: false, vertical: true)
            Button("Buy \(Fmt.n(needed)) complete sets for \(Fmt.money(100 * needed))") {
                Task {
                    do { try await store.buyCompleteSets(needed); store.flash("Bought \(Fmt.n(needed)) complete sets") }
                    catch { self.error = error.marketMessage }
                }
            }
            .buttonStyle(GhostButtonStyle())
        }
    }

    // MARK: Submit

    private func submit() {
        guard !submitting else { return }
        submitting = true
        error = nil
        Task {
            defer { submitting = false }
            do {
                let receipt = try await store.placeOrder(contract: contract, side: side, price: price, quantity: quantity)
                store.flash(toast(for: receipt))
                if postToChat, let league = store.league,
                   let card = MarketMessage.snapshot(from: store, headline: "\(store.myName) \(verb(for: receipt))") {
                    let message = MarketMessage.make(
                        invite: MarketInvite(league: league),
                        card: card,
                        caption: "\(host.senderToken) \(verb(for: receipt))",
                        subcaption: "Tap to trade",
                        summary: "\(store.myName) \(verb(for: receipt))",
                        session: host.session(for: league.id))
                    host.stage(message)
                }
                dismiss()
            } catch {
                self.error = error.marketMessage
            }
        }
    }

    private func toast(for r: OrderReceipt) -> String {
        let avg = r.averagePrice.map { Fmt.cents(($0 * 10).rounded() / 10) } ?? ""
        if r.filledQuantity > 0 && r.restingQuantity > 0 {
            return "Filled \(Fmt.n(r.filledQuantity)) at \(avg), \(Fmt.n(r.restingQuantity)) resting at \(price)¢"
        }
        if r.filledQuantity > 0 { return "Filled \(Fmt.n(r.filledQuantity)) at \(avg)" }
        return "Resting \(Fmt.n(quantity)) at \(price)¢"
    }

    /// "bought 100 Max @ 27¢" / "bid 25¢ for 100 Max" / "offered 100 Max at 30¢".
    private func verb(for r: OrderReceipt) -> String {
        let team = contract.name
        let avg = r.averagePrice.map { Fmt.cents(($0 * 10).rounded() / 10) } ?? "\(price)¢"
        switch (side, r.filledQuantity > 0, r.restingQuantity > 0) {
        case (.buy, true, false): return "bought \(Fmt.n(r.filledQuantity)) \(team) @ \(avg)"
        case (.buy, true, true): return "bought \(Fmt.n(r.filledQuantity)) \(team) @ \(avg), bidding \(price)¢ for \(Fmt.n(r.restingQuantity)) more"
        case (.buy, false, _): return "bid \(price)¢ for \(Fmt.n(quantity)) \(team)"
        case (.sell, true, false): return "sold \(Fmt.n(r.filledQuantity)) \(team) @ \(avg)"
        case (.sell, true, true): return "sold \(Fmt.n(r.filledQuantity)) \(team) @ \(avg), offering \(Fmt.n(r.restingQuantity)) more at \(price)¢"
        case (.sell, false, _): return "offered \(Fmt.n(quantity)) \(team) at \(price)¢"
        }
    }
}

struct StepperField: View {
    @Binding var text: String
    let down: () -> Void
    let up: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: down) {
                Text("−").font(.system(size: 22)).frame(width: 44, height: 44)
            }
            TextField("", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(Theme.display(24, weight: .semibold))
                .frame(maxWidth: .infinity)
            Button(action: up) {
                Text("+").font(.system(size: 22)).frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(Theme.chalk)
        .background(Theme.field)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Buy N complete sets: one contract of every team for $1.00 per set.
struct CompleteSetsView: View {
    let store: MarketStore
    @Environment(\.dismiss) private var dismiss
    @State private var quantityText = "100"
    @State private var error: String?
    @State private var busy = false

    private var quantity: Int { min(1_000_000, max(1, Int(quantityText.filter(\.isNumber)) ?? 0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule().fill(Theme.line).frame(width: 40, height: 4).frame(maxWidth: .infinity)
            Text("Complete sets").font(Theme.display(28)).foregroundStyle(Theme.chalk)
            Text("A set is one contract on every team, so exactly one of them pays $1.00 at settlement. Buy sets for $1.00 each, then sell the teams you think are overpriced. That is how you go short.")
                .font(Theme.body(14)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            LabeledField(label: "Sets") {
                StepperField(text: $quantityText,
                             down: { quantityText = String(max(1, quantity - (quantity > 100 ? 100 : 10))) },
                             up: { quantityText = String(min(1_000_000, quantity + (quantity >= 100 ? 100 : 10))) })
            }
            Text("Costs \(Fmt.money(100 * quantity)) of cash.").font(Theme.body(15)).foregroundStyle(Theme.muted)
            if let error { Text(error).font(Theme.body(15)).foregroundStyle(Theme.ask) }
            Button(busy ? "Buying…" : "Buy \(Fmt.n(quantity)) sets") {
                busy = true
                error = nil
                Task {
                    defer { busy = false }
                    do {
                        try await store.buyCompleteSets(quantity)
                        store.flash("Bought \(Fmt.n(quantity)) complete sets")
                        dismiss()
                    } catch { self.error = error.marketMessage }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.turf)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Theme.turf)
    }
}
