import SwiftUI
import WidgetKit

/// DeepSeek key management. Same black-card visual language as the status page; every original
/// string (including the keychain risk notice) is kept word for word.
///
/// Reads and writes through the App's single `UsageModel`, so a key added or removed here shows up
/// on 状态 at once, and a return to the foreground refreshes each account once (the model does it),
/// not once per screen.
struct DeepSeekPanel: View {
    @ObservedObject var model: UsageModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    private var ids: [String] { model.deepSeekIDs }
    private var snapshots: [String: DeepSeekSnapshot] { model.balances }
    @State private var key = ""
    @State private var replacing: String?
    @State private var busy = false
    @State private var consent = false
    @State private var message: String?
    var palette: AppPalette { .resolve(scheme) }
    /// Keychain or snapshot changed: republish through the model (it also rebuilds the widget
    /// dashboard) and ask WidgetKit to redraw.
    func reload() {
        model.reloadAccounts()
        WidgetCenter.shared.reloadAllTimelines()
    }
    func refresh(_ id: String) async {
        message = nil
        if let error = await model.refreshDeepSeek(id) {
            message = (error as? DeepSeekError)?.localizedDescription ?? "余额更新失败，保留缓存"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                AppCard(title: "DeepSeek · 账号 \(index + 1)", caption: "仅 API 平台余额，不是聊天订阅额度。按接口原币种显示，不合并或推算百分比。",
                        systemImage: "water.waves", palette: palette,
                        mark: AnyView(BrandMark(brand: .deepseek, palette: palette))) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let snapshot = snapshots[id] {
                            ForEach(Array(snapshot.balance.balanceInfos.enumerated()), id: \.offset) { _, info in
                                VStack(alignment: .leading, spacing: 0) {
                                    AppRow(label: "总余额", value: Money.text(info.total, currency: info.currency), palette: palette)
                                    AppRow(label: "赠送", value: Money.text(info.granted, currency: info.currency), palette: palette)
                                    AppRow(label: "充值", value: Money.text(info.toppedUp, currency: info.currency), palette: palette)
                                }
                            }
                            AppRow(label: "接口状态", value: snapshot.balance.isAvailable ? "API 余额可用" : "API 余额不可用", palette: palette)
                            AppRow(label: "更新时间", value: RelativeTime.text(snapshot.updatedAt) + (snapshot.isStale() ? " · 已过期" : ""), palette: palette)
                            if model.deepSeekFailed.contains(id) {
                                Text("刷新失败 · 保留上次余额").font(.caption).foregroundStyle(palette.warning)
                            }
                        } else {
                            AppRow(label: "接口状态", value: "暂无余额数据", palette: palette)
                        }
                        HStack(spacing: 10) {
                            Button("刷新") { Task { await refresh(id) } }
                            Button("更新 Key") { replacing = id; key = ""; consent = false }
                            Button("移除", role: .destructive) {
                                Task {
                                    do { try await DeepSeekService.shared.remove(id); reload() }
                                    catch { message = "移除失败，请解锁后重试" }
                                }
                            }
                        }.buttonStyle(.bordered).disabled(busy || model.busy).tint(palette.accent)
                    }
                }
            }
            AppCard(title: "DeepSeek API 余额", caption: replacing == nil ? "添加独立 API 账号" : "更新所选账号 Key（不回显旧 Key）",
                    systemImage: "key.horizontal", palette: palette) {
                VStack(alignment: .leading, spacing: 12) {
                    SecureField("在 iPhone 输入 DeepSeek API Key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        .textFieldStyle(.roundedBorder)
                    Toggle("知悉同组钥匙串风险，允许保存此 Key", isOn: $consent).tint(palette.accent)
                    Text("Key 仅写入本机 Keychain，不写快照或日志。购买证书的同组其他 App 可能读取 Key，service 名不是权限隔离；此操作不自动授权组件联网。组件沿用下方握手及独立刷新同意开关。")
                        .font(.caption).foregroundStyle(palette.secondary)
                    HStack(spacing: 10) {
                        Button("保存并读取余额") {
                            let entered = key
                            let replacingID = replacing
                            key = ""; busy = true; message = nil
                            Task {
                                do {
                                    let id = try await DeepSeekService.shared.install(key: entered, replacing: replacingID)
                                    if replacing == replacingID { replacing = nil; consent = false }
                                    _ = try await DeepSeekService.shared.refresh(id: id, widget: false)
                                } catch is CancellationError {
                                } catch { message = (error as? DeepSeekError)?.localizedDescription ?? "保存或读取失败，请解锁并检查签名" }
                                busy = false; reload()
                            }
                        }.buttonStyle(.borderedProminent).tint(palette.accent).disabled(!consent || key.isEmpty || busy)
                        if replacing != nil { Button("取消") { replacing = nil; key = ""; consent = false }.disabled(busy).tint(palette.secondary) }
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(palette.warning) }
                }
            }
        }
        // Foreground refresh and the widget's open-App link are handled once by ContentView; this
        // panel only has to wipe the half-typed key when the App leaves the foreground.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { key = ""; consent = false }
        }
        .onDisappear { key = ""; consent = false }
    }
}
