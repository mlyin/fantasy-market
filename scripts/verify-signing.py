"""Fail before archiving if Codemagic did not select BOTH App Store profiles."""
import plistlib
import sys

with open(sys.argv[1], 'rb') as f:
    options = plistlib.load(f)
profiles = options.get('provisioningProfiles', {})
for bundle_id in ('com.mlyin.FantasyMarket', 'com.mlyin.FantasyMarket.MessagesExtension'):
    if not profiles.get(bundle_id):
        raise SystemExit(f'Missing App Store profile for {bundle_id}. Add it to Codemagic Code signing identities.')
if not options.get('teamID'):
    raise SystemExit('Missing signing team in export options.')
if options.get('method') not in ('app-store', 'app-store-connect'):
    raise SystemExit('Expected App Store distribution profiles.')
print('PASS: App Store export includes containing app and Messages extension profiles')
