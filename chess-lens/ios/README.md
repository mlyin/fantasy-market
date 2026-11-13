# Chess Lens for iOS

A thin native shell around the shared web core in `chess-lens/web`. The web app does all
the recognition; this app only moves pixels and drives the glasses:

- hosts the web app in a full-screen `WKWebView`, served from the bundle at `chesslens://app/`
- connects to Meta glasses through the Meta Wearables Device Access Toolkit (DAT) 1.0.1
- hands glasses photos to the web app, and shows the recognised board on Meta Ray-Ban Display

Nothing here has been run on a device or the simulator yet. The GitHub Actions workflow
`chess-lens-ios.yml` is the compile check; treat the first run on real glasses as a test.

## Build

Needs macOS with **Xcode 26.4 or newer** (the SDK's frameworks are built with Swift 6.3) and
XcodeGen. The Xcode project is generated and not checked in; edit `project.yml` instead.

```sh
brew install xcodegen
xcodegen generate --spec chess-lens/ios/project.yml
open chess-lens/ios/ChessLens.xcodeproj
```

Select the **ChessLens** scheme, choose your Apple development team under Signing &
Capabilities, and run. The whole `chess-lens/web` folder is copied into the app as `web/`,
so keep build tooling and tests outside that folder.

Unsigned command-line builds (what CI runs):

```sh
xcodebuild -project chess-lens/ios/ChessLens.xcodeproj -scheme ChessLens \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild -project chess-lens/ios/ChessLens.xcodeproj -scheme ChessLens \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/chess-lens/ChessLens.xcarchive CODE_SIGNING_ALLOWED=NO archive
```

## Try it without glasses

**Simulated glasses** use Meta's MockDeviceKit: a simulated Meta Ray-Ban Display pair that
is already registered and has camera permission. It is on by default in the iOS Simulator
and off on a real iPhone; the web app switches it with the `setMock` message, and the
choice is remembered.

- On an iPhone, the simulated glasses' camera is the phone's back camera (the app asks for
  camera access on first connect).
- In the Simulator there is no camera. If `chess-lens/web/samples/book-page.jpg` exists it
  is used as the photo a scan returns.
- The **lens preview** panel (`lensPreview` message) shows what the display would show.
  Its buttons are live.

## Use real glasses

1. Install the **Meta AI** app, pair the glasses, and turn on **Developer Mode**
   (Meta AI → Settings → your glasses → Developer Mode).
2. Run the app on the iPhone with your Apple team selected, with simulated glasses off.
3. Tap connect in the app. The first time, it switches to Meta AI twice: once to register
   the app, once to allow camera access. Each time, Meta AI returns to the app through the
   `chesslens-app://` URL scheme.
4. On Meta Ray-Ban Display, the lens shows a **Scan** button. Selecting it takes a photo,
   the phone recognises the position, and the lens shows the board with **Scan** and
   **Flip**. Other Meta glasses work as a camera only; trigger the scan from the phone.

**Keep the app open and on screen while scanning.** Recognition runs in the web view, which
iOS suspends in the background, so the app keeps the phone awake while a glasses session
is running.

## What needs your accounts

| Setting | Where | Needed for |
| --- | --- | --- |
| Apple development team | Xcode → Signing & Capabilities | Running on an iPhone at all |
| `META_APP_ID`, `CLIENT_TOKEN` | Build settings in `project.yml`, values from the Wearables Developer Center | Only for sharing through a release channel. Leave empty for Developer Mode |
| `TeamID` in the `MWDAT` Info.plist entry | Filled from `DEVELOPMENT_TEAM` automatically | Same as above |

The bundle identifier is `com.mlyin.ChessLens`. Meta's SDK analytics and crash reporting
are opted out in `Info.plist` (`MWDAT` → `Analytics` / `CrashReporting` → `OptOut`).

The app uses none of the capabilities the SDK's 1.0 changelog marks experimental
(Inputs, Motion, Speech, voice invocations, standalone photo capture, camera audio).

## How the pieces talk

Web → native, `window.webkit.messageHandlers.chessLens.postMessage({...})`:

| `type` | Fields | Effect |
| --- | --- | --- |
| `ready` | | Native replies with a `status` message |
| `connect` / `disconnect` | | Start or end the glasses session (registers and asks for camera permission as needed) |
| `capture` | | Take a photo with the glasses; arrives as a `photo` message |
| `scanResult` | `id, ok, fen, boardPng, summary, reason` | Result for a photo; shown on the lens |
| `position` | `fen, boardPng, summary` | Position changed on the phone; refreshes a result on the lens |
| `setMock` | `enabled` | Simulated glasses on or off |
| `lensPreview` | `visible` | Show or hide the lens preview panel (simulated glasses only) |

Native → web, `window.ChessLensNative.receive({...})`:

| `type` | Fields |
| --- | --- |
| `status` | `registration, session, camera, display, deviceName, hasDisplay, mock, error` |
| `photo` | `id, url` (`/__native/photo/<id>`), `source: 'glasses'` |
| `frame` | `url` (`/__native/frame?t=<ms>`), at most two per second while streaming |
| `command` | `name: 'flip'` when Flip is selected on the lens; the web app answers with `position` |

State strings are the SDK's case names: `registration` is `registered`, `registering`,
`available` or `unavailable`; `session` is `idle`, `starting`, `started`, `paused`,
`stopping` or `stopped`; `camera` is `stopped`, `waitingForDevice`, `starting`,
`streaming`, `paused` or `stopping`; `display` is `starting`, `started`, `stopping` or
`stopped`.

## Files

| File | Role |
| --- | --- |
| `ChessLensApp.swift` | Entry point: configures the SDK, routes Meta AI's URL callbacks |
| `GlassesController.swift` | Registration, session, camera stream, photo capture, display, simulated glasses |
| `LensCards.swift` | The cards shown on the glasses display |
| `WebBridge.swift` | The web view, the JS bridge, navigation and camera-permission policy |
| `AppSchemeHandler.swift` | Serves `web/**` and `/__native/*` to the web view |
| `MediaStore.swift` | Photos and the latest preview frame, between the SDK and the web view |
| `RootView.swift` | Web view plus the lens preview panel |
