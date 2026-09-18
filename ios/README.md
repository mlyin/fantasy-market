# Fantasy Market in Messages

The primary client is a native SwiftUI Messages extension. Create/join a league,
read its book, place/cancel limit orders, buy complete sets, see standings, and
settle as commissioner without opening a browser. Supabase holds canonical state;
message cards are snapshots and invites, never balance or order authority.
Play money only. No deposits, withdrawals, prizes, or real-money payouts.

## Mac setup

Xcode requires macOS; it cannot run on Windows. Install Xcode, open it once to
accept its license and install an iOS simulator. With Homebrew installed, run:

```sh
git pull --ff-only
brew install xcodegen
xcodegen generate --spec ios/project.yml
open ios/FantasyMarket.xcodeproj
```

Select **FantasyMarket** and an iPhone simulator, then Run. This scheme launches
the containing app, not Messages. Open **Messages** in the simulator, open a
conversation, then **+ → More → Fantasy Market** (placement varies by iOS version).
For an iPhone, select the same Apple development team for both targets, connect
the phone, enable Developer Mode if requested, and Run.

| Target | Bundle identifier |
| --- | --- |
| FantasyMarket (containing app) | com.mlyin.FantasyMarket |
| FantasyMarketMessages (extension) | com.mlyin.FantasyMarket.MessagesExtension |

Minimum iOS is 17. The extension is embedded as `app-extension.messages`, with
`APPLICATION_EXTENSION_API_ONLY=YES` and `SKIP_INSTALL=YES`. XcodeGen writes
`com.apple.message-payload-provider` and principal class
`FantasyMarketMessages.MessagesViewController` from `info.properties`.

The generated project is ignored. Edit `project.yml` instead. Generation restores
`ios/Package.resolved`, pinning supabase-swift 2.55.2 and the transitive revisions
from the successful cloud build. Deliberate package upgrades must copy the new
workspace lockfile back to `ios/Package.resolved` and rerun both builds below.

## Build checks

GitHub Actions runs XcodeGen, model/link regression checks, a simulator build, an
unsigned Release device archive, and inspection of the actual embedded extension.
Logs and the archive are artifacts. An unsigned archive cannot install on an
iPhone or upload to TestFlight.

```sh
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/FantasyMarket.xcodeproj -scheme FantasyMarket \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/simulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios/FantasyMarket.xcodeproj -scheme FantasyMarket \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/FantasyMarket.xcarchive CODE_SIGNING_ALLOWED=NO archive
python3 scripts/verify-ios-bundle.py build/FantasyMarket.xcarchive/Products/Applications/FantasyMarket.app
```

The successful builds use Swift 5 language mode. The pinned SDK still produces
PostgREST Sendable warnings (including with `@preconcurrency import Supabase`).
MarketStore and Messages interaction run on the main actor. Revalidate the SDK
before enabling Swift 6 strict mode; those warnings would become errors.

## Apple/Codemagic actions still required

`fantasy-market-ios-unsigned` needs no Apple credentials. The signed workflow,
`fantasy-market-ios`, archives and submits to TestFlight. Before running it:

1. Enroll in Apple Developer; register both explicit bundle IDs above under your
   team. Create the App Store Connect app for the containing ID.
2. Add the App Store Connect API integration named **codemagic** in Codemagic Team
   integrations (or change the YAML name to match your existing integration).
3. Add an Apple Distribution certificate with its private key and App Store
   profiles for **both IDs**, from the same team/certificate, to Codemagic Code
   signing identities. Containing-ID matching also selects extension profiles;
   `verify-signing.py` fails early if either profile is missing.
4. Run the signed workflow for the tested commit. Both targets use Codemagic's
   project build counter. Raise the counter if Apple already has a higher build.
5. Complete Apple agreements, export-compliance answers and TestFlight tester
   setup. External testers may need Apple's beta review.

Keep `.p8`, `.p12`, certificates, keys and profiles in Apple/Codemagic secure
settings, never Git or chat. No App Groups/Keychain sharing is needed: the host
has no user session and the extension owns its Keychain session.

## Messages behavior and manual acceptance

The compact drawer expands into the board. The book polls while active, refreshes
after mutations/received cards, and stops polling when inactive. The live dot
means the latest fetch succeeded, not a server push subscription.

Cards carry an HTTPS league/invite URL and rendered snapshot. Selecting one joins
through the server RPC and fetches the board. Sharing reuses the selected card's
MSSession only for the same league. `MSConversation.insert` stages the card; the
person taps Send. Insertion errors do not undo already-saved market changes.
The web companion also handles the invite URL.

Anonymous identity is per installation/session: web and native may join the same
league as different users. Cross-device recovery/linking is not implemented.

Manual checks still needed on a Mac/iPhone:

- Enter a name, create two teams, and send an invite into a conversation.
- Tap the card on a second device/account; confirm the same market opens inside
  Messages. Simulator participants may share an installation's anonymous session,
  so use a second device for genuine two-user trading.
- Buy sets, sell, partially fill from the other account, cancel the remainder,
  and send a result card.
- Collapse/reopen, switch conversations, select old cards, and test offline recovery.
- Settle a disposable league and verify final equity equals paid cash.
- Check small iPhones, iPad, keyboard, VoiceOver and card layout.

## Backend review

The live schema, RPCs and RLS were inspected. No backend interfaces/migrations
changed. The rollback-only [integration check](../scripts/backend-contract-smoke.sql)
passed: private access, idempotent join, reservations, maker-price partial fills,
cancellation, commissioner authorization and settlement. All test rows rolled back.

Important existing assumptions/limits:

- Settlement retains historical positions after crediting cash; settled equity
  must not include their value again. The native client accounts for this.
- Complete sets cost 100 cents and issue one of each open contract. Selling is a
  funded inventory sale, not an unfunded short or future payment obligation.
- SKIP LOCKED matching is not strict global price/time priority with concurrent
  writers. Order/settlement races need concurrency tests and a shared lock strategy.
- The backend permits adding contracts after sets exist, and checks contract
  status rather than league closed status during orders. The native UI creates
  all teams initially and allows trading only in open leagues; server hardening
  is still needed before adding those features to other clients.
- Cost basis is not reduced on sells; it is not accurate realized P&L. The native
  client uses holdings/cash for equity. Tape volume covers the last 60 trades.
- Multi-request REST reads are not an atomic snapshot. Cards can be stale.
- Network failures around non-idempotent mutations require checking orders and
  balances before retrying. Do not automatically retry order/create/set RPCs.

The sequential smoke test does not certify concurrency correctness or production
readiness of the existing matching engine.
