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

After replacing a development build, fully close Messages from the iPhone app
switcher and reopen it before testing the extension. On the test iPhone, leaving
Messages open across a reinstall produced an empty gray drawer with no running
extension process; restarting Messages restored the app without another install.
If the drawer is blank, restart Messages first, then open **+ → Fantasy Market**.
Do not delete the app as a troubleshooting step: anonymous identity recovery is
not implemented.

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
league as different users. Cross-device recovery/linking is not implemented. The beta onboarding explains that each person should keep using the same iPhone.

Manual checks still needed on a Mac/iPhone:

- Tap Continue, import a standings screenshot, review every team/manager pair, and open a market.
- Choose your own team, then stage an invite into a conversation. New roster leagues require a team claim before trading.
- Tap the card on a second device/account; confirm the same market opens inside
  Messages. Simulator participants may share an installation's anonymous session,
  so use a second device for genuine two-user trading.
- Buy sets, sell, partially fill from the other account, cancel the remainder,
  and send a result card.
- Collapse/reopen, switch conversations, select old cards, and test offline recovery.
- Settle a disposable league and verify final equity equals paid cash.
- Check small iPhones, iPad, keyboard, VoiceOver and card layout.

## Backend review

The roster migration in `supabase/migrations/20260918033028_roster_identity.sql` adds manager names and exclusive per-league team claims. Apply it to an existing market backend before running the updated clients. Public RPCs use invoker wrappers; private functions validate membership and serialize claims. Existing leagues without a roster remain compatible. The rollback-only [integration check](../scripts/backend-contract-smoke.sql)
passed: private access, idempotent join, reservations, maker-price partial fills,
cancellation, commissioner authorization and settlement. All test rows rolled back.

Important existing assumptions/limits:

- Settlement retains historical positions after crediting cash; settled equity
  must not include their value again. The native client accounts for this.
- Complete sets cost 100 cents and issue one of each open contract. Selling is a
  funded inventory sale, not an unfunded short or future payment obligation.
- Migration `20260918035611_serialize_market_mutations.sql` locks the league row
  before every trade, cancellation, set purchase, contract addition and settlement.
  Matching waits for the current transaction instead of skipping locked makers.
  Closed leagues reject trades/sets, settlement pays once, and teams cannot be
  added after a roster is imported or trading begins. The privileged bodies live
  in `market_private`, behind authenticated invoker RPCs.
- The per-league lock favors correctness for a small friends beta. Throughput under
  large traffic has not been benchmarked.
- Cost basis is not reduced on sells; it is not accurate realized P&L. The native
  client uses holdings/cash for equity. Tape volume covers the last 60 trades.
- Multi-request REST reads are not an atomic snapshot. Cards can be stale.
- Network failures around non-idempotent mutations require checking orders and
  balances before retrying. Do not automatically retry order/create/set RPCs.

The live concurrency check passed 12 simultaneous orders plus three rounds of
trades, set purchases and cancellations racing settlement, verifying cash
conservation and reservations. This is bounded beta coverage, not an exhaustive
proof of concurrency correctness. Run `scripts/backend-beta-guards.sql` for
rollback-only lifecycle and permission checks. `scripts/test-market-concurrency.py`
is an opt-in live test requiring `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`; it
creates disposable accounts/leagues and prints exact IDs for administrator cleanup.
Do not run it unattended against a backend without authorization.

## Screenshot roster and identity

In Messages, choose **New market → Import standings screenshot**. Apple's Vision OCR reads the selected image locally; the screenshot is never uploaded. The importer currently recognizes standings layouts with a record column and a team/manager pair on each row, including ESPN. Other layouts can be entered manually. Review all rows and the team count before opening. Truncated team names are flagged and stay editable; hidden text is never guessed.

Each participant joins through the invite, then picks their manager/team. A team can be claimed once and each account can claim one team per league. Claims are idempotent and persist across reopening. The database blocks orders and complete sets until a claim is made. Claims are self-selected, not verified against ESPN accounts. Changing a claim or recovering it after reinstall is not implemented. Web and native still have separate anonymous sessions: choose one client per person for now.

The companion web client supports typed rosters and team selection; screenshot import is native only. Website source changes require deployment separately.

Regression checks:

```sh
swiftc ios/FantasyMarketMessages/RosterImport.swift scripts/test-roster-import.swift -o build/roster-import-tests
build/roster-import-tests
# Optional: pass an ESPN screenshot containing 10 teams and 3 truncated names.
```

Run `scripts/backend-roster-smoke.sql` through an administrator database connection. It exercises validation, private visibility, duplicate and cross-member claims, trade gating, matching and settlement inside a rolled-back transaction. The existing `backend-contract-smoke.sql` covers backward compatibility.

When running the simulator interactively, allow ad-hoc signing (`CODE_SIGN_IDENTITY=-`) so Keychain sessions persist. `CODE_SIGNING_ALLOWED=NO` remains appropriate for build-only CI checks.

## Release beta validation

Both bundles read `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`; never hardcode
the Messages extension version in its plist. The archive verifier checks that the
versions match. The app uses standard HTTPS and declares no non-exempt encryption.
Build 2 was archived in Release and exported with `method=app-store-connect`.
Local signing selections and export artifacts stay in ignored paths.
