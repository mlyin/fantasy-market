# Fantasy Market

Mobile-first play-money prediction exchange for a private fantasy league.

## Stack
Next.js + Supabase Postgres/Auth/Realtime. The matching engine runs transactionally in Postgres RPCs.

## Run
```bash
npm install
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
