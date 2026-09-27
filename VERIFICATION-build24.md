# CodexUsage 2.0 (24) 验证

- 产物：`Dist/CodexUsage-widget-build24-unsigned.ipa`，1,161,847 字节，SHA-256 `f22b4903dd5f4392266c9d38fe7dc038430f919ebcf9e32357012c4532c19f86`。
- 对 build 23 的纠正：小号 DeepSeek 刷新控件原先距底部 38pt，图标实际上在黑卡中间偏右。此版将 44pt 点击区的右边/底边分别放在距小组件右边/底边 4pt 处，图标中心约距两边各 26pt，位于黑卡真正右下角；金额行右边预留 48pt，避免被按钮覆盖。Codex 图标仍在整体右上角。授权时为组件内 AppIntent 刷新，未授权时为不同形状的打开 App 链接；Claude 登录与授权流程不变。
- 先修改并运行定位契约，在旧 38pt 实现上失败（`Logs/build24-red.log`），然后修改实现；`python3 Tests/widget_refresh_contract.py -v` 17 项通过（`Logs/build24-contract.log`）。
- ad-hoc 签名模拟器全量测试 67 项、0 失败（`Logs/build24-e2e.log`）；Release iphoneos 未签名构建成功（`Logs/build24-device.log`）。
- `swift test` 41 项中 40 通过、1 项仍因已有的 `storage("锁文件不可用")` 失败（`Logs/build24-swifttest.log`）。
- `Scripts/package_widget_build24.py` 校验 private bundle ID、版本、组配置、arm64、无签名及旧功能标记（`Logs/build24-package.log`）。另用 `shasum`、ZIP 解包复核：两 bundle 分别是私有主 App ID 与其 `.Widget` 扩展（取自 `Configuration/Private.xcconfig`），均为 `2.0 (24)`；无签名目录及 embedded profile。
- 局限：代码尺寸和模拟器测试不是重签真机的像素/触摸验收。小组件位置、组件内网络刷新以及真实 Claude OAuth 登录仍需在用户真机测试。
