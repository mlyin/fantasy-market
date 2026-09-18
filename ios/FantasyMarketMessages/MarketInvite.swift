import Foundation

/// What a bubble carries in its URL so tapping it opens the right market. The URL is the
/// web app with the same `league` / `invite` query keys as `MarketLink`, so people without
/// the iMessage app still land somewhere useful when they tap.
struct MarketInvite: Hashable, Identifiable, Sendable {
    static let webBase = URL(string: "https://fantasy-market-nine.vercel.app")!

    let leagueID: UUID
    let inviteCode: String
    let leagueName: String

    var id: String { leagueID.uuidString }

    init(leagueID: UUID, inviteCode: String, leagueName: String) {
        self.leagueID = leagueID
        self.inviteCode = inviteCode
        self.leagueName = leagueName
    }

    init(league: League) {
        self.init(leagueID: league.id, inviteCode: league.invite_code, leagueName: league.name)
    }

    init?(url: URL?) {
        guard let url, url.scheme == "https", url.host == Self.webBase.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                               uniquingKeysWith: { first, _ in first })
        guard let rawID = query["league"] ?? query["id"],
              let id = UUID(uuidString: rawID),
              let code = query["invite"] ?? query["code"],
              code.count == 8, code.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        self.init(leagueID: id, inviteCode: code, leagueName: query["name"] ?? "Fantasy Market")
    }

    var url: URL {
        var components = URLComponents(url: Self.webBase, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "source", value: "imessage"),
            URLQueryItem(name: "league", value: leagueID.uuidString),
            URLQueryItem(name: "invite", value: inviteCode),
            URLQueryItem(name: "name", value: leagueName),
        ]
        return components.url!
    }
}

