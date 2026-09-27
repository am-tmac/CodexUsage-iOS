import SwiftUI
import WidgetKit

@MainActor final class UsageModel: ObservableObject {
    @Published var deepSeekIDs = (try? DeepSeekStore.ids()) ?? []
    @Published var balances: [String: DeepSeekSnapshot] = [:]
    @Published var accounts = (try? SharedStorage.accountIDs()) ?? []
    @Published var snapshots: [String: UsageSnapshot] = [:]
    @Published var emails: [String: String] = [:]
    @Published var selectedWidget = SharedStorage.selectedAccount()
    // Antigravity lives in the App's own state and cached snapshot; the widget reads the same
    // snapshot through DashboardStore.
    @Published var antigravity: AntigravitySnapshot?
    @Published var antigravityInstalled = AntigravityStore.installed()
    @Published var claudeInstalled = ClaudeStore.installed()
    @Published var claudeSnapshot: ClaudeSnapshot? = ClaudeStore.snapshot()
    init() {
        // build 19 and earlier stored a scraped claude.ai session cookie. That path is deleted, not
        // hidden, so the now-unusable record and its cache are removed once and the user is told.
        if ClaudeStore.invalidateLegacyCredential() {
            try? DashboardStore.publish()
            WidgetCenter.shared.reloadAllTimelines()
            message = "已删除旧版 Claude 网页会话凭据（旧的网页会话方式已彻底移除，也不再接受粘贴会话 Cookie）；请在设置里用 Claude 账号重新登录。"
        }
    }
    func reloadAccounts() {
        let nextDeepSeekIDs = (try? DeepSeekStore.ids()) ?? []
        let nextBalances = Dictionary(uniqueKeysWithValues: nextDeepSeekIDs.compactMap { id in DeepSeekStore.snapshot(id).map { (id, $0) } })
        try? DashboardStore.publish()
        let nextAccounts = (try? SharedStorage.accountIDs()) ?? []
        let nextSnapshots = Dictionary(uniqueKeysWithValues: nextAccounts.compactMap { id in SharedStorage.snapshot(account: id).map { (id, $0) } })
        let nextEmails = Dictionary(uniqueKeysWithValues: nextAccounts.compactMap { id in SharedStorage.accountEmail(id).map { (id, $0) } })
        let nextSelectedWidget = SharedStorage.selectedAccount()
        let nextAntigravity = AntigravityStore.snapshot()
        let nextAntigravityInstalled = AntigravityStore.installed()
        let nextClaudeInstalled = ClaudeStore.installed()
        let nextClaudeSnapshot = ClaudeStore.snapshot()
        let nextSignedIn = !nextAccounts.isEmpty || !nextDeepSeekIDs.isEmpty || nextAntigravityInstalled || nextClaudeInstalled
        // ObservableObject publishes even equal assignments. Cache-only reloads should
        // not invalidate every observing view; retain the existing ownership model.
        if deepSeekIDs != nextDeepSeekIDs { deepSeekIDs = nextDeepSeekIDs }
        if balances != nextBalances { balances = nextBalances }
        if accounts != nextAccounts { accounts = nextAccounts }
        if snapshots != nextSnapshots { snapshots = nextSnapshots }
        if emails != nextEmails { emails = nextEmails }
        if selectedWidget != nextSelectedWidget { selectedWidget = nextSelectedWidget }
        if antigravity != nextAntigravity { antigravity = nextAntigravity }
        if antigravityInstalled != nextAntigravityInstalled { antigravityInstalled = nextAntigravityInstalled }
        if claudeInstalled != nextClaudeInstalled { claudeInstalled = nextClaudeInstalled }
        if claudeSnapshot != nextClaudeSnapshot { claudeSnapshot = nextClaudeSnapshot }
        if signedIn != nextSignedIn { signedIn = nextSignedIn }
    }
    func selectWidget(_ id: String) {
        do { try SharedStorage.selectWidgetAccount(id); reloadAccounts(); WidgetCenter.shared.reloadAllTimelines() }
        catch { message = error.localizedDescription }
    }
    /// List/switcher label. The App always shows the full identity; only the shared
    /// snapshot the widget reads is masked (unless the user opts in).
    func label(for id: String) -> String {
        AccountLabel.text(identity: emails[id],
                          plan: AccountLabel.plan(snapshots[id]?.usage.planType),
                          masked: false)
    }
    @Published var code: DeviceCode?
    @Published var busy = false
    @Published var signingIn = false
    @Published var message: String?
    @Published var signedIn = (try? SharedStorage.credentials()) != nil
    private var loginTask: Task<Void, Never>?
    private var generation = UUID()
    func refresh(account: String? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        for id in account.map({ [$0] }) ?? accounts {
            do { snapshots[id] = try await UsageService.shared.refresh(account: id) }
            catch is CancellationError { return }
            catch { message = error.localizedDescription }
        }
        if account == nil {
            for id in deepSeekIDs {
                do { balances[id] = try await DeepSeekService.shared.refresh(id: id, widget: false) }
                catch is CancellationError { return }
                catch { message = error.localizedDescription }
            }
            if antigravityInstalled {
                do { antigravity = try await AntigravityService.shared.refresh(widget: false) }
                catch is CancellationError { return }
                catch { message = error.localizedDescription }
            }
            if claudeInstalled {
                do { claudeSnapshot = try await ClaudeService.shared.refresh(widget: false) }
                catch is CancellationError { return }
                catch { message = (error as? ClaudeFailure)?.localizedDescription ?? "Claude 刷新失败，保留缓存" }
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
    func login() {
        cancelLogin()
        let current = UUID(); generation = current; signingIn = true; message = nil
        loginTask = Task {
            do {
                let api = AuthAPI()
                let code = try await api.start()
                try Task.checkCancellation()
                self.code = code
                let credentials = try await api.complete(code)
                try Task.checkCancellation()
                guard generation == current else { return }
                do { try await UsageService.shared.install(credentials) }
                catch is CancellationError { return }
                catch {
                    guard generation == current else { return }
                    message = "设备授权已成功，但本机保存失败。请解锁手机后重试；若仍失败，请检查重签的钥匙串权限并重新登录。\(error.localizedDescription)"
                    reloadAccounts(); signingIn = false; self.code = nil; return
                }
                try Task.checkCancellation()
                guard generation == current else { return }
                reloadAccounts()
                signedIn = true; self.code = nil; signingIn = false
                await refresh()
            } catch is CancellationError {} catch { if generation == current { message = error.localizedDescription } }
            if generation == current { signingIn = false; self.code = nil }
        }
    }
    func cancelLogin() { generation = UUID(); loginTask?.cancel(); loginTask = nil; code = nil; signingIn = false }
    func logout(account: String) async {
        cancelLogin()
        do { try await UsageService.shared.logout(account: account); reloadAccounts(); message = nil; WidgetCenter.shared.reloadAllTimelines() }
        catch { message = error.localizedDescription }
    }
}

// MARK: - App appearance
//
// `ThemePalette` (App + Widget) is the accepted widget palette and stays untouched: the widget
// keeps its navy look. The App renders its card layout with a separate palette,
// which is why this type is separate.
struct AppPalette {
    let background: Color
    let card: Color
    let tile: Color
    let primary: Color
    let secondary: Color
    let tertiary: Color
    let divider: Color
    let meterUsed: Color
    let meterRest: Color
    let capsule: Color
    let pill: Color
    let accent: Color
    let warning: Color
    let danger: Color
    static let dark = AppPalette(background: Color(red: 0.004, green: 0.004, blue: 0.008),
                                 card: Color(red: 0.110, green: 0.110, blue: 0.110),
                                 tile: Color(red: 0.173, green: 0.173, blue: 0.180),
                                 primary: Color(white: 1), secondary: Color(white: 0.62), tertiary: Color(white: 0.50),
                                 divider: Color(white: 1).opacity(0.08),
                                 meterUsed: Color(red: 0.212, green: 0.620, blue: 0.961),
                                 meterRest: Color(red: 0.133, green: 0.204, blue: 0.282),
                                 capsule: Color(red: 0.149, green: 0.149, blue: 0.149),
                                 pill: Color(red: 0.043, green: 0.043, blue: 0.043),
                                 accent: Color(red: 0.212, green: 0.620, blue: 0.961),
                                 warning: Color(red: 1.0, green: 0.62, blue: 0.24),
                                 danger: Color(red: 1.0, green: 0.35, blue: 0.32))
    static let light = AppPalette(background: Color(red: 0.949, green: 0.949, blue: 0.965),
                                  card: Color(white: 1),
                                  tile: Color(red: 0.925, green: 0.925, blue: 0.937),
                                  primary: Color(white: 0.07), secondary: Color(white: 0.42), tertiary: Color(white: 0.55),
                                  divider: Color(white: 0).opacity(0.08),
                                  meterUsed: Color(red: 0.129, green: 0.522, blue: 0.929),
                                  meterRest: Color(red: 0.851, green: 0.878, blue: 0.918),
                                  capsule: Color(red: 0.902, green: 0.902, blue: 0.914),
                                  pill: Color(white: 1),
                                  accent: Color(red: 0.129, green: 0.522, blue: 0.929),
                                  warning: Color(red: 0.72, green: 0.36, blue: 0.02),
                                  danger: Color(red: 0.80, green: 0.16, blue: 0.13))
    static func resolve(_ scheme: ColorScheme) -> AppPalette { scheme == .light ? .light : .dark }
}

/// One black card: icon tile + bold title + caption + trailing controls, then arbitrary content.
struct AppCard<Content: View>: View {
    let title: String
    let caption: String?
    let systemImage: String
    let palette: AppPalette
    var expanded: Binding<Bool>? = nil
    var menu: AnyView? = nil
    /// Optional hand-drawn mark (e.g. the DeepSeek whale) used instead of an SF Symbol.
    var mark: AnyView? = nil
    /// Optional reorder handle, drawn at the header's leading edge (user request: 卡片左上角可拖动排序).
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(palette.tile)
                    .frame(width: 42, height: 42)
                    .overlay {
                        if let mark { mark } else {
                            Image(systemName: systemImage).font(.system(size: 17, weight: .bold)).foregroundStyle(palette.primary)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(palette.primary).lineLimit(1)
                    if let caption {
                        Text(caption).font(.system(size: 12)).foregroundStyle(palette.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                if let menu { menu }
                if let expanded {
                    Button { withAnimation(.snappy(duration: 0.22)) { expanded.wrappedValue.toggle() } } label: {
                        Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.tertiary)
                            .frame(width: 28, height: 28)
                    }.buttonStyle(.plain).accessibilityLabel(expanded.wrappedValue ? "折叠详情" : "展开详情")
                }
            }
            content
        }
        .padding(16)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// Segmented meter from the reference: one dash per slot, the *remaining* share lit — the same
/// thing the widget and chatgpt.com show. It is a gauge, not a chart, and it never invents a
/// value: a missing window lights no dash and the label shows —.
struct DashMeter: View {
    let remainingPercent: Double?
    var palette: AppPalette
    var dashes = 68
    var height: CGFloat = 14
    var lit: Int { guard let remainingPercent else { return 0 }; return min(dashes, max(0, Int((remainingPercent / 100 * Double(dashes)).rounded()))) }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<dashes, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.4, style: .continuous)
                    .fill(index < lit ? palette.meterUsed : palette.meterRest)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
        .accessibilityLabel(remainingPercent.map { "剩余 \(Int($0))%" } ?? "暂无额度数据")
    }
}

struct AppRow: View {
    let label: String
    let value: String
    var palette: AppPalette
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(palette.secondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(palette.primary).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 15))
        .padding(.vertical, 5)
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case status, settings
    var id: String { rawValue }
    var title: String { self == .status ? "状态" : "设置" }
    var systemImage: String { self == .status ? "chart.bar.fill" : "gearshape.fill" }
}

struct ContentView: View {
    @ObservedObject var model: UsageModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    @State private var tab: AppTab = .status
    @State private var expanded: Set<String> = []
    @State private var handshakeStatus = SharedStorage.handshakeText
    @State private var confirmKeychainRisk = false
    @State private var confirmWidgetRisk = false
    @State private var widgetConsentEnabled = SharedStorage.consent != nil
    @State private var showFullInWidget = SharedStorage.showFullAccountInWidget
    @State private var theme = ThemePreference.load()
    @StateObject private var cardOrderModel = CardOrderModel(keys: CardOrder.load())
    @State private var editMode: EditMode = .inactive
    var palette: AppPalette { .resolve(scheme) }
    func setTheme(_ value: ThemePreference) {
        do { try value.save() } catch { model.message = error.localizedDescription }
        theme = ThemePreference.load()
        WidgetCenter.shared.reloadAllTimelines()
    }
    func setWidgetConsent(_ enabled: Bool) {
        guard enabled else {
            do { try SharedStorage.setWidgetRefreshConsent(false); model.reloadAccounts() }
            catch { model.message = error.localizedDescription }
            widgetConsentEnabled = SharedStorage.consent != nil
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        do { try SharedStorage.setWidgetRefreshConsent(true) }
        catch {
            // The App ⇄ Widget round trip could not be completed on this signing (the extension has
            // to render while the App is running to prove it). That is evidence, not a capability,
            // so after the user has acknowledged the risk we authorize the probed group anyway and
            // let the first real in-widget refresh be the test. If the extension cannot read the
            // credential the widget says so and keeps the cache; nothing is faked.
            if SharedStorage.canForceWidgetRefreshConsent {
                do { try SharedStorage.setWidgetRefreshConsent(true, forced: true) }
                catch { model.message = error.localizedDescription }
            } else { model.message = error.localizedDescription }
        }
        model.reloadAccounts()
        widgetConsentEnabled = SharedStorage.consent != nil
        WidgetCenter.shared.reloadAllTimelines()
    }
    func setFullInWidget(_ enabled: Bool) {
        do { try SharedStorage.setShowFullAccountInWidget(enabled); SharedStorage.relabelSnapshots(); model.reloadAccounts() }
        catch { model.message = error.localizedDescription }
        showFullInWidget = SharedStorage.showFullAccountInWidget
        WidgetCenter.shared.reloadAllTimelines()
    }
    /// Local slot text from build 14, kept verbatim: it says which on-device account this is.
    func slotValue(_ id: String) -> String { id == "phone-owned" ? "首个账号" : String(id.prefix(8)) }
    /// Drag key for one card: provider plus account id, stable across launches.
    func cardKey(_ provider: String, _ id: String?) -> String { provider + ":" + (id ?? "-") }
    var orderedCards: [(key: String, view: AnyView)] {
        var cards: [(key: String, view: AnyView)] = []
        for id in model.accounts {
            cards.append((cardKey("codex", id), AnyView(AccountCard(id: id,
                        title: "Codex",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        caption: model.label(for: id),
                        snapshot: model.snapshots[id],
                        expanded: expandedBinding(id),
                        canSelectWidget: SharedStorage.cacheSharingAvailable,
                        palette: palette,
                        onRefresh: { Task { await model.refresh(account: id) } },
                        onSelectWidget: { model.selectWidget(id) },
                        onRemove: { Task { await model.logout(account: id) } },
                        slotValue: slotValue(id)))))
        }
        for (index, id) in model.deepSeekIDs.enumerated() {
            cards.append((cardKey("deepseek", id), AnyView(DeepSeekAccountCard(index: index, snapshot: model.balances[id], palette: palette,
                                onRefresh: { Task { await model.refresh() } },
                                busy: model.busy))))
        }
        if model.antigravityInstalled {
            cards.append((cardKey("antigravity", nil), AnyView(AntigravityCard(snapshot: model.antigravity, palette: palette,
                            onRefresh: { Task { await model.refresh() } }, busy: model.busy))))
        }
        if model.claudeInstalled {
            cards.append((cardKey("claude", ClaudeStore.id), AnyView(ClaudeAccountCard(snapshot: model.claudeSnapshot, palette: palette,
                            onRefresh: { Task { await model.refresh() } }, busy: model.busy))))
        }
        let wanted = CardOrder.sorted(cards.map(\.key), by: cardOrderModel.keys)
        return wanted.compactMap { key in cards.first { $0.key == key } }
    }
    /// Moves one card by one slot (negative = up) and persists the new order.
    func moveCard(_ key: String, by offset: Int) {
        var keys = orderedCards.map(\.key)
        guard let index = keys.firstIndex(of: key) else { return }
        let target = index + offset
        guard keys.indices.contains(target), target != index else { return }
        keys.swapAt(index, target)
        withAnimation(.snappy(duration: 0.2)) { cardOrderModel.keys = keys }
        CardOrder.save(keys)
    }
    /// Moves one card to the bottom of the list.
    func moveCardToEnd(_ key: String) {
        var keys = orderedCards.map(\.key)
        guard let index = keys.firstIndex(of: key), index != keys.count - 1 else { return }
        let item = keys.remove(at: index)
        keys.append(item)
        withAnimation(.snappy(duration: 0.2)) { cardOrderModel.keys = keys }
        CardOrder.save(keys)
    }
    var body: some View {
        // System TabView: on iOS 26 the bar *is* Liquid Glass (refracting capsule, system-managed
        // hit testing), on older systems it is the standard bar. The hand-rolled capsule this
        // replaced drew its glass around the buttons — it looked right but swallowed taps.
        TabView(selection: $tab) {
            page(list: true) { statusSections }
                .tabItem { Label(AppTab.status.title, systemImage: AppTab.status.systemImage) }
                .tag(AppTab.status)
            page { settingsSections }
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage) }
                .tag(AppTab.settings)
        }
        .preferredColorScheme(theme == .system ? nil : (theme == .light ? .light : .dark))
        .alert("允许独立刷新及共享组风险", isPresented: $confirmWidgetRisk) {
            Button("取消", role: .cancel) {}
            Button("知悉风险，开启独立刷新") { setWidgetConsent(true) }
        } message: {
            Text("实测组：\(SharedStorage.diagnostics.observedDefaultGroup ?? "未知")。购买证书下，被授权访问同一组的其他 App 可能读取或修改所有账号令牌；service 名称不提供安全隔离。已有默认令牌可能已在此组。本开关不迁移或复制令牌，只允许组件用精确验证组访问所选账号。关闭保留账号并停止新请求，但无法撤回已经发送的请求或泄露的令牌。iOS 仅接受约每 15 分钟刷新请求，不保证时刻；负一屏出现不能强制联网。")
        }
        .alert("确认钥匙串安全边界", isPresented: $confirmKeychainRisk) {
            Button("取消", role: .cancel) {}
            Button("知悉风险，继续登录") { model.login() }
        } message: {
            Text("当前签名默认组：\(SharedStorage.diagnostics.observedDefaultGroup ?? "未知")。购买证书可能让同组其他 App 读取或修改本 App 保存的令牌，private 服务名不能隔离权限。继续只授权在现有默认钥匙串保存本次登录，不授权共享迁移或组件独立刷新。若不接受，请取消；已有令牌的暴露不能被此提示撤销。")
        }
        .refreshable { if model.signedIn { await model.refresh() } }
        .task {
            model.reloadAccounts()
            if model.signedIn { await model.refresh() }
        }
        .onOpenURL { url in if url.scheme == "codexusage" && model.signedIn { Task { await model.refresh() } } }
        .onChange(of: scenePhase) { _, phase in if phase == .active && model.signedIn && !model.signingIn { Task { await model.refresh() } } }
    }
    /// One tab page: the shared title bar plus the scrolling section stack. The system tab bar
    /// supplies its own bottom inset, so the content only needs a small tail pad.
    @ViewBuilder func page<C: View>(list: Bool = false, @ViewBuilder content: () -> C) -> some View {
        ZStack(alignment: .top) {
            palette.background.ignoresSafeArea()
            VStack(spacing: 0) {
                navigationBar
                if list {
                    // The status page is a real List so reordering can use the system's own
                    // `.onMove` effect (edit mode is toggled from the navigation bar).
                    List { content() }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .environment(\.editMode, $editMode)
                } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        content()
                        if let message = model.message { Text(message).font(.callout).foregroundStyle(palette.danger).accessibilityIdentifier("errorMessage") }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                }
            }
        }
    }
    /// Centred App title (this project's own name) with the one meaningful trailing control.
    var navigationBar: some View {
        ZStack {
            Text("Codex 用量").font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.primary)
            HStack {
                Spacer()
                if tab == .status {
                    Button(editMode == .active ? "完成" : "排序") {
                        withAnimation { editMode = editMode == .active ? .inactive : .active }
                    }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.primary)
                    .padding(.trailing, 4)
                }
                Button { Task { await model.refresh() } } label: {
                    Group {
                        if model.busy { ProgressView().tint(palette.primary) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.primary) }
                    }
                    .frame(width: 36, height: 36)
                    .background(palette.capsule, in: Circle())
                }.buttonStyle(.plain).disabled(model.busy || !model.signedIn).accessibilityLabel("刷新额度")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }
    // MARK: - 状态
    @ViewBuilder var statusSections: some View {
        // Rows carry the card look; the drag itself is the system's (`.onMove`), which is only
        // offered while the list is in edit mode.
        ForEach(orderedCards, id: \.key) { card in
            card.view
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .contextMenu {
                    Button { moveCard(card.key, by: -1) } label: { Label("上移", systemImage: "arrow.up") }
                    Button { moveCard(card.key, by: 1) } label: { Label("下移", systemImage: "arrow.down") }
                    Button { moveCardToEnd(card.key) } label: { Label("移到最后", systemImage: "arrow.down.to.line") }
                }
        }
        .onMove { source, destination in
            guard let from = source.first else { return }
            cardOrderModel.set(CardOrder.move(from, to: destination, in: orderedCards.map(\.key)))
        }
        if model.accounts.isEmpty && model.deepSeekIDs.isEmpty && !model.antigravityInstalled {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 42)).foregroundStyle(palette.primary).padding(.top, 24)
                Text("在 iPhone 上直接查看额度").font(.title2.bold()).foregroundStyle(palette.primary)
                Text("使用 ChatGPT 设备代码登录，无需 Mac 或代理服务。令牌仅存储在本机钥匙串。此 App 非 OpenAI 官方产品，使用非公开接口，可能随时失效。")
                    .foregroundStyle(palette.secondary)
            }.padding(.vertical, 4)
        }
        Text("如何添加小组件").font(.system(size: 15)).foregroundStyle(palette.secondary)
            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 2)
        if SharedStorage.cacheSharingAvailable {
            Text("长按桌面组件编辑左右账号").font(.system(size: 12)).foregroundStyle(palette.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        loginCard
        // Claude sign-in belongs next to the ChatGPT (GPT) device-code login on the status page —
        // it is an account login, not a setting, and hiding it under 设置 made it look absent.
        ClaudePanel(model: model, palette: palette)
        footerCard
    }
    func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { value in
            if value { expanded.insert(id) } else { expanded.remove(id) }
        })
    }
    var loginCard: some View {
        AppCard(title: "ChatGPT 账号", caption: model.signedIn ? "已在本机保存授权" : "尚未登录", systemImage: "person.crop.circle", palette: palette) {
            VStack(alignment: .leading, spacing: 14) {
                if let code = model.code {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("设备代码（15 分钟有效）").font(.headline).foregroundStyle(palette.primary)
                        Text(code.userCode).font(.system(.largeTitle, design: .monospaced).bold()).foregroundStyle(palette.primary).textSelection(.enabled)
                        ShareLink(item: code.userCode) { Label("复制或分享代码", systemImage: "square.and.arrow.up") }
                        Link("打开 OpenAI 验证页面", destination: AuthAPI.verificationURL).buttonStyle(.borderedProminent)
                        Text("仅输入你在此 App 主动申请的代码。添加第二个账号时，请在官方验证页面退出或切换到另一个账号，再授权。必要时在 ChatGPT 设置 → 安全中启用设备代码登录。验证后返回此 App 等待完成。").font(.footnote).foregroundStyle(palette.secondary)
                        ProgressView("等待授权…").tint(palette.primary)
                    }.padding(14).background(palette.tile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                if model.signingIn { Button("取消登录", role: .cancel) { model.cancelLogin() } }
                else {
                    Group {
                        if #available(iOS 26.0, *) {
                            Button(model.signedIn ? "添加账号 / 重新授权" : "使用 ChatGPT 登录") { confirmKeychainRisk = true }.buttonStyle(.glassProminent)
                        } else {
                            Button(model.signedIn ? "添加账号 / 重新授权" : "使用 ChatGPT 登录") { confirmKeychainRisk = true }.buttonStyle(.borderedProminent).padding(6).background(.regularMaterial, in: Capsule())
                        }
                    }.disabled(model.busy)
                }
            }
        }
    }
    var footerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !SharedStorage.sharingAvailable {
                Text(SharedStorage.cacheSharingAvailable ? "缓存共享模式：组件不能自行联网刷新，需打开 App 更新。令牌保持原钥匙串位置；购买证书的默认组可能与其他 App 共用，并非 App 私有安全边界。" : "App 私有模式：共享容器不可用，组件无法读取额度。请查看下方诊断。")
                    .font(.footnote).foregroundStyle(palette.secondary)
            }
            Text("每个账号独立显示，不合并额度。账号名称取自已授权的登录身份（id_token 只读声明）与接口返回的套餐，仅用于显示、不用于鉴权；缺少身份时显示「未命名账号」，缺少套餐时省略后缀，绝不推测。小号显示所选左列，中号显示两个所选账号；默认显示遮蔽邮箱。小组件由 iOS 决定刷新时机；请求约每 15 分钟更新，不保证准时；切换负一屏没有可强制联网的公开回调。点击组件内刷新按钮仅在共享授权成功后可用；仅缓存时请打开 App 刷新。未提供的额度窗口显示 —。")
                .font(.footnote).foregroundStyle(palette.secondary)
        }.padding(.horizontal, 4)
    }
    // MARK: - 设置
    /// Recomputed on every render so the card shows the current authorization, not the state when
    /// the page was first built.
    var refreshAuthorization: WidgetRefreshAuthorization { DashboardStore.refreshAuthorization() }
    @ViewBuilder var settingsSections: some View {
        AppCard(title: "组件刷新", caption: "默认关闭，先用握手确认共享组", systemImage: "arrow.triangle.2.circlepath", palette: palette) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("允许组件独立联网刷新", isOn: Binding(get: { widgetConsentEnabled }, set: { enabled in
                    if enabled { confirmWidgetRisk = true } else { setWidgetConsent(false) }
                })).tint(palette.accent)
                    // Refuse the tap only when neither path can authorize a real probed group, so
                    // the switch never sits permanently dead with no way forward.
                    .disabled(!widgetConsentEnabled && !SharedStorage.canEnableWidgetRefreshConsent && !SharedStorage.canForceWidgetRefreshConsent)
                Text(widgetConsentEnabled ? (SharedStorage.widgetCanRefresh ? "独立刷新已启用：右上角按钮不打开 App，直接刷新所选账号。" : "已记录同意，但当前握手、钥匙串或所选账号路由不可用；组件安全退回缓存。") : "默认关闭：组件右上角仍有一个控制，但那是「打开 App 刷新」（箭头图标），不会假装在组件内刷新。开启并知悉共享组风险后，它才会变成真正的组件内刷新。")
                    .font(.footnote).foregroundStyle(palette.secondary)
                if let consent = SharedStorage.consent, consent.forced == true {
                    Text("当前是「未完成跨进程验证」的强制授权：组件会用实测组真实发起刷新。如果这次重签没有把同一个 keychain-access-groups 同时给 App 和扩展，组件会读不到凭据，那时它显示「刷新失败 · 保留缓存」，不会编造数字——遇到这种显示说明是签名权限的问题，而不是额度接口的问题。")
                        .font(.footnote).foregroundStyle(palette.warning)
                }
                Text(refreshAuthorization.text)
                    .font(.caption.monospaced()).foregroundStyle(palette.secondary).textSelection(.enabled)
                if !widgetConsentEnabled {
                    if SharedStorage.canEnableWidgetRefreshConsent {
                        Text("可以开启：握手已确认，打开上面的开关并确认风险提示即可。").font(.footnote).foregroundStyle(palette.secondary)
                    } else if SharedStorage.canForceWidgetRefreshConsent {
                        Text("可以直接开启：本机有可用的实测 keychain 组，只是跨进程握手没走完（它要求组件在 App 运行时渲染一次并写回，组件没及时重渲染就走不完）。打开开关并确认风险后，会记录为「未完成跨进程验证」的强制授权；组件随后会真实尝试刷新，失败时保留缓存并说明原因。")
                            .font(.footnote).foregroundStyle(palette.secondary)
                        Button("开始非敏感跨进程验证（可选）") {
                            do { try SharedStorage.startHandshake(); handshakeStatus = SharedStorage.handshakeText
                                 widgetConsentEnabled = SharedStorage.consent != nil
                                 WidgetCenter.shared.reloadAllTimelines() }
                            catch { handshakeStatus = error.localizedDescription }
                        }.font(.footnote)
                    } else {
                        Text("下一步：" + SharedStorage.widgetConsentBlockerText)
                            .font(.footnote).foregroundStyle(palette.warning)
                        Button("开始非敏感跨进程验证") {
                            do { try SharedStorage.startHandshake(); handshakeStatus = SharedStorage.handshakeText
                                 widgetConsentEnabled = SharedStorage.consent != nil
                                 WidgetCenter.shared.reloadAllTimelines() }
                            catch { handshakeStatus = error.localizedDescription }
                        }.font(.footnote)
                        Text("顺序：1) 点这里开始握手；2) 回桌面让组件渲染一次（它会读取随机挑战并写回）；3) 回到 App 点「检查握手结果」；4) 打开上面的开关。重签时 App 与扩展必须是同一张证书、同一份 profile，并且都带同一个 App Group 与 keychain-access-groups —— 缺任意一项，握手都无法完成，组件会一直停在「打开 App 刷新」。")
                            .font(.footnote).foregroundStyle(palette.secondary)
                    }
                }
            }
        }
        AppCard(title: "外观", caption: "App 与小组件共用同一主题", systemImage: "circle.lefthalf.filled", palette: palette) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("主题", selection: Binding(get: { theme }, set: { setTheme($0) })) {
                    ForEach(ThemePreference.allCases, id: \.self) { value in Text(value.displayName).tag(value) }
                }.pickerStyle(.segmented)
                Text(theme == .system ? "跟随系统：App 与小组件随 iOS 外观切换。" : "已固定为\(theme.displayName)：App 与小组件使用同一套配色，不随系统切换。").font(.footnote).foregroundStyle(palette.secondary)
            }
        }
        AppCard(title: "隐私", caption: "邮箱遮蔽与共享容器", systemImage: "lock", palette: palette) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("在小组件中显示完整邮箱", isOn: Binding(get: { showFullInWidget }, set: { enabled in setFullInWidget(enabled) })).tint(palette.accent)
                Text(showFullInWidget ? "已开启：完整邮箱（含套餐，如 alex@example.com · Plus）会写入与其他同组 App 共享的容器，购买证书下这些 App 可读取该显示字符串。登录令牌始终不写入共享容器。" : "默认关闭：小组件只显示遮蔽账号名（如 ale***@example.com · Plus），完整邮箱不会写入共享容器。App 内仍显示完整邮箱。开启即接受同组其他 App 可读取该字符串。")
                    .font(.footnote).foregroundStyle(palette.secondary)
            }
        }
        AppCard(title: "共享诊断", caption: "握手、容器与组件状态", systemImage: "stethoscope", palette: palette) {
            VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup("共享诊断（不含令牌）") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(SharedStorage.diagnostics.text)
                        Text(SharedStorage.widgetDiagnosticText)
                        Text(handshakeStatus)
                        Button("开始非敏感跨进程验证") {
                            do { try SharedStorage.startHandshake(); handshakeStatus = SharedStorage.handshakeText; widgetConsentEnabled = SharedStorage.consent != nil; WidgetCenter.shared.reloadAllTimelines() }
                            catch { handshakeStatus = error.localizedDescription }
                        }
                        Button("检查握手结果") { handshakeStatus = SharedStorage.handshakeText; model.reloadAccounts() }
                        Text("安全选择：开关默认关闭。开启前须当前同组握手成功；只按实测精确组访问原有令牌，不迁移、不复制。关闭仅停止新组件请求，保留全部账号及令牌；已发出的请求无法收回，已完成的令牌轮换仍需安全保存。同组其他 App 可能读取或修改令牌；已泄露令牌不能靠关闭收回。重新开始握手会关闭授权。")
                    }.font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(palette.secondary)
                }.tint(palette.secondary)
            }
        }
        DeepSeekPanel()
        AntigravityPanel(model: model, palette: palette)
    }
}

/// Holds the card order. A reference type on purpose: the drop delegate is built long before the
/// drag starts, so a value copy would keep re-reading a stale array.
final class CardOrderModel: ObservableObject {
    @Published var keys: [String]
    init(keys: [String]) { self.keys = keys }
    func move(_ source: String, before target: String) {
        keys = CardOrder.sorted(CardOrder.move(source, before: target, in: keys), by: keys)
        CardOrder.save(keys)
    }
    func set(_ order: [String]) { keys = order; CardOrder.save(order) }
}

/// One Codex account card: header, weekly row, segmented meter, relative reset and — when
/// expanded — the label/value table. Only real fields are drawn; anything missing shows —.
struct AccountCard: View {
    let id: String
    let title: String
    let systemImage: String
    let caption: String
    let snapshot: UsageSnapshot?
    @Binding var expanded: Bool
    let canSelectWidget: Bool
    var palette: AppPalette
    let onRefresh: () -> Void
    let onSelectWidget: () -> Void
    let onRemove: () -> Void
    let slotValue: String
    var weekly: UsageWindow? { snapshot?.usage.rateLimit?.secondaryWindow }
    var session: UsageWindow? { snapshot?.usage.rateLimit?.primaryWindow }
    var credits: UsageCredits? { snapshot?.usage.credits }
    var updated: String {
        guard let snapshot else { return "—" }
        return RelativeTime.stamp(snapshot.updatedAt) + (snapshot.isStale() ? " · 数据已过期" : "")
    }
    var body: some View {
        AppCard(title: title, caption: caption, systemImage: systemImage, palette: palette, expanded: $expanded,
                menu: AnyView(Menu {
                    Button("刷新此账号", action: onRefresh)
                    if canSelectWidget { Button("设为小组件左列账号", action: onSelectWidget) }
                    Button("移除账号", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.tertiary).frame(width: 28, height: 28)
                }),
                mark: AnyView(Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(palette.primary)),
                ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("每周").font(.system(size: 15)).foregroundStyle(palette.secondary)
                    Spacer(minLength: 8)
                    Text(percent(weekly?.remaining)).font(.system(size: 16, weight: .semibold)).monospacedDigit().foregroundStyle(palette.primary)
                }
                DashMeter(remainingPercent: weekly?.remaining, palette: palette)
                Text(RelativeTime.text(weekly?.resetDate)).font(.system(size: 13)).monospacedDigit().foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if expanded {
                    Rectangle().fill(palette.divider).frame(height: 1).padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 0) {
                        AppRow(label: "本机独立授权账号", value: slotValue, palette: palette)
                        if let plan = AccountLabel.plan(snapshot?.usage.planType) { AppRow(label: "套餐", value: plan, palette: palette) }
                        AppRow(label: "5 小时额度", value: percent(session?.remaining), palette: palette)
                        AppRow(label: "会话重置", value: RelativeTime.text(session?.resetDate), palette: palette)
                        AppRow(label: "每周", value: percent(weekly?.remaining), palette: palette)
                        AppRow(label: "周重置", value: RelativeTime.text(weekly?.resetDate), palette: palette)
                        if let credits {
                            if credits.balance != nil { AppRow(label: "额度", value: Money.text(credits.balance, currency: credits.currency), palette: palette) }
                            if let unlimited = credits.unlimited { AppRow(label: "无限额度", value: unlimited ? "是" : "否", palette: palette) }
                        }
                        if let count = snapshot?.usage.rateLimitResetCredits?.availableCount { AppRow(label: "重置额度", value: String(count), palette: palette) }
                        AppRow(label: "更新时间", value: updated, palette: palette)
                    }
                }
            }
        }
    }
    func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "—" }
}

/// One DeepSeek account card: the same card visual, real currency amounts only — a balance has
/// no denominator, so this card never shows a percentage and never draws the meter.
struct DeepSeekAccountCard: View {
    let index: Int
    let snapshot: DeepSeekSnapshot?
    var palette: AppPalette
    let onRefresh: () -> Void
    let busy: Bool
    var info: DeepSeekBalance.BalanceInfo? { snapshot?.balance.balanceInfos.first }
    var body: some View {
        AppCard(title: "DeepSeek", caption: "仅 API 平台余额，不是聊天订阅额度", systemImage: "water.waves", palette: palette,
                menu: AnyView(Menu {
                    Button("刷新此账号", action: onRefresh).disabled(busy)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.tertiary).frame(width: 28, height: 28)
                }),
                mark: AnyView(DeepSeekWhale().fill(palette.primary).frame(width: 26, height: 17)),
                ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("总余额").font(.system(size: 15)).foregroundStyle(palette.secondary)
                    Spacer(minLength: 8)
                    Text(Money.text(info?.total, currency: info?.currency))
                        .font(.system(size: 22, weight: .bold)).monospacedDigit().foregroundStyle(palette.primary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                Rectangle().fill(palette.divider).frame(height: 1).padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 0) {
                    AppRow(label: "赠送", value: Money.text(info?.granted, currency: info?.currency), palette: palette)
                    AppRow(label: "充值", value: Money.text(info?.toppedUp, currency: info?.currency), palette: palette)
                    AppRow(label: "接口状态", value: snapshot == nil ? "暂无余额数据" : (snapshot!.balance.isAvailable ? "API 余额可用" : "API 余额不可用"), palette: palette)
                    AppRow(label: "更新时间", value: snapshot.map { RelativeTime.text($0.updatedAt) + ($0.isStale() ? " · 已过期" : "") } ?? "—", palette: palette)
                }
            }
        }
    }
}

/// Antigravity usage. Collapsed it shows the *pool* view — the two shared pools Antigravity really
/// meters, each as the tightest row inside it — plus the plan; expanding reveals every model row the
/// backend reports. Credit rows only appear when the API actually sends credits (Pro/Ultra tiers do
/// not), so nothing is shown as "—" just to fill a table.
struct AntigravityCard: View {
    let snapshot: AntigravitySnapshot?
    var palette: AppPalette
    let onRefresh: () -> Void
    let busy: Bool
    var body: some View {
        AppCard(title: "Antigravity", caption: "Google Antigravity 配额与额度",
                systemImage: "sparkles", palette: palette,
                menu: AnyView(Menu {
                    Button("刷新 Antigravity 用量", action: onRefresh).disabled(busy)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.tertiary).frame(width: 28, height: 28)
                })) {
            // 用户要求：Antigravity 只显示总用量 —— 不列池、不列模型，因此也没有可展开的明细。
            VStack(alignment: .leading, spacing: 12) {
                if let tightest = snapshot?.usage.tightestRemaining {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("总用量").font(.system(size: 15)).foregroundStyle(palette.secondary)
                            Spacer(minLength: 8)
                            Text("\(Int(tightest.rounded()))%")
                                .font(.system(size: 22, weight: .bold)).monospacedDigit().foregroundStyle(palette.primary)
                        }
                        DashMeter(remainingPercent: tightest, palette: palette)
                    }
                }
                Rectangle().fill(palette.divider).frame(height: 1).padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 0) {
                    AppRow(label: "套餐", value: snapshot?.usage.tier ?? "—", palette: palette)
                    AppRow(label: "更新时间", value: snapshot.map { RelativeTime.text($0.updatedAt) + ($0.isStale() ? " · 已过期" : "") } ?? "—", palette: palette)
                }
            }
        }
    }
}

@main
struct CodexUsageApp: App {
    @StateObject private var model = UsageModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
