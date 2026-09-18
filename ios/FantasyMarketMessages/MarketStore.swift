import Foundation
import Observation
import Supabase

/// All market state for the extension: anonymous auth, the leagues you belong to,
/// and the live book for the league that is open. Mirrors what the reference
/// League Market page computes client-side (marks, equity, standings).
@MainActor
@Observable
final class MarketStore {
    // MARK: Auth
    private(set) var userID: UUID?
    /// True on first launch until the trader picks a display name (it is stored in
    /// the anonymous user's metadata, which the `handle_new_user` trigger copies to profiles).
    private(set) var needsName = false
    private(set) var isBootstrapped = false

    // MARK: Data
    private(set) var memberships: [MembershipWithLeague] = []
    private(set) var league: League?
    private(set) var contracts: [Contract] = []
    private(set) var openOrders: [Order] = []     // every resting order in the league
    private(set) var trades: [Trade] = []         // newest first
    private(set) var positions: [Position] = []   // everyone's, for standings
    private(set) var members: [MemberRow] = []
    private(set) var isLive = false

    var isBusy = false
    var errorMessage: String?
    var toast: String?

    private let client = Backend.client
    private var channel: RealtimeChannelV2?
    private var listeners: [Task<Void, Never>] = []
    private var refreshTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    // MARK: - Session

    func bootstrap() async {
        if isBootstrapped {
            await loadMyLeagues()
            if league != nil { await refresh() }
            return
        }
        do {
            let session = try await client.auth.session
            userID = session.user.id
            isBootstrapped = true
            needsName = false
            await loadMyLeagues()
        } catch {
            needsName = true
        }
    }

    func signIn(displayName: String) async {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "Pick a name first."; return }
        isBusy = true
        defer { isBusy = false }
        do {
            let session = try await client.auth.signInAnonymously(data: ["display_name": .string(name)])
            userID = session.user.id
            needsName = false
            isBootstrapped = true
            await loadMyLeagues()
        } catch {
            errorMessage = error.marketMessage
        }
    }

    // MARK: - Leagues

    func loadMyLeagues() async {
        guard let uid = userID else { return }
        do {
            let rows: [MembershipWithLeague] = try await client
                .from("league_members")
                .select("league_id, cash_balance, reserved_cash, leagues(id, name, commissioner_id, invite_code, starting_cash, status, winning_contract_id)")
                .eq("user_id", value: uid.uuidString)
                .order("joined_at", ascending: false)
                .execute()
                .value
            memberships = rows
        } catch {
            errorMessage = error.marketMessage
        }
    }

    @discardableResult
    func createLeague(name: String, teams: [String]) async throws -> League {
        struct Params: Encodable { let p_name: String; let p_teams: [String] }
        let cleaned = teams.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard cleaned.count >= 2 else { throw MarketError.message("Add at least two teams.") }
        let result: CreateLeagueResult = try await client
            .rpc("create_demo_league", params: Params(p_name: name, p_teams: cleaned))
            .execute()
            .value
        await loadMyLeagues()
        return try await open(leagueID: result.league_id)
    }

    @discardableResult
    func join(code: String) async throws -> League {
        struct Params: Encodable { let p_invite_code: String }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { throw MarketError.invalidInvite }
        let membership: Membership = try await client
            .rpc("join_league", params: Params(p_invite_code: trimmed))
            .execute()
            .value
        await loadMyLeagues()
        return try await open(leagueID: membership.league_id)
    }

    /// Select a league, load its book and start listening for changes.
    @discardableResult
    func open(leagueID: UUID) async throws -> League {
        let l: League = try await client
            .from("leagues")
            .select()
            .eq("id", value: leagueID.uuidString)
            .single()
            .execute()
            .value
        league = l
        contracts = []; openOrders = []; trades = []; positions = []; members = []
        await refresh()
        await subscribe(to: l.id)
        return l
    }

    func closeLeague() {
        league = nil
        contracts = []; openOrders = []; trades = []; positions = []; members = []
        Task { await unsubscribe() }
    }

    // MARK: - Book

    func refresh() async {
        guard let current = league else { return }
        let lid = current.id.uuidString
        do {
            let fresh: League = try await client.from("leagues").select().eq("id", value: lid).single().execute().value
            let cs: [Contract] = try await client.from("contracts").select().eq("league_id", value: lid).order("created_at").execute().value
            let os: [Order] = try await client.from("orders").select().eq("league_id", value: lid)
                .in("status", values: ["open", "partially_filled"]).execute().value
            let ts: [Trade] = try await client.from("trades").select().eq("league_id", value: lid)
                .order("created_at", ascending: false).limit(60).execute().value
            let ps: [Position] = try await client.from("positions").select().eq("league_id", value: lid).execute().value
            let ms: [MemberRow] = try await client.from("league_members")
                .select("user_id, cash_balance, reserved_cash, profiles(display_name)")
                .eq("league_id", value: lid).execute().value
            guard league?.id == current.id else { return }   // user switched leagues mid-flight
            league = fresh; contracts = cs; openOrders = os; trades = ts; positions = ps; members = ms
        } catch {
            errorMessage = error.marketMessage
        }
    }

    func placeOrder(contract: Contract, side: Side, price: Int, quantity: Int) async throws -> OrderReceipt {
        struct Params: Encodable { let p_contract: UUID; let p_side: String; let p_price: Int; let p_quantity: Int }
        guard (1...99).contains(price), quantity > 0 else { throw MarketError.message("Price must be 1–99¢ and size at least 1.") }
        let orderID: UUID = try await client
            .rpc("place_order", params: Params(p_contract: contract.id, p_side: side.rawValue, p_price: price, p_quantity: quantity))
            .execute()
            .value
        let order: Order = try await client.from("orders").select().eq("id", value: orderID.uuidString).single().execute().value
        let fills: [Trade] = try await client.from("trades").select()
            .or("buy_order_id.eq.\(orderID.uuidString),sell_order_id.eq.\(orderID.uuidString)")
            .execute().value
        let filled = fills.reduce(0) { $0 + $1.quantity }
        let notional = fills.reduce(0) { $0 + $1.quantity * $1.price_cents }
        await refresh()
        return OrderReceipt(order: order, filledQuantity: filled,
                            averagePrice: filled > 0 ? Double(notional) / Double(filled) : nil)
    }

    func cancel(order: Order) async throws {
        struct Params: Encodable { let p_order: UUID }
        _ = try await client.rpc("cancel_order", params: Params(p_order: order.id)).execute()
        await refresh()
    }

    /// Buy one of every contract for $1.00 a set. That is how you get inventory to sell
    /// a team short (the set always pays out exactly $1.00 at settlement).
    func buyCompleteSets(_ quantity: Int) async throws {
        struct Params: Encodable { let p_league: UUID; let p_quantity: Int }
        guard let league else { throw MarketError.message("Open a market first.") }
        _ = try await client.rpc("seed_complete_set", params: Params(p_league: league.id, p_quantity: quantity)).execute()
        await refresh()
    }

    /// Commissioner only: pay out the winner and close every order.
    func settle(winner: Contract) async throws {
        struct Params: Encodable { let p_league: UUID; let p_winner: UUID }
        guard let league else { return }
        _ = try await client.rpc("settle_league", params: Params(p_league: league.id, p_winner: winner.id)).execute()
        await refresh()
        await loadMyLeagues()
    }

    // MARK: - Derived

    var isCommissioner: Bool { league.map { $0.commissioner_id == userID } ?? false }

    var me: Membership? {
        guard let league, let uid = userID, let row = members.first(where: { $0.user_id == uid }) else { return nil }
        return Membership(league_id: league.id, user_id: uid, cash_balance: row.cash_balance, reserved_cash: row.reserved_cash)
    }

    var myName: String {
        members.first(where: { $0.user_id == userID })?.name ?? "You"
    }

    var myPositions: [Position] { positions.filter { $0.user_id == userID && $0.quantity != 0 } }

    var myOpenOrders: [Order] { openOrders.filter { $0.user_id == userID } }

    func quote(for contract: Contract) -> Quote {
        var q = Quote()
        let book = openOrders.filter { $0.contract_id == contract.id && $0.remaining > 0 }
        func levels(_ side: String, bestIsHigh: Bool) -> [Quote.Level] {
            Dictionary(grouping: book.filter { $0.side == side }, by: { $0.price_cents })
                .map { price, orders in
                    Quote.Level(price: price,
                                quantity: orders.reduce(0) { $0 + $1.remaining },
                                mine: orders.contains { $0.user_id == userID })
                }
                .sorted { bestIsHigh ? $0.price > $1.price : $0.price < $1.price }
        }
        q.bids = levels("buy", bestIsHigh: true)
        q.asks = levels("sell", bestIsHigh: false)
        let prints = trades.filter { $0.contract_id == contract.id }
        q.last = prints.first?.price_cents
        q.volume = prints.reduce(0) { $0 + $1.quantity }
        return q
    }

    /// Mark in cents: settlement value once settled, otherwise the quote mark.
    func mark(for contract: Contract) -> Double {
        if let league, league.isSettled {
            return league.winning_contract_id == contract.id ? 100 : 0
        }
        return quote(for: contract).mark
    }

    func position(for contract: Contract) -> Position? {
        positions.first { $0.contract_id == contract.id && $0.user_id == userID }
    }

    func contract(id: UUID) -> Contract? { contracts.first { $0.id == id } }

    /// Cash plus positions at the mark, in cents.
    func equity(of userID: UUID) -> Int {
        guard let row = members.first(where: { $0.user_id == userID }) else { return 0 }
        let held = positions.filter { $0.user_id == userID }.reduce(0.0) { sum, p in
            guard let c = contract(id: p.contract_id) else { return sum }
            return sum + Double(p.quantity) * mark(for: c)
        }
        return row.cash_balance + Int(held.rounded())
    }

    var myEquity: Int { userID.map(equity(of:)) ?? 0 }

    /// Members ranked by equity, best first.
    var standings: [(member: MemberRow, equity: Int)] {
        members.map { ($0, equity(of: $0.user_id)) }.sorted { $0.1 > $1.1 }
    }

    func name(of userID: UUID) -> String {
        members.first(where: { $0.user_id == userID })?.name ?? "Trader"
    }

    // MARK: - Realtime

    private func subscribe(to leagueID: UUID) async {
        await unsubscribe()
        let ch = client.channel("league-\(leagueID.uuidString.lowercased())")
        let orderStream = ch.postgresChange(AnyAction.self, schema: "public", table: "orders")
        let tradeStream = ch.postgresChange(AnyAction.self, schema: "public", table: "trades")
        await ch.subscribe()
        channel = ch
        isLive = true
        listeners = [
            Task { [weak self] in
                for await _ in orderStream { await self?.scheduleRefresh() }
            },
            Task { [weak self] in
                for await _ in tradeStream { await self?.scheduleRefresh() }
            },
        ]
    }

    private func unsubscribe() async {
        listeners.forEach { $0.cancel() }
        listeners = []
        if let ch = channel {
            await client.removeChannel(ch)
        }
        channel = nil
        isLive = false
    }

    /// Coalesce bursts of change events into one reload.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: - UI helpers

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func clearError() { errorMessage = nil }
}
