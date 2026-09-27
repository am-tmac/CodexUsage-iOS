#!/usr/bin/env python3
"""Package private-ID unsigned build 27, rejecting stale or signed payloads.

Build 27 reworks the App screens only (widget untouched): official provider marks, collapsed-card
summary line, reset countdowns from the reported reset time, and a 连接账号 sheet that now holds every
sign-in (status page = account cards, "⋯" menus = refresh / reauthorize / remove). No demo mode.

Build 26 kept the build 24 look at default text size: status-page errors, one DeepSeek model, Claude-aware empty state, Dynamic Type text, off-render keychain reads; plus the build 25 review fixes (rotated tokens are never dropped,
Antigravity errors no longer wipe good data, the Claude paste-code login works and checks state.

Earlier build 22 addressed these reports against build 21:

* the widget still never refreshed in-widget (the consent switch could dead-end, because the
  App ⇄ Widget handshake round trip it required is not always completable on a re-signed build),
  so an explicit acknowledged override now exists and is disclosed;
* the Claude sign-in sat under 设置 and looked absent — it is an account login and now lives on
  the status page directly under the ChatGPT device-code login.

Markers below are what the shipping payload must literally contain or must NOT contain; each
positive marker is >= 16 UTF-8 bytes, because Swift stores shorter literals as small-string
immediates and a byte scan cannot see them.
"""
from pathlib import Path
import hashlib
import plistlib
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
app = root / 'Build27Direct/Build/Products/Release-iphoneos/CodexUsage.app'
appex = app / 'PlugIns/CodexUsageWidget.appex'
# Private identifiers come from the untracked Configuration/Private.xcconfig, never from this file.
private = {}
for line in (root / 'Configuration/Private.xcconfig').read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('//'):
        key, value = line.split('=', 1)
        private[key.strip()] = value.strip()
base_id = private['CODEX_APP_BUNDLE_IDENTIFIER']
ids = (base_id, base_id + '.Widget')
for bundle, bundle_id in zip((app, appex), ids):
    assert bundle.is_dir(), bundle
    assert not (bundle / '_CodeSignature').exists(), bundle
    assert not (bundle / 'embedded.mobileprovision').exists(), bundle
    info = plistlib.loads((bundle / 'Info.plist').read_bytes())
    assert (info['CFBundleIdentifier'], info['CFBundleVersion'], info['CFBundleShortVersionString'], info['MinimumOSVersion']) == (bundle_id, '27', '2.0', '17.0'), info
    assert '$(' not in str(info)
    executable = bundle / info['CFBundleExecutable']
    assert 'arm64' in subprocess.check_output(['lipo', '-archs', str(executable)], text=True)
    assert subprocess.run(['codesign', '-v', str(bundle)], capture_output=True).returncode != 0
for bundle in (app, appex):
    info = str(plistlib.loads((bundle / 'Info.plist').read_bytes()))
    assert private['APP_GROUP_IDENTIFIER'] in info, bundle
    assert private['KEYCHAIN_GROUP_IDENTIFIER'] in info, bundle

app_binary = (app / 'CodexUsage').read_bytes()
widget = (appex / 'CodexUsageWidget').read_bytes()

# --- widget refresh control: present in both states, never one disguised as the other ---
assert 'arrow.up.forward.app'.encode() in widget          # open-App control, unauthorised state
assert '组件无刷新授权'.encode() in widget
assert '打开 App 刷新'.encode() in widget                  # the open-App control's own label
# --- the consent switch can no longer dead-end, and the override is disclosed ---
assert '可以直接开启：本机有可用的实测 keychain 组'.encode() in app_binary
assert '未完成跨进程验证'.encode() in app_binary
assert '刷新失败 · 保留缓存'.encode() in app_binary
# --- Claude sign-in is a real OAuth login, not a pasted web session ---
assert 'Anthropic 不授权第三方 App 提供 Claude.ai 登录'.encode() in app_binary
assert '用 Claude 账号登录'.encode() in app_binary
assert 'http://localhost:54545/callback'.encode() in app_binary
assert '9d1c250a-e61b-44d9-88ed-5944d1962f5e'.encode() in app_binary
assert 'https://api.anthropic.com/api/oauth/usage'.encode() in app_binary
# The new credential namespace is live, and the pre-OAuth one exists only as the delete target.
assert 'CodexUsage.Claude.oauth.v1'.encode() in app_binary
assert 'CodexUsage.Claude.session.v1'.encode() in app_binary
# --- build 27 review fixes: new user-visible strings (>= 16 bytes) prove this revision ---
assert '授权码格式无法识别，或不属于本次登录'.encode() in app_binary
assert '登录已失效，请重新点「打开授权页面」'.encode() in app_binary
assert '授权码格式无法识别，请粘贴页面上显示的整段内容'.encode() not in app_binary   # old message gone
# --- build 27 App screens: connect sheet, per-service pages, card menus, shortened captions ---
assert '令牌只存本机钥匙串'.encode() in app_binary
assert '订阅额度 · 非官方 OAuth 兼容'.encode() in app_binary
assert 'API 平台余额 · 非聊天订阅'.encode() in app_binary
assert 'Claude 订阅额度 · Claude Code OAuth 兼容方式'.encode() not in app_binary   # old caption gone
assert '体验演示'.encode() not in app_binary
assets = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', 'assetutil', '--info', str(app / 'Assets.car')], text=True)
for logo in ['LogoOpenAI', 'LogoClaude', 'LogoDeepSeek', 'LogoAntigravity']:
    assert f'"{logo}"' in assets, logo
# --- deleted path, negative markers: a stale payload cannot pass as this revision ---
for gone in ['连接 Claude 账号', '登录页面由网站提供', '已阻止非 Claude 或已知登录提供商']:
    assert gone.encode() not in app_binary, gone

out = root / 'Dist/CodexUsage-widget-build27-unsigned.ipa'
out.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in app.rglob('*'):
        if path.is_file():
            archive.write(path, Path('Payload') / app.name / path.relative_to(app))
with zipfile.ZipFile(out) as archive:
    assert archive.testzip() is None
    for suffix, bundle_id in (('', ids[0]), ('PlugIns/CodexUsageWidget.appex/', ids[1])):
        info = plistlib.loads(archive.read('Payload/CodexUsage.app/' + suffix + 'Info.plist'))
        assert (info['CFBundleIdentifier'], info['CFBundleVersion'], info['CFBundleShortVersionString']) == (bundle_id, '27', '2.0')
print(out)
print('sha256:', hashlib.sha256(out.read_bytes()).hexdigest())
print('bundle IDs:', *ids, 'version: 2.0 (27)')
