"""Static UI policy checks complement native compilation, not physical WidgetKit tests."""
from pathlib import Path
import re
import unittest
ROOT = Path(__file__).resolve().parents[1]


class WidgetRefreshContract(unittest.TestCase):
    def test_fifteen_minute_request(self):
        source = (ROOT / 'Widget/CodexUsageWidget.swift').read_text()
        self.assertIn('addingTimeInterval(900)', source)
        self.assertNotIn('addingTimeInterval(1800)', source)
    def test_cache_only_control_is_present_and_never_disguised_as_refresh(self):
        # Contract change (build 21): build 20 answered the earlier "the icon opened the App"
        # complaint by deleting the cache-only control, so on a device without the sharing
        # handshake the widget had NO refresh control at all. The policy is now: exactly one
        # control, present in BOTH states, and the two states must never look alike.
        views = (ROOT / 'Shared/UsageViews.swift').read_text()
        widget = (ROOT / 'Widget/CodexUsageWidget.swift').read_text()
        affordance = views.split('struct RefreshAffordance: View {', 1)[1].split('\nstruct DeepSeekCompactView:', 1)[0]
        self.assertIn('if canRefresh {', affordance)
        self.assertIn('} else {', affordance)
        authorized = affordance.split('if canRefresh {', 1)[1].split('} else {', 1)[0]
        cache_only = affordance.split('} else {', 1)[1].split('#else', 1)[0]
        glyph_def = affordance.split('var glyph: some View {', 1)[1].split('}', 1)[0]
        open_def = affordance.split('var openAppGlyph: some View {', 1)[1].split('}', 1)[0]
        # The two states must not share a symbol: the circular refresh glyph belongs to the
        # AppIntent refresh only, and the open-App branch draws something visibly different.
        self.assertIn('arrow.clockwise', glyph_def)
        self.assertIn('arrow.up.forward.app', open_def)
        self.assertNotIn('arrow.clockwise', open_def)
        # Authorized: the real in-widget AppIntent refresh, drawn with the circular glyph.
        self.assertIn('Button(intent: RefreshDashboardIntent(leftID: leftID, rightID: rightID))', authorized)
        self.assertIn('glyph', authorized)
        self.assertNotIn('openAppGlyph', authorized)
        self.assertIn('.frame(width: 44, height: 44).contentShape(Rectangle())', authorized)
        # Not authorized: an open-App control that is visibly a different glyph and label, and
        # carries no refresh intent at all. It opens the App, where the fetch is actually allowed.
        self.assertIn('Link(destination: Self.openAppURL)', cache_only)
        self.assertIn('openAppGlyph', cache_only)
        self.assertIn('accessibilityLabel("打开 App 刷新")', cache_only)
        self.assertNotIn('RefreshDashboardIntent', cache_only)
        # No root widgetURL: no tap can be routed around the AppIntent refresh button.
        self.assertNotIn('.widgetURL(', widget)
        self.assertIn('仅缓存 · 组件无刷新授权，打开 App', views)
        self.assertIn('guard DashboardStore.canRefreshAnyProvider(id) else { continue }', views)
        self.assertIn('for id in RefreshTargets.unique([leftID, rightID])', views)
    def test_widget_refresh_authorization_is_visible_in_the_app(self):
        # The point of the control is that the user can turn the real refresh on: the App must name
        # the missing step and refuse the switch instead of silently failing.
        storage = (ROOT / 'Shared/Storage.swift').read_text()
        store = (ROOT / 'Shared/DashboardStore.swift').read_text()
        app = (ROOT / 'App/CodexUsageApp.swift').read_text()
        self.assertIn('static var canEnableWidgetRefreshConsent: Bool', storage)
        self.assertIn('static var widgetConsentBlockerText: String', storage)
        self.assertIn('static func refreshAuthorization() -> WidgetRefreshAuthorization', store)
        self.assertIn('static func canRefreshAnyProvider', store)
        self.assertIn('SharedStorage.cacheSharingAvailable, let group = SharedStorage.permittedGroup', store)
        self.assertIn('row.credentialGroup == group', store)
        self.assertIn('Toggle("允许组件独立联网刷新"', app)
        self.assertIn('.disabled(!widgetConsentEnabled && !SharedStorage.canEnableWidgetRefreshConsent && !SharedStorage.canForceWidgetRefreshConsent)', app)
        self.assertIn('SharedStorage.widgetConsentBlockerText', app)
        self.assertIn('Button("开始非敏感跨进程验证")', app)
    def test_consent_switch_can_never_dead_end_on_a_resigned_device(self):
        # The handshake round trip needs the extension to render while the App runs, which a
        # re-signed build may never deliver. Gating the switch on it alone leaves the user with a
        # permanently dead switch and a cache-only widget, so an explicit acknowledged override
        # exists — and it may only authorize a group this device really probed.
        storage = (ROOT / 'Shared/Storage.swift').read_text()
        app = (ROOT / 'App/CodexUsageApp.swift').read_text()
        self.assertIn('static var canForceWidgetRefreshConsent: Bool', storage)
        self.assertIn('func permitsForced(group: String?) -> Bool', storage)
        self.assertIn('consent.permitsForced(group: diagnostics.selectedGroup)', storage)
        self.assertIn('guard let group = diagnostics.selectedGroup, diagnostics.observedDefaultGroup == group', storage)
        self.assertIn('setWidgetRefreshConsent(_ enabled: Bool, forced: Bool = false)', storage)
        # The strict round-trip path stays first and is not weakened by the override.
        self.assertIn('connected: (try? session.appConfirmed(read: session.read)) == true', storage)
        self.assertIn('consent.permits(group: diagnostics.selectedGroup, handshakeID: session.id', storage)
        # The switch is disabled only when NEITHER path can authorize a real group.
        self.assertIn('.disabled(!widgetConsentEnabled && !SharedStorage.canEnableWidgetRefreshConsent && !SharedStorage.canForceWidgetRefreshConsent)', app)
        self.assertIn('try SharedStorage.setWidgetRefreshConsent(true, forced: true)', app)
        # A forced consent is disclosed in the UI, and its failure mode is stated honestly.
        self.assertIn('consent.forced == true', app)
        self.assertIn('刷新失败 · 保留缓存', app)
    def test_claude_sign_in_lives_on_the_status_page_next_to_the_gpt_login(self):
        # It is an account login, not a setting: putting it under 设置 made it look missing.
        app = (ROOT / 'App/CodexUsageApp.swift').read_text()
        status = app.split('var statusSections: some View {', 1)[1].split('@ViewBuilder var settingsSections', 1)[0]
        settings = app.split('@ViewBuilder var settingsSections', 1)[1]
        self.assertIn('loginCard', status)
        self.assertIn('ClaudePanel(model: model, palette: palette)', status)
        self.assertLess(status.index('loginCard'), status.index('ClaudePanel(model: model, palette: palette)'))
        self.assertNotIn('ClaudePanel(model: model, palette: palette)', settings)
    def test_claude_signs_in_with_oauth_and_keeps_no_session_secret(self):
        # Contract change (build 21): the embedded cookie-scraping browser and the manual
        # sessionKey/key path are DELETED, not hidden — no paste field, no cookie store, no
        # key-based fetch, no allowlist of challenge hosts. The provider is a real sign-in.
        for name in ['App/ClaudePanel.swift', 'Shared/Claude.swift', 'App/CodexUsageApp.swift',
                     'Widget/CodexUsageWidget.swift', 'Scripts/package_widget_build21.py']:
            text = (ROOT / name).read_text()
            self.assertNotIn('sessionKey', text)
            self.assertNotIn('saveCookie', text)
            self.assertNotIn('validateCookie', text)
        claude = (ROOT / 'Shared/Claude.swift').read_text()
        panel = (ROOT / 'App/ClaudePanel.swift').read_text()
        # First-party endpoints and scopes, not invented ones.
        self.assertIn('https://claude.ai/oauth/authorize', claude)
        self.assertIn('https://platform.claude.com/v1/oauth/token', claude)
        self.assertIn('https://api.anthropic.com/api/oauth/usage', claude)
        self.assertIn('9d1c250a-e61b-44d9-88ed-5944d1962f5e', claude)
        self.assertIn('code_challenge_method', claude)
        self.assertIn('oauth-2025-04-20', claude)
        self.assertIn('user:profile', claude)
        # No cookie handling and no embedded web view left anywhere.
        self.assertNotIn('Cookie', claude)
        self.assertNotIn('WKWebView', panel)
        self.assertNotIn('WebKit', panel)
        # Loopback OAuth in the existing Antigravity style: fixed registered port, in-app browser.
        self.assertIn('http://localhost:54545/callback', claude)
        self.assertIn('static let callbackPort: UInt16 = 54545', claude)
        self.assertIn('127.0.0.1', panel)
        self.assertIn('SFSafariViewController', panel)
        self.assertIn('ASWebAuthenticationSession', panel)  # documented as unusable here
        # Only the refresh token is persisted; the access token is never stored.
        self.assertIn('static let service = "CodexUsage.Claude.oauth.v1"', claude)
        self.assertIn('struct ClaudeCredential: Codable, Equatable {', claude)
        credential = claude.split('struct ClaudeCredential: Codable, Equatable {', 1)[1].split('}', 1)[0]
        self.assertIn('refreshToken', credential)
        self.assertNotIn('accessToken', credential)
        # The pre-OAuth record is deleted, and the deletion is disclosed.
        self.assertIn('invalidateLegacyCredential', claude)
        self.assertIn('SecItemDelete(legacy as CFDictionary)', claude)
        # The legacy service name survives only as the delete target — never as a live query.
        self.assertEqual(claude.count('CodexUsage.Claude.session.v1'), 1)
        legacy = claude.split('static let legacyService', 1)[0]
        self.assertNotIn('CodexUsage.Claude.session.v1', legacy)
        self.assertIn('invalidateLegacyCredential()', (ROOT / 'App/CodexUsageApp.swift').read_text())
        # The risk is stated, not glossed: no claim of compliance or stability.
        self.assertIn('不授权第三方', panel)
        self.assertIn('可能随时被更改或封禁', panel)
    def test_both_rows_display_actual_reset_timestamp(self):
        source = (ROOT / 'Shared/UsageViews.swift').read_text()
        self.assertIn('row("5h", window: snapshot?.usage.rateLimit?.primaryWindow)', source)
        self.assertIn('row("7d", window: snapshot?.usage.rateLimit?.secondaryWindow)', source)
        self.assertIn('Label(ResetTimestamp.text(window?.resetDate), systemImage: "clock")', source)
        self.assertNotIn('snapshot?.updatedAt ?? Date()', source)
        self.assertIn('else { Text("—") }', source)
        # Both rows are unconditional and cannot be squeezed out of the small layout.
        self.assertLess(source.index('row("5h"'), source.index('row("7d"'))
        self.assertIn('.fixedSize(horizontal: false, vertical: true)', source)
    def test_intent_only_in_extension(self):
        source = (ROOT / 'Shared/UsageViews.swift').read_text()
        self.assertIn('#if CODEX_WIDGET\n/// One control for the whole widget', source)
        self.assertIn('struct RefreshDashboardIntent: AppIntent', source)
        self.assertIn('static var openAppWhenRun = false', source)
        project = (ROOT / 'CodexUsage.xcodeproj/project.pbxproj').read_text()
        self.assertEqual(project.count('SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) CODEX_WIDGET"'), 2)
    def test_preserves_namespace_without_migration(self):
        source = (ROOT / 'Shared/Storage.swift').read_text()
        self.assertIn('kSecAttrService as String: "CodexUsage.OAuth.private"', source)
        self.assertIn('consent.permits(', source)
        self.assertIn('try checkPermission()', source)
    def test_in_progress_label_is_persisted_and_truthful(self):
        widget = (ROOT / 'Widget/CodexUsageWidget.swift').read_text()
        views = (ROOT / 'Shared/UsageViews.swift').read_text()
        storage = (ROOT / 'Shared/Storage.swift').read_text()
        # A truthful static label, never an animated/fake spinner.
        self.assertIn('刷新中', views)
        self.assertNotIn('ProgressView', views)
        # The label is driven by the persisted start marker, not an optimistic guess.
        self.assertIn('isRefreshing(at: Date())', widget)
        self.assertIn('WidgetRefreshAttempt.load(', widget)
        self.assertIn('refreshing: value.refreshing', widget)
        # Timeline re-render must show progress without issuing a competing fetch.
        self.assertLess(widget.index('isRefreshing(at: Date())'), widget.index('try await UsageService.shared.refresh(account: id, widget: true'))
        # Extension-kill recovery clears the stale marker before the throttle decision.
        self.assertIn('recoverInterrupted', storage)
        self.assertLess(storage.index('recoverInterrupted(Date())'), storage.index('guard attempt.allows(Date())'))
    def test_single_tap_stays_single_request(self):
        source = (ROOT / 'Shared/Storage.swift').read_text()
        views = (ROOT / 'Shared/UsageViews.swift').read_text()
        widget = (ROOT / 'Widget/CodexUsageWidget.swift').read_text()
        self.assertIn('attempt.begin(Date()); try attempt.save(id)', source)
        self.assertIn('.reloadTimelines(ofKind: "CodexUsageWidget")', source)
        # Only the extension compiles an intent; the App never issues a widget fetch.
        self.assertIn('#if CODEX_WIDGET', views)
        self.assertEqual(views.count('struct RefreshDashboardIntent: AppIntent'), 1)
        self.assertIn('WidgetCenter.shared.reloadAllTimelines()', views)
        self.assertIn('catch is CancellationError {\n                throw CancellationError()', views)
        self.assertIn('catch is CancellationError {\n                return Timeline(entries:', widget)

    # --- parsers: never rely on generated Xcode object IDs staying the same ---
    def _target_block(self, project, name):
        pattern = r'\n\t\t[0-9A-F]{24} /\* [^*]* \*/ = \{\n\t\t\tisa = PBXNativeTarget;(?:(?!\n\t\t\};).)*?name = ' + name + r';.*?\n\t\t\};'
        match = re.search(pattern, project, re.S)
        self.assertIsNotNone(match, f"{name} target not found")
        return match.group(0)
    def _phase_block(self, project, object_id, comment):
        pattern = r'\n\t\t' + object_id + r' /\* ' + comment + r' \*/ = \{(?:(?!\n\t\t\};).)*?\n\t\t\};'
        match = re.search(pattern, project, re.S)
        self.assertIsNotNone(match, f"{comment} phase {object_id} not found")
        return match.group(0)
    def _resources_phase(self, project, target_name):
        phase_ids = re.findall(r'([0-9A-F]{24}) /\* Resources \*/', self._target_block(project, target_name))
        self.assertEqual(len(phase_ids), 1, f"{target_name} must have exactly one Resources phase")
        return self._phase_block(project, phase_ids[0], 'Resources')
    def test_widget_title_has_no_logo_asset_or_drawing_code(self):
        views = (ROOT / 'Shared/UsageViews.swift').read_text()
        project = (ROOT / 'CodexUsage.xcodeproj/project.pbxproj').read_text()
        # Build 7 removed the Blossom title mark; the header is the plain bold title.
        self.assertIn('Text("Codex").font(.system(size: 19, weight: .bold))', views)
        for forbidden in ['CodexBlossom', 'CodexBlossomMark', 'Image("CodexBlossom")',
                          'struct CodexMark', 'AngularGradient', 'UIColor.white']:
            self.assertNotIn(forbidden, views)
        # No orphaned widget catalog, and no logo-fetch/asset-generation step left to reintroduce it.
        self.assertFalse((ROOT / 'Widget/Assets.xcassets').exists())
        self.assertFalse((ROOT / 'Scripts/fetch_codex_logo.py').exists())
        self.assertNotIn('Widget/Assets.xcassets', project)
        self.assertNotIn('CodexBlossom', project)
        self.assertNotIn('Widget/Assets.xcassets', (ROOT / 'Scripts/generate_project.rb').read_text())
        configure = (ROOT / 'Scripts/configure.py').read_text()
        self.assertNotIn('CodexBlossom', configure)
        self.assertNotIn('widget_assets', configure)
        # The App's own catalog and Resources phase are untouched; the widget compiles no catalog.
        self.assertNotIn('Assets.xcassets', self._resources_phase(project, 'CodexUsageWidget'))
        app_catalog = self._resources_phase(project, 'CodexUsage')
        self.assertEqual(re.findall(r'path = (App/Assets\.xcassets)', project), ['App/Assets.xcassets'])
        self.assertIn('Assets.xcassets in Resources', app_catalog)
    def test_account_label_is_display_only_masked_by_default_and_never_invented(self):
        views = (ROOT / 'Shared/UsageViews.swift').read_text()
        storage = (ROOT / 'Shared/Storage.swift').read_text()
        models = (ROOT / 'Shared/Models.swift').read_text()
        auth = (ROOT / 'Shared/AuthAPI.swift').read_text()
        app = (ROOT / 'App/CodexUsageApp.swift').read_text()
        # Widget renders the saved label on one line so the quota rows cannot be pushed.
        self.assertIn('snapshot?.accountLabel', views)
        self.assertIn('truncationMode(.middle)', views)
        self.assertIn('layoutPriority(1)', views)
        # One masking decision for App and Widget; default is masked.
        self.assertIn('masked: !showFull', storage)
        self.assertIn('public static func text(identity: String?, plan: String?, masked: Bool) -> String', models)
        self.assertIn('snapshotLabel(email: email, plan: plan, showFull: showFullAccountInWidget)', storage)
        self.assertIn('guard let url, let data = try? Data(contentsOf: url),', storage)
        self.assertIn('guard !isWidget, let url else { throw ServiceError.storage("共享容器不可用") }', storage)
        self.assertIn('"widget-identity-display.json"', storage)
        self.assertIn('WidgetIdentityDisplay', storage)
        self.assertIn('showFullAccountInWidget', app)
        self.assertIn('setShowFullAccountInWidget', app)
        # Identity is a read-only display claim; a plan is never invented.
        self.assertIn('static func emailClaim', auth)
        self.assertIn('unknownIdentity', models)
        self.assertIn('guard let plan, !plan.isEmpty else { return base }', models)
        # The local sequence label is gone from the App list/switcher.
        self.assertNotIn('账号 \\(index', app)
        self.assertIn('model.label(for: id)', app)
        # The snapshot carries display text only: no tokens or credentials.
        self.assertIn('public var accountLabel: String? = nil', models)
        block = re.search(r'public struct UsageSnapshot:[^{]+\{.*?\n\}', models, re.S).group(0)
        for forbidden in ['accessToken', 'refreshToken', 'idToken']:
            self.assertNotIn(forbidden, block)
        self.assertIn('accountLabel: SharedStorage.snapshotLabel', storage)


    def test_one_top_right_refresh_control_per_family(self):
        widget = (ROOT / 'Widget/CodexUsageWidget.swift').read_text()
        views = (ROOT / 'Shared/UsageViews.swift').read_text()
        # Columns never draw their own button; each family gets exactly one control, pinned to the
        # top-right corner. Build 10 regressed by drawing it only for the medium family (as a footer),
        # which left the small widget with no refresh control at all.
        self.assertIn('column(entry.left)', widget)
        self.assertIn('column(entry.right)', widget)
        self.assertEqual(widget.count('RefreshAffordance(canRefresh:'), 1)
        self.assertEqual(views.count('Button(intent: RefreshDashboardIntent'), 1)
        self.assertIn('.overlay(alignment: .topTrailing)', widget)
        self.assertNotIn('if family == .systemMedium', widget)
        # The medium control carries both slots; the small control only the slot it displays.
        self.assertIn('canRefresh: isMedium ? (entry.left.canRefresh || entry.right.canRefresh)', widget)
        self.assertIn('rightID: isMedium ? entry.right.id : nil', widget)
        self.assertIn('var hasConfiguredAccount: Bool { isMedium ? (entry.left.id != nil || entry.right.id != nil) : entry.left.id != nil }', widget)
        self.assertIn('if hasConfiguredAccount { refreshControl }', widget)
        # Deduplicated: the same account is never refreshed twice by one tap.
        self.assertIn('public static func unique(_ ids: [String?]) -> [String]', (ROOT / 'Shared/Models.swift').read_text())
    def test_refresh_hit_area_anchors_codex_corner_and_deepseek_bottom_right(self):
        widget = (ROOT / 'Widget/CodexUsageWidget.swift').read_text()
        views = (ROOT / 'Shared/UsageViews.swift').read_text()
        # The 44pt hit region is at the outer Codex top-right corner, but at the
        # *bottom-right* of the stacked wallet: old 38pt bottom padding placed the
        # DeepSeek glyph halfway up the black card, not in the requested corner.
        self.assertIn('inset: stackedCard ? 4 : 0, topInset: 0,', widget)
        self.assertIn('bottomInset: stackedCard ? 4 : 0, bottomAligned: stackedCard)', widget)
        self.assertIn('control.padding(.trailing, inset).padding(.bottom, bottomInset)', views)
        self.assertIn('.frame(width: 44, height: 44).contentShape(Rectangle())', views)
        self.assertIn('.overlay(alignment: .topTrailing)', widget)
        # Reserve space for the wallet button so its 44pt hit target cannot cover
        # digits even when the currency string becomes longer.
        self.assertIn('.padding(.trailing, 48)', views)

    def test_theme_preference_is_shared_applied_and_not_hardcoded(self):
        models = (ROOT / 'Shared/Models.swift').read_text()
        views = (ROOT / 'Shared/UsageViews.swift').read_text()
        widget = (ROOT / 'Widget/CodexUsageWidget.swift').read_text()
        app = (ROOT / 'App/CodexUsageApp.swift').read_text()
        # One stored preference, read by the extension and written by the App.
        self.assertIn('public enum ThemePreference: String, CaseIterable, Codable, Sendable', models)
        self.assertIn('case system, light, dark', models)
        self.assertIn('return .system', models)  # unknown/missing value never crashes or blanks
        self.assertIn('theme: ThemePreference.load()', widget)
        self.assertIn('ThemePreference.allCases', app)
        self.assertIn('Picker("主题"', app)
        self.assertIn('.preferredColorScheme(theme == .system ? nil', app)
        # The widget resolves the same palette instead of hardcoding one appearance.
        self.assertIn('.resolve(entry.theme, scheme: scheme)', widget)
        self.assertIn('containerBackground(palette.background, for: .widget)', widget)
        self.assertNotIn('Color(red: 0.035, green: 0.065, blue: 0.13)', widget)
        for forbidden in ['.foregroundStyle(.white)', 'Color.white']:
            self.assertNotIn(forbidden, views)
    def test_legacy_identity_backfill_is_read_only_offline_and_keeps_the_placeholder(self):
        storage = (ROOT / 'Shared/Storage.swift').read_text()
        auth = (ROOT / 'Shared/AuthAPI.swift').read_text()
        models = (ROOT / 'Shared/Models.swift').read_text()
        # Load-time recovery exists and derives from the stored access token's claims
        # using the same extraction rules as login; it persists what it found.
        self.assertIn('private static func recoverDisplayIdentity(', storage)
        self.assertIn('stored.recoveredDisplayIdentity()', storage)
        self.assertIn('recoveringDisplayIdentity: true', storage)
        self.assertIn('Credentials(accessToken: fresh.accessToken, refreshToken: fresh.refreshToken', storage)
        self.assertIn('func recoveredDisplayIdentity() -> String? {', auth)
        self.assertIn('Self.nonBlank(email) ?? Self.emailClaim(Self.claims(accessToken))', auth)
        # Identity stays optional: no required field, no empty string, no wrong account.
        self.assertIn('public let email: String?', auth)
        self.assertIn('unknownIdentity', models)
        self.assertIn('guard let plan, !plan.isEmpty else { return base }', models)
        # The recovery block performs no network I/O and never triggers a token refresh.
        recovery = storage.split('private static func recoverDisplayIdentity(')[1].split('\n    static func save(')[0]
        for forbidden in ['URLSession', 'AuthAPI', 'await ', 'api.refresh', 'api.usage', 'func post(']:
            self.assertNotIn(forbidden, recovery)
        # It re-reads before writing so a concurrent rotation cannot be rolled back.
        self.assertIn('fresh.accessToken == stored.accessToken', recovery)
        self.assertIn('fresh.refreshToken == stored.refreshToken', recovery)
        # Masking rules are untouched: the shared snapshot is masked unless opted in,
        # and the recovered identity feeds the same single masking decision.
        self.assertIn('masked: !showFull', storage)
        self.assertIn('snapshotLabel(email: email, plan: plan, showFull: showFullAccountInWidget)', storage)
        self.assertIn('credentials.displayIdentity, plan: usage.planType', storage)
        self.assertIn('public var displayIdentity: String?', auth)


if __name__ == '__main__': unittest.main()
