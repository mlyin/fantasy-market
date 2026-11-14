#!/bin/bash
# Prepares the Chess Lens iPhone app on a Mac and opens it in Xcode, ready to run on your phone.
# These are the same steps the GitHub build runs. Usage, from anywhere:
#
#   bash chess-lens/ios/open-in-xcode.sh
#
# Then in Xcode: pick your Apple ID team under Signing & Capabilities, choose your iPhone as the
# run destination, and press Run.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodebuild >/dev/null; then
  echo "Xcode is not installed. Install it from the App Store, open it once, then run this again."
  exit 1
fi
VERSION=$(xcodebuild -version | awk '/^Xcode/ {print $2}')
MAJOR=${VERSION%%.*}
REST=${VERSION#*.}
MINOR=${REST%%.*}
if [ "$MAJOR" -lt 26 ] || { [ "$MAJOR" -eq 26 ] && [ "${MINOR:-0}" -lt 4 ]; }; then
  echo "Xcode $VERSION is too old: Meta's glasses SDK needs Xcode 26.4 or newer. Update Xcode and run this again."
  exit 1
fi
for tool in node npm brew; do
  if ! command -v "$tool" >/dev/null; then
    echo "$tool is not installed. Install Homebrew (https://brew.sh), then: brew install node"
    exit 1
  fi
done

echo "Bundling the real-board reader into the app…"
npm ci
npm run vendor:offline

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate --spec ios/project.yml
open ios/ChessLens.xcodeproj
echo
echo "Xcode is opening. Select the ChessLens target > Signing & Capabilities > choose your team,"
echo "plug in your iPhone, choose it at the top of the window, and press Run."
