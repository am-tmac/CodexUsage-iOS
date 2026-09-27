"""Build9 UI/security wiring checks; native build verifies Swift types."""
from pathlib import Path
import unittest
R = Path(__file__).resolve().parents[1]
class DashboardContract(unittest.TestCase):
    def test_phone_key_entry_and_account_configuration(self):
        app = (R/'App/DeepSeekPanel.swift').read_text()
        self.assertIn('SecureField(', app)
        self.assertIn('.privacySensitive()', app)
        self.assertIn('scenePhase', app)
        self.assertIn('DeepSeekService.shared.install', app)
        self.assertIn('granted', app)
        self.assertIn('toppedUp', app)
        widget = (R/'Widget/CodexUsageWidget.swift').read_text()
        for token in ['AppIntentConfiguration', '.systemSmall, .systemMedium', 'leftAccount', 'rightAccount', 'DashboardStore.canRefresh', 'DeepSeekService.shared.refresh']:
            self.assertIn(token, widget)
        # build 27: the panel moved into the 连接账号 sheet together with every other sign-in.
        self.assertIn('DeepSeekPanel(model: model)', (R/'App/ConnectViews.swift').read_text())
        # 三种来源都能落到组件槽位里（Codex / DeepSeek / Antigravity；OpenCode 已按用户要求摘除）。
        views = (R/'Shared/UsageViews.swift').read_text()
        for token in ['AntigravityWidgetView', 'DeepSeekStackedCardView', 'CompactUsageView']:
            self.assertIn(token, views)
        self.assertIn('AntigravityService.shared.refresh', widget)
    def test_navy_dashboard_no_charts_and_no_secrets(self):
        views = (R/'Shared/UsageViews.swift').read_text()
        # 组件侧只有一套调色板：深海军蓝背景 + 白色主文字定义在 ThemePalette 内，
        # 视图层不再硬编码白色或 .secondary（外观由 App 的主题设置决定）。
        self.assertIn('Color(red: 0.035, green: 0.065, blue: 0.13)', views)
        self.assertIn('primary: .white', views)
        self.assertIn('DeepSeekCompactView', views)
        # 'Antigravity' 曾经是禁用词（build 9 时组件只有 Codex/DeepSeek 两个来源）。用户明确要求
        # Antigravity 作为组件来源、带自己的标记后，这个禁用项不再成立；其余守卫不变：
        # 组件里不得出现 Codex 花标、Charts 或硬编码白色（外观由主题设置决定），也不得出现模型品牌
        # 之外的东西（'Gemini' 保留，池名在 Shared/Antigravity.swift 里拼，不进视图层）。
        # OpenCode 已整源摘除（无官方用量接口），共享代码与组件里不留它的痕迹。
        for token in ['CodexBlossom', 'import Charts', 'Gemini', '.foregroundStyle(.white)']:
            self.assertNotIn(token, views)
        # App 侧的 7 天 token 柱状图是 App-only 的（由 Tests/token_usage_contract.py 断言）；
        # 组件永不引入 Charts。
        self.assertNotIn('import Charts', (R/'Widget/CodexUsageWidget.swift').read_text())
        storage = (R/'Shared/Storage.swift').read_text()
        self.assertIn('try DashboardStore.publish()', storage)
        self.assertIn('recoverDisplayIdentity', storage)
if __name__ == '__main__': unittest.main()
