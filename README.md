# Fantasy Market

Play-money prediction exchange for a private fantasy league, primarily operated
through a native iMessage Messages extension. Friends trade team-winner contracts
inside the conversation and share market/trade cards.

## Stack
Native Swift/SwiftUI Messages extension + Next.js/Vercel companion + Supabase
Postgres/Auth. The matching engine runs in Postgres RPCs. XcodeGen generates the
iOS project; Codemagic handles signed iOS builds and TestFlight.

See [iOS build, Mac setup and remaining Apple actions](ios/README.md).

## Run
```bash
npm ci
npm run dev
```

The checked-in Supabase URL and publishable key are intentionally client-safe. Never commit service-role keys.

## v1
- anonymous quick entry
- create/join private leagues with invite codes
- $10,000 play-money starting balance
- mutually exclusive winner contracts
- limit order book with price-time priority
- realtime order/trade refresh
- settlement RPC

Play money only; no deposits, withdrawals, or real-money payouts.
