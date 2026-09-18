"""Verify the actual archive, not just the XcodeGen input. No signing secrets needed."""
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1])
extension = app / 'PlugIns/FantasyMarketMessages.appex'
def info(bundle):
    with (bundle / 'Info.plist').open('rb') as f:
        return plistlib.load(f)

host, child = info(app), info(extension)
assert host['CFBundleIdentifier'] == 'com.mlyin.FantasyMarket'
assert child['CFBundleIdentifier'] == 'com.mlyin.FantasyMarket.MessagesExtension'
assert host['CFBundleVersion'] == child['CFBundleVersion']
assert host['CFBundleShortVersionString'] == child['CFBundleShortVersionString']
assert child['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.message-payload-provider'
assert child['NSExtension']['NSExtensionPrincipalClass'] == 'FantasyMarketMessages.MessagesViewController'
assert 'NSExtensionMainStoryboard' not in child['NSExtension']
assert (extension / child['CFBundleExecutable']).is_file()
assert (app / host['CFBundleExecutable']).is_file()
print('PASS: containing app, embedded Messages extension, identifiers, versions and principal class')
