# Fantasy Market for iMessage

This folder contains the native Messages extension client. It uses Apple's Messages framework and shares the existing Supabase-backed market.

## Xcode setup
1. Create an iOS app named FantasyMarket.
2. Add Target -> iMessage Extension named FantasyMarketMessages.
3. Replace the generated controller and extension Info.plist with these files.
4. Set your Apple Development Team and unique bundle IDs.
5. Run the Messages extension target. In Messages open + -> More -> Fantasy Market.
6. For friends, archive and distribute through TestFlight/App Store.

The extension sends an interactive MSMessage into the conversation. Tapping it opens the live market. Apple requires an Xcode-signed app/TestFlight/App Store build; the Vercel site alone cannot install an iMessage extension.
