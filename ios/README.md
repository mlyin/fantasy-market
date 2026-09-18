# Fantasy Market iMessage client

The iOS project is generated from project.yml using XcodeGen so it can be built from a cloud Mac without checking a machine-generated .xcodeproj into source control.

Targets:
- FantasyMarket: containing iOS app
- FantasyMarketMessages: Messages extension

Codemagic installs XcodeGen, generates FantasyMarket.xcodeproj, applies signing profiles, archives, and uploads to TestFlight.

Bundle IDs:
- com.mlyin.FantasyMarket
- com.mlyin.FantasyMarket.MessagesExtension
