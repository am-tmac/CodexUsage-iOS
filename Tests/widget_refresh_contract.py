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
    def test_cache_refresh_opens_app(self):
        views = (ROOT / 'Shared/UsageViews.swift').read_text()
        # One control serves every slot: an in-extension refresh when the account is authorized,
        # otherwise a link that opens the App (cache mode never pretends to fetch).
        self.assertIn('Link(destination: URL(string: "codexusage://refresh")!)', views)
        self.assertIn('Button(intent: RefreshDashboardIntent(leftID: leftID, rightID: rightID))', views)
        self.assertIn('guard DashboardStore.canRefreshAnyProvider(id) else { continue }', views)
        self.assertIn('for id in RefreshTargets.unique([leftID, rightID])', views)
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
