import Foundation

@main
struct MarketModelTests {
    static func main() throws {
        let id = UUID()
        let invite = MarketInvite(leagueID: id, inviteCode: "A1B2C3D4", leagueName: "Friends & family")
        precondition(MarketInvite(url: invite.url) == invite, "Message URL round trip")
        precondition(MarketInvite(url: URL(string: "https://example.com/?league=\(id)&invite=A1B2C3D4")) == nil)
        precondition(MarketInvite(url: URL(string: "https://fantasy-market-nine.vercel.app/?league=bad&invite=A1B2C3D4")) == nil)
        precondition(MarketInvite(url: URL(string: "https://fantasy-market-nine.vercel.app/?league=\(id)&invite=")) == nil)
        precondition(MarketValuation.equity(cash: 1_000_180, positionValue: 300, settled: true) == 1_000_180,
                     "Settled positions have already paid into cash")
        precondition(MarketValuation.equity(cash: 999_880, positionValue: 120, settled: false) == 1_000_000)
        var quote = Quote()
        precondition(quote.mark == 50)
        quote.last = 37
        precondition(quote.mark == 37)
        quote.bids = [.init(price: 40, quantity: 2, mine: false)]
        quote.asks = [.init(price: 51, quantity: 3, mine: true)]
        precondition(quote.mark == 45.5)
        precondition(PostgresDate.parse("2026-09-18T02:00:00.123456+00:00") != nil)
        print("PASS: message links, settled equity, quotes and Postgres dates")
    }
}
