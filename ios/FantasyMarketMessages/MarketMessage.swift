import Foundation
import Messages
import SwiftUI
import UIKit

/// The card drawn into the bubble, GamePigeon style: a snapshot of the board.
struct MarketCard: View {
    struct Row: Hashable, Sendable {
        let team: String
        let bid: Int?
        let ask: Int?
        let mark: Double
    }

    struct Snapshot: Hashable, Sendable {
        let leagueName: String
        let inviteCode: String
        let headline: String
        let rows: [Row]
        let hiddenTeams: Int
        let winner: String?
    }

    let snapshot: Snapshot

    static let size = CGSize(width: 300, height: 270)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.leagueName)
                    .font(Theme.display(22))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("FM")
                    .font(Theme.display(13))
                    .foregroundStyle(Theme.gold)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Theme.turf2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.bottom, 6)

            if let winner = snapshot.winner {
                Text("\(winner) won. Contracts have paid out.")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.gold)
                    .padding(.vertical, 4)
            } else {
                HStack {
                    Text("Team").frame(maxWidth: .infinity, alignment: .leading)
                    Text("bid / ask").frame(width: 84, alignment: .trailing)
                    Text("mark").frame(width: 48, alignment: .trailing)
                }
                .font(Theme.body(10))
                .foregroundStyle(Theme.muted)
                Divider().overlay(Theme.line)
            }

            ForEach(snapshot.rows, id: \.self) { row in
                HStack {
                    Text(row.team)
                        .font(Theme.display(16, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 3) {
                        Text(row.bid.map(String.init) ?? "–").foregroundStyle(Theme.bid)
                        Text("/").foregroundStyle(Theme.muted)
                        Text(row.ask.map(String.init) ?? "–").foregroundStyle(Theme.ask)
                    }
                    .font(Theme.display(16, weight: .semibold))
                    .frame(width: 84, alignment: .trailing)
                    Text(Fmt.cents(row.mark))
                        .font(Theme.display(14, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 48, alignment: .trailing)
                }
                .padding(.vertical, 3)
                Divider().overlay(Theme.line)
            }

            if snapshot.hiddenTeams > 0 {
                Text("+\(snapshot.hiddenTeams) more teams")
                    .font(Theme.body(10))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 3)
            }

            Spacer(minLength: 0)

            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.headline)
                    .font(Theme.body(12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Invite \(snapshot.inviteCode)")
                    .font(Theme.display(13, weight: .semibold))
                    .foregroundStyle(Theme.gold)
            }
        }
        .foregroundStyle(Theme.chalk)
        .padding(14)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .background(
            LinearGradient(colors: [Theme.turf2, Theme.field], startPoint: .top, endPoint: .bottom)
        )
    }

    @MainActor
    static func render(_ snapshot: Snapshot) -> UIImage? {
        let renderer = ImageRenderer(content: MarketCard(snapshot: snapshot))
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.uiImage
    }
}

enum MarketMessage {
    /// Snapshot the top of the board for the card: favourites first, at most five rows.
    @MainActor
    static func snapshot(from store: MarketStore, headline: String) -> MarketCard.Snapshot? {
        guard let league = store.league else { return nil }
        let ranked = store.contracts
            .map { c -> (Contract, Quote) in (c, store.quote(for: c)) }
            .sorted { store.mark(for: $0.0) > store.mark(for: $1.0) }
        let shown = ranked.prefix(league.isSettled ? 3 : 5)
        let rows = shown.map { contract, quote in
            MarketCard.Row(team: contract.name, bid: quote.bestBid, ask: quote.bestAsk, mark: store.mark(for: contract))
        }
        let winner = league.winning_contract_id.flatMap { store.contract(id: $0)?.name }
        return MarketCard.Snapshot(leagueName: league.name,
                                   inviteCode: league.invite_code,
                                   headline: headline,
                                   rows: rows,
                                   hiddenTeams: max(0, ranked.count - shown.count),
                                   winner: winner)
    }

    /// Build the bubble. `caption` may contain `$<participant uuid>` tokens, which Messages
    /// renders as the participant's name (that is how the sender is named without a login).
    @MainActor
    static func make(invite: MarketInvite,
                     card: MarketCard.Snapshot,
                     caption: String,
                     subcaption: String? = nil,
                     summary: String,
                     session: MSSession?) -> MSMessage {
        let message = MSMessage(session: session ?? MSSession())
        let layout = MSMessageTemplateLayout()
        layout.image = MarketCard.render(card)
        layout.caption = caption
        layout.subcaption = subcaption
        message.layout = layout
        message.url = invite.url
        message.summaryText = summary
        return message
    }
}
