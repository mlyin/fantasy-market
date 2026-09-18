# Fantasy Market iMessage client

The iOS project is generated from project.yml using XcodeGen so it can be built from a cloud Mac without checking a machine-generated .xcodeproj into source control.

Targets:
- FantasyMarket: containing iOS app (landing screen that points people to Messages)
- FantasyMarketMessages: Messages extension, the actual trading app (Swift + SwiftUI)

Codemagic installs XcodeGen, generates FantasyMarket.xcodeproj, applies signing profiles, archives, and uploads to TestFlight (see codemagic.yaml at the repo root).

Bundle IDs:
- com.mlyin.FantasyMarket
- com.mlyin.FantasyMarket.MessagesExtension

## Build it locally

```bash
brew install xcodegen
cd ios && xcodegen generate && open FantasyMarket.xcodeproj
```

Xcode resolves the one package, [supabase-swift](https://github.com/supabase/supabase-swift) 2.x,
on first open. Run the `FantasyMarket` scheme on an iPhone simulator: Xcode launches Messages
with the extension installed. Open a conversation, tap the app drawer, pick **Fantasy Market**.
To test the bubble round trip use the two-person conversation the simulator provides: send a
bubble as one person, switch to the other, tap it. On a device pick a team under
*Signing & Capabilities* for both targets.

The extension code was written without Xcode at hand (Linux container). It parses cleanly,
but expect a few compiler complaints on the first build, most likely in the supabase-swift
calls in `MarketStore.swift`.

## How the extension works

**Sign in.** First launch asks for a name, then signs in anonymously
(`auth.signInAnonymously` with `display_name` metadata, which the `handle_new_user`
trigger copies into `profiles`). The session lives in the extension's Keychain. There is
no update policy on `profiles`, so the name is set once at sign-in.

**Compact drawer** (`DrawerView`): tiles for the leagues you belong to, plus *New market*
and *Join*. Tapping any of them expands the extension.

**Board** (`BoardView`): the reference League Market layout. Header with equity and cash,
a row per team with a *bid / ask* cell and the mark underneath, then your open orders,
positions, standings and the tape. Pull to refresh; while a league is open the store also
re-fetches the book every 8 seconds (`MarketStore.subscribe`). Supabase Realtime can
replace the poll once a Mac build pins the SDK version.

**Order ticket** (`OrderTicketView`): book ladder, buy/sell, price and size steppers with
"lift the ask / join the bid / improve" chips, a plain-English preview, and a *Post the
result in the chat* toggle. Selling more than you hold offers to buy complete sets
(`seed_complete_set`), which is how you go short.

**Bubbles** (`MarketMessage`, `MarketCard`): every bubble carries a card rendered from the
board (SwiftUI `ImageRenderer`) and a URL into the web app,
`https://fantasy-market-nine.vercel.app/?source=imessage&league=…&invite=…`, the same
query keys `MarketLink` uses, so someone without the iMessage app still gets a working
link. Captions use Messages' `$<participant-uuid>` substitution so they read
"Max bought 100 Karthik @ 27¢" without the app knowing anyone's name. When you tap an
existing bubble the new one reuses its `MSSession`, so Messages moves and updates that
bubble instead of stacking a new one, like GamePigeon's "your turn" bubble.
`MSConversation.insert` only stages the message; the sender still taps send.

**Tapping a bubble** (`RootView.handleInvite`): calls `join_league` with the code in the
URL (idempotent) and opens that board.

## Backend contract

Tables `leagues`, `contracts`, `league_members`, `orders`, `trades`, `positions`,
`profiles`; RPCs `create_demo_league`, `join_league`, `place_order`, `cancel_order`,
`seed_complete_set`, `settle_league`. Money is integer cents, prices are 1–99¢, a contract
pays 100¢. Row types in `Models.swift` use the column names verbatim. The URL and
publishable key in `Backend.swift` are the same client-safe values as `lib/supabase.ts`.

Not in the backend yet, so not in the app: 2nd and 3rd place contracts (the schema has one
"wins the league" contract per team and `settle_league` takes a single winner).
