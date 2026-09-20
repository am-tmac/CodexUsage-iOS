from pathlib import Path
import plistlib, json
root = Path(__file__).resolve().parent.parent
shared = {'KeychainGroupIdentifier':'$(KEYCHAIN_GROUP_IDENTIFIER)', 'AppGroupIdentifier':'$(APP_GROUP_IDENTIFIER)', 'KeychainAccessGroup':'$(AppIdentifierPrefix)$(KEYCHAIN_GROUP_IDENTIFIER)'}
app = dict(shared, CFBundleURLTypes=[{'CFBundleURLName':'CodexUsage', 'CFBundleURLSchemes':['codexusage']}])
widget = dict(shared, NSExtension={'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'})
entitlements = {'com.apple.security.application-groups':['$(APP_GROUP_IDENTIFIER)'], 'keychain-access-groups':['$(AppIdentifierPrefix)$(KEYCHAIN_GROUP_IDENTIFIER)']}
for name, value in [('App/Info.plist',app), ('Widget/Info.plist',widget), ('Configuration/Shared.entitlements',entitlements)]:
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value))
assets = root / 'App/Assets.xcassets'
assets.mkdir(parents=True, exist_ok=True)
(assets / 'Contents.json').write_text(json.dumps({'info':{'author':'xcode','version':1}}))
icon = assets / 'AppIcon.appiconset'
icon.mkdir(exist_ok=True)
(icon / 'Contents.json').write_text(json.dumps({'images':[{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}], 'info':{'author':'xcode','version':1}}))

