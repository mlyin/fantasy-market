import Foundation

// Row types mirror the Supabase tables column-for-column (snake_case on purpose:
// the PostgREST decoder is not configured to convert keys).

struct League: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let commissioner_id: UUID
    let invite_code: String
    let starting_cash: Int
    let status: String            // open | closed | settled
    let winning_contract_id: UUID?

    var isSettled: Bool { status == "settled" }
    var isOpen: Bool { status == "open" }
}

struct Contract: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let league_id: UUID
    let name: String
    let ticker: String
    let status: String
    let settlement_cents: Int?
}

struct Order: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let league_id: UUID
    let contract_id: UUID
    let user_id: UUID
    let side: String              // buy | sell
    let price_cents: Int
    let quantity: Int
    let remaining: Int
    let status: String            // open | partially_filled | filled | cancelled
    let created_at: String

    var isBuy: Bool { side == "buy" }
    var isResting: Bool { status == "open" || status == "partially_filled" }
}

struct Trade: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let league_id: UUID
    let contract_id: UUID
    let buy_order_id: UUID
    let sell_order_id: UUID
    let buyer_id: UUID
    let seller_id: UUID
    let price_cents: Int
    let quantity: Int
    let created_at: String

    var createdAt: Date? { PostgresDate.parse(created_at) }
}

struct Position: Codable, Hashable, Sendable {
    let league_id: UUID
    let contract_id: UUID
    let user_id: UUID
    let quantity: Int
    let reserved_quantity: Int
    let cost_basis: Int
}

struct Membership: Codable, Hashable, Sendable {
    let league_id: UUID
    let user_id: UUID
    let cash_balance: Int
    let reserved_cash: Int

    var availableCash: Int { cash_balance - reserved_cash }
}

/// league_members embedded with its league (drawer list).
struct MembershipWithLeague: Codable, Identifiable, Hashable, Sendable {
    let league_id: UUID
    let cash_balance: Int
    let reserved_cash: Int
    let leagues: League

    var id: UUID { league_id }
}

struct Profile: Codable, Hashable, Sendable {
    let display_name: String
}

/// league_members embedded with the member's profile (standings).
struct MemberRow: Codable, Identifiable, Hashable, Sendable {
    let user_id: UUID
    let cash_balance: Int
    let reserved_cash: Int
    let profiles: Profile?

    var id: UUID { user_id }
    var name: String { profiles?.display_name ?? "Trader" }
}

struct CreateLeagueResult: Codable, Sendable {
    let league_id: UUID
    let invite_code: String
}

enum Side: String, Codable, CaseIterable, Sendable {
    case buy, sell
}

/// Aggregated top-of-book for one contract.
struct Quote: Hashable, Sendable {
    var bids: [Level] = []        // best first
    var asks: [Level] = []        // best first
    var last: Int?
    var volume: Int = 0

    struct Level: Hashable, Sendable {
        let price: Int
        let quantity: Int
        let mine: Bool
    }

    var bestBid: Int? { bids.first?.price }
    var bestAsk: Int? { asks.first?.price }

    /// Mid when both sides exist, else last trade, else 50¢ (matches the reference page).
    var mark: Double {
        if let b = bestBid, let a = bestAsk { return Double(b + a) / 2 }
        if let l = last { return Double(l) }
        return 50
    }
}

/// What happened to an order we just placed, for the toast and the chat bubble.
struct OrderReceipt: Sendable {
    let order: Order
    let filledQuantity: Int
    let averagePrice: Double?

    var restingQuantity: Int { order.remaining }
}

enum PostgresDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        // Postgres emits "+00:00"; ISO8601DateFormatter accepts that, but a bare "+00" does not parse.
        var t = s
        if t.hasSuffix("+00") { t += ":00" }
        return fractional.date(from: t) ?? plain.date(from: t)
    }
}
