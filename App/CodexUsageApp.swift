import SwiftUI
import WidgetKit

enum AppRefreshTarget: Hashable {
    case codex(String), deepSeek(String), antigravity, claude
    var accountID: String {
        switch self {
        case .codex(let id), .deepSeek(let id): return id
        case .antigravity: return AntigravityStore.account
        case .claude: return ClaudeStore.id
        }
    }
}

/// Never display arbitrary localized descriptions or storage details on an account card.
enum AppRefreshError {
    static func text(_ error: Error, for target: AppRefreshTarget) -> String {
        switch target {
        case .codex:
            if let error = error as? ServiceError {
                switch error {
                case .loginRequired, .expired: return "Codex 登录已失效，请重新授权"
                case .http(401), .http(403): return "Codex 登录已失效或未获授权，请重新授权"
                case .http(429): return "Codex 请求受限，请稍后重试或等待额度重置"
                case .busy: return "Codex 正在刷新，请稍后重试"
                case .storage: return "Codex 本机储存不可用，请解锁并检查权限"
                case .malformed: return "Codex 用量格式异常，保留缓存"
                case .http: return "Codex 服务暂不可用，保留缓存"
                }
            }
            return "Codex 网络连接失败，保留缓存"
        case .deepSeek: return (error as? DeepSeekError)?.localizedDescription ?? "DeepSeek 刷新失败，保留缓存"
        case .antigravity: return (error as? AntigravityError)?.localizedDescription ?? "Antigravity 刷新失败，保留缓存"
        case .claude: return (error as? ClaudeFailure)?.localizedDescription ?? "Claude 刷新失败，保留缓存"
        }
    }
}

/// Inject only the network boundary; production still uses the existing leased services.
struct AppRefreshFetchers {
    var codex: @Sendable (String) async throws -> UsageSnapshot = { try await UsageService.shared.refresh(account: $0) }
    var deepSeek: @Sendable (String) async throws -> DeepSeekSnapshot = { try await DeepSeekService.shared.refresh(id: $0, widget: false) }
    var antigravity: @Sendable () async throws -> AntigravitySnapshot = { try await AntigravityService.shared.refresh(widget: false) }
    var claude: @Sendable () async throws -> ClaudeSnapshot = { try await ClaudeService.shared.refresh(widget: false) }
}

@MainActor final class UsageModel: ObservableObject {
    @Published var deepSeekIDs: [String] = []
    @Published var balances: [String: DeepSeekSnapshot] = [:]
    /// DeepSeek accounts whose last refresh failed (from the persisted attempt record), loaded with
    /// the balances so no view reads the file while rendering.
    @Published var deepSeekFailed: Set<String> = []
    @Published var accounts: [String] = []
    @Published var snapshots: [String: UsageSnapshot] = [:]
    @Published var emails: [String: String] = [:]
    @Published var selectedWidget: String?
    // Antigravity lives in the App's own state and cached snapshot; the widget reads the same
    // snapshot through DashboardStore.
    @Published var antigravity: AntigravitySnapshot?
    @Published var antigravityInstalled = false
    @Published var claudeInstalled = false
    @Published var claudeSnapshot: ClaudeSnapshot?
    @Published var refreshErrors: [AppRefreshTarget: String] = [:]
    private let fetchers: AppRefreshFetchers
    private var refreshFailureDates: [AppRefreshTarget: Date] = [:]
    init(loadStoredAccounts: Bool = true, fetchers: AppRefreshFetchers = AppRefreshFetchers()) {
        self.fetchers = fetchers
        guard loadStoredAccounts else { return }
        reloadAccounts()
        // build 19 and earlier stored a scraped claude.ai session cookie. Only that legacy
        // Keychain item is deleted (the current OAuth cache and backoff record are kept); the
        // user is told once, when an old item was actually found and removed.
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
        reloadRefreshAttempts(targets: nextAccounts.map { .codex($0) } + nextDeepSeekIDs.map { .deepSeek($0) }
                              + (nextAntigravityInstalled ? [.antigravity] : []) + (nextClaudeInstalled ? [.claude] : []))
    }
    /// Load persisted feedback outside body; equal reloads emit no UI notifications.
    func reloadRefreshAttempts(targets: [AppRefreshTarget]) {
        let live = Set(targets)
        var next = refreshErrors.filter { live.contains($0.key) }
        for target in targets {
            let attempt = WidgetRefreshAttempt.load(target.accountID)
            if attempt.failed {
                if next[target] == nil { next[target] = "刷新失败，保留缓存；请重试或检查授权" }
            } else if let completed = attempt.completedAt,
                      completed >= (refreshFailureDates[target] ?? .distantPast) {
                next[target] = nil
                refreshFailureDates[target] = nil
            }
        }
        let failedWallets = Set(next.keys.compactMap { target -> String? in
            if case .deepSeek(let id) = target { return id }; return nil
        })
        refreshFailureDates = refreshFailureDates.filter { live.contains($0.key) }
        if refreshErrors != next { refreshErrors = next }
        if deepSeekFailed != failedWallets { deepSeekFailed = failedWallets }
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
    @Published var signedIn = false
    private var loginTask: Task<Void, Never>?
    private var generation = UUID()
    /// True only while a refresh the user asked for (button / pull) is running; automatic refreshes
    /// on launch and foreground update the cards silently instead of spinning the title bar.
    @Published var spinning = false
    /// When the last full refresh finished; automatic refreshes within `autoRefreshInterval` are skipped.
    private var lastFullRefresh: Date?
    static let autoRefreshInterval: TimeInterval = 60
    /// Launch / foreground: show the cache at once and refresh in the background only when the
    /// last refresh is older than a minute.
    func autoRefresh() async {
        if let lastFullRefresh, Date().timeIntervalSince(lastFullRefresh) < Self.autoRefreshInterval { return }
        await refresh(userInitiated: false)
    }
    /// Every provider and account is fetched concurrently (build 28): the refresh now takes as long
    /// as the slowest service instead of the sum of all of them. Each result lands on its card as
    /// soon as it arrives; a failure keeps that card's cache.
    /// Returns false when another refresh was already running and this call fetched nothing.
    @discardableResult
    func refresh(account: String? = nil, target: AppRefreshTarget? = nil, userInitiated: Bool = true) async -> Bool {
        // A tap during a silent refresh just shows the spinner until that refresh lands.
        guard !busy else { if userInitiated { spinning = true }; return false }
        busy = true
        if userInitiated { spinning = true }
        // Ask iOS for time to finish if the App is backgrounded mid-refresh, so a token exchange
        // the server has already answered is written to the keychain instead of being lost.
        let background = UIApplication.shared.beginBackgroundTask(withName: "CodexUsage.refresh")
        defer {
            busy = false; spinning = false
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
        enum Result { case codex(String, UsageSnapshot), deepSeek(String, DeepSeekSnapshot), antigravity(AntigravitySnapshot),
                      claude(ClaudeSnapshot), failed(AppRefreshTarget, String), cancelled }
        let selection = target ?? account.map { AppRefreshTarget.codex($0) }
        let full = selection == nil
        let codexIDs: [String]
        let deepSeek: [String]
        if case .codex(let id)? = selection { codexIDs = [id] } else { codexIDs = full ? accounts : [] }
        if case .deepSeek(let id)? = selection { deepSeek = [id] } else { deepSeek = full ? deepSeekIDs : [] }
        let withAntigravity = selection == .antigravity || (full && antigravityInstalled)
        let withClaude = selection == .claude || (full && claudeInstalled)
        let fetchers = self.fetchers
        await withTaskGroup(of: Result.self) { group in
            for id in codexIDs {
                group.addTask {
                    do { return .codex(id, try await fetchers.codex(id)) }
                    catch is CancellationError { return .cancelled }
                    catch { return .failed(.codex(id), AppRefreshError.text(error, for: .codex(id))) }
                }
            }
            for id in deepSeek {
                group.addTask {
                    do { return .deepSeek(id, try await fetchers.deepSeek(id)) }
                    catch is CancellationError { return .cancelled }
                    catch { return .failed(.deepSeek(id), AppRefreshError.text(error, for: .deepSeek(id))) }
                }
            }
            if withAntigravity {
                group.addTask {
                    do { return .antigravity(try await fetchers.antigravity()) }
                    catch is CancellationError { return .cancelled }
                    catch { return .failed(.antigravity, AppRefreshError.text(error, for: .antigravity)) }
                }
            }
            if withClaude {
                group.addTask {
                    do { return .claude(try await fetchers.claude()) }
                    catch is CancellationError { return .cancelled }
                    catch { return .failed(.claude, AppRefreshError.text(error, for: .claude)) }
                }
            }
            for await result in group {
                switch result {
                case let .codex(id, value): snapshots[id] = value; refreshErrors[.codex(id)] = nil
                case let .deepSeek(id, value): balances[id] = value; refreshErrors[.deepSeek(id)] = nil; deepSeekFailed.remove(id)
                case let .antigravity(value): antigravity = value; refreshErrors[.antigravity] = nil
                case let .claude(value): claudeSnapshot = value; refreshErrors[.claude] = nil
                case let .failed(target, text):
                    refreshErrors[target] = text
                    refreshFailureDates[target] = Date()
                    if case .deepSeek(let id) = target { deepSeekFailed.insert(id) }
                case .cancelled: break
                }
            }
        }
        if full { lastFullRefresh = Date() }
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }
    /// Refreshes one DeepSeek account (the 设置 panel's per-account button). Shares `busy` with the
    /// full refresh, so the two can never race on the same key. When skipped because another
    /// refresh is running, report that instead of returning the card's previous error.
    func refreshDeepSeek(_ id: String) async -> Error? {
        guard await refresh(target: .deepSeek(id)) else {
            return NSError(domain: "CodexUsage.AppRefresh", code: 2, userInfo: [NSLocalizedDescriptionKey: "正在刷新，请稍后重试"])
        }
        return refreshErrors[.deepSeek(id)].map { NSError(domain: "CodexUsage.AppRefresh", code: 1, userInfo: [NSLocalizedDescriptionKey: $0]) }
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
    // The card "⋯" menus remove credentials here (build 27 moved these out of the sign-in panels).
    func removeDeepSeek(_ id: String) async {
        do { try await DeepSeekService.shared.remove(id); reloadAccounts(); WidgetCenter.shared.reloadAllTimelines() }
        catch { message = "移除失败，请解锁后重试" }
    }
    func removeAntigravity() async {
        do { try await AntigravityService.shared.remove(); try? DashboardStore.publish(); reloadAccounts(); WidgetCenter.shared.reloadAllTimelines() }
        catch { message = error.localizedDescription }
    }
    func removeClaude() async {
        do { try await ClaudeService.shared.remove(); try DashboardStore.publish(); reloadAccounts(); WidgetCenter.shared.reloadAllTimelines() }
        catch { message = (error as? ClaudeFailure)?.localizedDescription ?? "移除失败，请检查本机储存" }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var accessibilityContext: String? = nil
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
                    Text(title).scaledFont(20, weight: .bold, relativeTo: .title3).foregroundStyle(palette.primary).lineLimit(1)
                    if let caption {
                        Text(caption).scaledFont(12, relativeTo: .caption).foregroundStyle(palette.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                if let menu { menu }
                if let expanded {
                    Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { expanded.wrappedValue.toggle() } } label: {
                        Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.tertiary)
                            .frame(width: 28, height: 28)
                            .frame(width: 44, height: 44).contentShape(Rectangle()).padding(-8)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(accessibilityContext ?? [title, caption].compactMap { $0 }.joined(separator: " · "))，\(expanded.wrappedValue ? "折叠详情" : "展开详情")")
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
    /// Per-service colours (build 27); nil keeps the palette's original blue.
    var litColor: Color? = nil
    var restColor: Color? = nil
    /// 设置 › 用量显示: light the remaining share (default) or the used share.
    var display: UsageDisplay = .remaining
    var lit: Int { guard let shown = display.shown(remainingPercent) else { return 0 }; return min(dashes, max(0, Int((shown / 100 * Double(dashes)).rounded()))) }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<dashes, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.4, style: .continuous)
                    .fill(index < lit ? (litColor ?? palette.meterUsed) : (restColor ?? palette.meterRest))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
        .accessibilityLabel(display.accessibility(remainingPercent))
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
        .scaledFont(15, relativeTo: .subheadline)
        .padding(.vertical, 5)
    }
}

/// A fixed-size system font that still follows Dynamic Type: at the default text size it is exactly
/// `.system(size:weight:)` (build14's look), and it grows with the user's text-size setting.
private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    init(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }
    func body(content: Content) -> some View { content.font(.system(size: size, weight: weight)) }
}
extension View {
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, relativeTo: style))
    }
}

/// Everything the App shows about widget sharing, read in one pass off the main actor. Each field is
/// the same `SharedStorage` / `DashboardStore` value the views used to compute inline on every
/// render; defaults are the "not loaded yet" state (switch disabled, no warning flashed).
struct WidgetAuthState: Sendable {
    var sharingAvailable = true
    var consentRecorded = false
    var forcedConsent = false
    var canEnableConsent = false
    var canForceConsent = false
    var widgetCanRefresh = false
    var blockerText = ""
    var authorizationText = ""
    var widgetDiagnostics = ""
    var handshakeText = ""
    static func load() -> WidgetAuthState {
        let consent = SharedStorage.consent
        return WidgetAuthState(sharingAvailable: SharedStorage.sharingAvailable,
                               consentRecorded: consent != nil,
                               forcedConsent: consent?.forced == true,
                               canEnableConsent: SharedStorage.canEnableWidgetRefreshConsent,
                               canForceConsent: SharedStorage.canForceWidgetRefreshConsent,
                               widgetCanRefresh: SharedStorage.widgetCanRefresh,
                               blockerText: SharedStorage.widgetConsentBlockerText,
                               authorizationText: DashboardStore.refreshAuthorization().text,
                               widgetDiagnostics: SharedStorage.widgetDiagnosticText,
                               handshakeText: SharedStorage.handshakeText)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var tab: AppTab = .status
    @State private var expanded: Set<String> = []
    @State private var handshakeStatus = ""
    /// Keychain/file-backed sharing state, loaded in `.task` and after each action instead of on
    /// every render (the 设置 body used to hit the keychain several times per redraw).
    @State private var auth = WidgetAuthState()
    @State private var connect: ConnectEntry?
    @State private var confirmWidgetRisk = false
    @State private var widgetConsentEnabled = false
    @State private var showFullInWidget = SharedStorage.showFullAccountInWidget
    @State private var theme = ThemePreference.load()
    @State private var usageDisplay = UsageDisplay.load()
    @StateObject private var cardOrderModel = CardOrderModel(keys: CardOrder.load())
    @State private var editMode: EditMode = .inactive
    var palette: AppPalette { .resolve(scheme) }
    func setUsageDisplay(_ value: UsageDisplay) {
        do { try value.save() } catch { model.message = error.localizedDescription }
        usageDisplay = UsageDisplay.load()
        WidgetCenter.shared.reloadAllTimelines()
    }
    func setTheme(_ value: ThemePreference) {
        do { try value.save() } catch { model.message = error.localizedDescription }
        theme = ThemePreference.load()
        WidgetCenter.shared.reloadAllTimelines()
    }
    /// Re-reads the sharing state off the main actor. Called on launch, on foreground and after
    /// every action that can change consent, handshake or accounts.
    func reloadAuth() async {
        let next = await Task.detached(priority: .userInitiated) { WidgetAuthState.load() }.value
        auth = next
        widgetConsentEnabled = next.consentRecorded
        if handshakeStatus.isEmpty { handshakeStatus = next.handshakeText }
    }
    func setWidgetConsent(_ enabled: Bool) {
        guard enabled else {
            do { try SharedStorage.setWidgetRefreshConsent(false); model.reloadAccounts() }
            catch { model.message = error.localizedDescription }
            widgetConsentEnabled = SharedStorage.consent != nil
            WidgetCenter.shared.reloadAllTimelines()
            Task { await reloadAuth() }
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
        Task { await reloadAuth() }
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
                        caption: model.label(for: id),
                        snapshot: model.snapshots[id],
                        expanded: expandedBinding(id),
                        canSelectWidget: SharedStorage.cacheSharingAvailable,
                        palette: palette,
                        onRefresh: { Task { await model.refresh(account: id) } },
                        onSelectWidget: { model.selectWidget(id) },
                        onReauthorize: { connect = .service(.codex) },
                        onRemove: { Task { await model.logout(account: id) } },
                        slotValue: slotValue(id), refreshError: model.refreshErrors[.codex(id)], busy: model.busy))))
        }
        for id in model.deepSeekIDs {
            cards.append((cardKey("deepseek", id), AnyView(DeepSeekAccountCard(snapshot: model.balances[id],
                                expanded: expandedBinding("deepseek:" + id), palette: palette,
                                onRefresh: { Task { _ = await model.refreshDeepSeek(id) } },
                                onUpdateKey: { connect = .service(.deepseek) },
                                onRemove: { Task { await model.removeDeepSeek(id) } },
                                busy: model.busy, refreshError: model.refreshErrors[.deepSeek(id)],
                                accountContext: "DeepSeek · 账号 \((model.deepSeekIDs.firstIndex(of: id) ?? 0) + 1)"))))
        }
        if model.antigravityInstalled {
            cards.append((cardKey("antigravity", nil), AnyView(AntigravityCard(snapshot: model.antigravity,
                            expanded: expandedBinding("antigravity"), palette: palette,
                            onRefresh: { Task { await model.refresh(target: .antigravity) } },
                            onReauthorize: { connect = .service(.antigravity) },
                            onRemove: { Task { await model.removeAntigravity() } },
                            busy: model.busy, refreshError: model.refreshErrors[.antigravity]))))
        }
        if model.claudeInstalled {
            cards.append((cardKey("claude", ClaudeStore.id), AnyView(ClaudeAccountCard(snapshot: model.claudeSnapshot,
                            expanded: expandedBinding("claude"), palette: palette,
                            onRefresh: { Task { await model.refresh(target: .claude) } },
                            onReauthorize: { connect = .service(.claude) },
                            onRemove: { Task { await model.removeClaude() } },
                            busy: model.busy, refreshError: model.refreshErrors[.claude]))))
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
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { cardOrderModel.keys = keys }
        CardOrder.save(keys)
    }
    /// Moves one card to the bottom of the list.
    func moveCardToEnd(_ key: String) {
        var keys = orderedCards.map(\.key)
        guard let index = keys.firstIndex(of: key), index != keys.count - 1 else { return }
        let item = keys.remove(at: index)
        keys.append(item)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { cardOrderModel.keys = keys }
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
        .environment(\.usageDisplay, usageDisplay)
        .alert("允许独立刷新及共享组风险", isPresented: $confirmWidgetRisk) {
            Button("取消", role: .cancel) {}
            Button("知悉风险，开启独立刷新") { setWidgetConsent(true) }
        } message: {
            Text("实测组：\(SharedStorage.diagnostics.observedDefaultGroup ?? "未知")。购买证书下，被授权访问同一组的其他 App 可能读取或修改所有账号令牌；service 名称不提供安全隔离。已有默认令牌可能已在此组。本开关不迁移或复制令牌，只允许组件用精确验证组访问所选账号。关闭保留账号并停止新请求，但无法撤回已经发送的请求或泄露的令牌。iOS 仅接受约每 15 分钟刷新请求，不保证时刻；负一屏出现不能强制联网。")
        }
        .sheet(item: $connect) { entry in
            ConnectSheet(model: model, entry: entry)
                .preferredColorScheme(theme == .system ? nil : (theme == .light ? .light : .dark))
        }
        .refreshable { if model.signedIn { await model.refresh() } }
        .task {
            model.reloadAccounts()
            await reloadAuth()
            if model.signedIn { await model.autoRefresh() }
        }
        .onOpenURL { url in if url.scheme == "codexusage" && model.signedIn { Task { await model.refresh() } } }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await reloadAuth() }
            if model.signedIn && !model.signingIn { Task { await model.autoRefresh() } }
        }
        // Accounts added or removed change which rows the widget may refresh.
        .onChange(of: model.accounts) { _, _ in Task { await reloadAuth() } }
        .onChange(of: model.deepSeekIDs) { _, _ in Task { await reloadAuth() } }
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
            Text("Codex 用量").scaledFont(17, weight: .semibold, relativeTo: .headline).foregroundStyle(palette.primary)
            HStack {
                Spacer()
                if tab == .status && model.signedIn {
                    Button(editMode == .active ? "完成" : "排序") {
                        withAnimation(reduceMotion ? nil : .default) { editMode = editMode == .active ? .inactive : .active }
                    }
                    .scaledFont(15, weight: .semibold, relativeTo: .subheadline).foregroundStyle(palette.primary)
                    .frame(minHeight: 44).contentShape(Rectangle()).padding(.vertical, -4)
                    .padding(.trailing, 4)
                }
                if tab == .status {
                    Button { connect = .picker } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.primary)
                            .frame(width: 36, height: 36)
                            .background(palette.capsule, in: Circle())
                            .frame(width: 44, height: 44).contentShape(Rectangle()).padding(-4)
                    }.buttonStyle(.plain).accessibilityLabel("连接账号")
                }
                if model.signedIn {
                Button { Task { await model.refresh() } } label: {
                    Group {
                        if model.spinning { ProgressView().tint(palette.primary) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.primary) }
                    }
                    .frame(width: 36, height: 36)
                    .background(palette.capsule, in: Circle())
                    .frame(width: 44, height: 44).contentShape(Rectangle()).padding(-4)
                }.buttonStyle(.plain).disabled(model.spinning || !model.signedIn).accessibilityLabel("刷新额度")
                }
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
        // The status page is a List, so the ScrollView-only error line in `page` never reached it:
        // a failed refresh here used to look like nothing happened. Same text style as 设置.
        if let message = model.message {
            Text(message).font(.callout).foregroundStyle(palette.danger).accessibilityIdentifier("statusErrorMessage")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
        }
        if model.accounts.isEmpty && model.deepSeekIDs.isEmpty && !model.antigravityInstalled && !model.claudeInstalled {
            EmptyConnectView(palette: palette) { connect = .picker }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        } else {
        Text("如何添加小组件").scaledFont(15, relativeTo: .subheadline).foregroundStyle(palette.secondary)
            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 2)
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
        if SharedStorage.cacheSharingAvailable {
            Text("长按桌面组件编辑左右账号").scaledFont(12, relativeTo: .caption).foregroundStyle(palette.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        }
        // Every sign-in (ChatGPT, Claude, DeepSeek, Antigravity) now lives in 连接账号 (the "+"
        // button); the status page carries account cards only.
    }
    func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { value in
            if value { expanded.insert(id) } else { expanded.remove(id) }
        })
    }
    var footerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !auth.sharingAvailable {
                Text(SharedStorage.cacheSharingAvailable ? "缓存共享模式：组件不能自行联网刷新，需打开 App 更新。令牌保持原钥匙串位置；购买证书的默认组可能与其他 App 共用，并非 App 私有安全边界。" : "App 私有模式：共享容器不可用，组件无法读取额度。请查看下方诊断。")
                    .font(.footnote).foregroundStyle(palette.secondary)
            }
            Text("每个账号独立显示，不合并额度。账号名称取自已授权的登录身份（id_token 只读声明）与接口返回的套餐，仅用于显示、不用于鉴权；缺少身份时显示「未命名账号」，缺少套餐时省略后缀，绝不推测。小号显示所选左列，中号显示两个所选账号；默认显示遮蔽邮箱。小组件由 iOS 决定刷新时机；请求约每 15 分钟更新，不保证准时；切换负一屏没有可强制联网的公开回调。点击组件内刷新按钮仅在共享授权成功后可用；仅缓存时请打开 App 刷新。未提供的额度窗口显示 —。")
                .font(.footnote).foregroundStyle(palette.secondary)
        }.padding(.horizontal, 4)
    }
    // MARK: - 设置
    @ViewBuilder var settingsSections: some View {
        AppCard(title: "组件刷新", caption: "默认关闭，先用握手确认共享组", systemImage: "arrow.triangle.2.circlepath", palette: palette) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("允许组件独立联网刷新", isOn: Binding(get: { widgetConsentEnabled }, set: { enabled in
                    if enabled { confirmWidgetRisk = true } else { setWidgetConsent(false) }
                })).tint(palette.accent)
                    // Refuse the tap only when neither path can authorize a real probed group, so
                    // the switch never sits permanently dead with no way forward.
                    .disabled(!widgetConsentEnabled && !auth.canEnableConsent && !auth.canForceConsent)
                Text(widgetConsentEnabled ? (auth.widgetCanRefresh ? "独立刷新已启用：右上角按钮不打开 App，直接刷新所选账号。" : "已记录同意，但当前握手、钥匙串或所选账号路由不可用；组件安全退回缓存。") : "默认关闭：组件右上角仍有一个控制，但那是「打开 App 刷新」（箭头图标），不会假装在组件内刷新。开启并知悉共享组风险后，它才会变成真正的组件内刷新。")
                    .font(.footnote).foregroundStyle(palette.secondary)
                if auth.forcedConsent {
                    Text("当前是「未完成跨进程验证」的强制授权：组件会用实测组真实发起刷新。如果这次重签没有把同一个 keychain-access-groups 同时给 App 和扩展，组件会读不到凭据，那时它显示「刷新失败 · 保留缓存」，不会编造数字——遇到这种显示说明是签名权限的问题，而不是额度接口的问题。")
                        .font(.footnote).foregroundStyle(palette.warning)
                }
                Text(auth.authorizationText)
                    .font(.caption.monospaced()).foregroundStyle(palette.secondary).textSelection(.enabled)
                if !widgetConsentEnabled {
                    if auth.canEnableConsent {
                        Text("可以开启：握手已确认，打开上面的开关并确认风险提示即可。").font(.footnote).foregroundStyle(palette.secondary)
                    } else if auth.canForceConsent {
                        Text("可以直接开启：本机有可用的实测 keychain 组，只是跨进程握手没走完（它要求组件在 App 运行时渲染一次并写回，组件没及时重渲染就走不完）。打开开关并确认风险后，会记录为「未完成跨进程验证」的强制授权；组件随后会真实尝试刷新，失败时保留缓存并说明原因。")
                            .font(.footnote).foregroundStyle(palette.secondary)
                        Button("开始非敏感跨进程验证（可选）") {
                            do { try SharedStorage.startHandshake(); handshakeStatus = SharedStorage.handshakeText
                                 widgetConsentEnabled = SharedStorage.consent != nil
                                 WidgetCenter.shared.reloadAllTimelines(); Task { await reloadAuth() } }
                            catch { handshakeStatus = error.localizedDescription }
                        }.font(.footnote)
                    } else {
                        Text("下一步：" + auth.blockerText)
                            .font(.footnote).foregroundStyle(palette.warning)
                        Button("开始非敏感跨进程验证") {
                            do { try SharedStorage.startHandshake(); handshakeStatus = SharedStorage.handshakeText
                                 widgetConsentEnabled = SharedStorage.consent != nil
                                 WidgetCenter.shared.reloadAllTimelines(); Task { await reloadAuth() } }
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
                Divider().overlay(palette.divider)
                HStack {
                    Text("用量显示").scaledFont(15, relativeTo: .subheadline).foregroundStyle(palette.primary)
                    Spacer(minLength: 12)
                    Menu {
                        Picker("用量显示", selection: Binding(get: { usageDisplay }, set: { setUsageDisplay($0) })) {
                            ForEach(UsageDisplay.allCases, id: \.self) { value in Text(value.displayName).tag(value) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(usageDisplay.displayName)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                        }.scaledFont(15, relativeTo: .subheadline).foregroundStyle(palette.secondary)
                    }.accessibilityLabel("用量显示：\(usageDisplay.displayName)")
                }
                Text("百分比和用量条显示剩余还是已用；App 与小组件同步。剩余不足 20% 时仍会变红。").font(.footnote).foregroundStyle(palette.secondary)
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
                        Text(auth.widgetDiagnostics)
                        Text(handshakeStatus)
                        Button("开始非敏感跨进程验证") {
                            do { try SharedStorage.startHandshake(); handshakeStatus = SharedStorage.handshakeText; widgetConsentEnabled = SharedStorage.consent != nil; WidgetCenter.shared.reloadAllTimelines(); Task { await reloadAuth() } }
                            catch { handshakeStatus = error.localizedDescription }
                        }
                        Button("检查握手结果") { handshakeStatus = SharedStorage.handshakeText; model.reloadAccounts(); Task { await reloadAuth() } }
                        Text("安全选择：开关默认关闭。开启前须当前同组握手成功；只按实测精确组访问原有令牌，不迁移、不复制。关闭仅停止新组件请求，保留全部账号及令牌；已发出的请求无法收回，已完成的令牌轮换仍需安全保存。同组其他 App 可能读取或修改令牌；已泄露令牌不能靠关闭收回。重新开始握手会关闭授权。")
                    }.font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(palette.secondary)
                }.tint(palette.secondary)
            }
        }
        footerCard
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

/// The "⋯" menu every account card shares. Destructive and re-auth actions live here now that the
/// sign-in panels moved into 连接账号.
struct CardMenu<Items: View>: View {
    var palette: AppPalette
    var accountContext = "账号"
    @ViewBuilder var items: Items
    var body: some View {
        Menu { items } label: {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.tertiary).frame(width: 28, height: 28)
                .frame(width: 44, height: 44).contentShape(Rectangle()).padding(-8)
        }
        .accessibilityLabel("\(accountContext)，账号操作")
    }
}

/// Invisible on success; a failed card keeps its old data and exposes the actual cached timestamp.
struct CardRefreshFeedback: View {
    let error: String?
    let updatedAt: Date?
    let palette: AppPalette
    var busy = false
    let onRetry: () -> Void
    var body: some View {
        if let error {
            VStack(alignment: .leading, spacing: 4) {
                Text(error).font(.caption).foregroundStyle(palette.warning)
                Text(updatedAt.map { "缓存更新 " + RelativeTime.stamp($0) } ?? "暂无缓存数据")
                    .font(.caption).foregroundStyle(palette.secondary)
                Button("重试此账号", action: onRetry).font(.caption).disabled(busy)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
        }
    }
}

/// One quota window, expanded: label + remaining, the brand-coloured meter, then the countdown and
/// the absolute reset moment. Missing values stay "—" / "重置时间未知".
struct QuotaRow: View {
    let label: String
    let remaining: Double?
    let reset: Date?
    let brand: ServiceBrand
    var palette: AppPalette
    @Environment(\.colorScheme) private var scheme
    @Environment(\.usageDisplay) private var display
    var body: some View {
        let colors = MeterColors(brand: brand, remaining: remaining, palette: palette, dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).scaledFont(15, relativeTo: .subheadline).foregroundStyle(palette.secondary)
                Spacer(minLength: 8)
                Text(display.text(remaining)).scaledFont(16, weight: .semibold, relativeTo: .callout).monospacedDigit().foregroundStyle(palette.primary)
            }
            DashMeter(remainingPercent: remaining, palette: palette, litColor: colors.lit, restColor: colors.rest, display: display)
            ResetLine(date: reset, palette: palette).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// One Codex account card. Collapsed: header + the tighter of 5 小时 / 每周. Expanded: both windows
/// with countdowns, then the label/value table. Only real fields are drawn; anything missing shows —.
struct AccountCard: View {
    let id: String
    let title: String
    let caption: String
    let snapshot: UsageSnapshot?
    @Binding var expanded: Bool
    let canSelectWidget: Bool
    var palette: AppPalette
    let onRefresh: () -> Void
    let onSelectWidget: () -> Void
    let onReauthorize: () -> Void
    let onRemove: () -> Void
    let slotValue: String
    var refreshError: String? = nil
    var busy = false
    var weekly: UsageWindow? { snapshot?.usage.rateLimit?.secondaryWindow }
    var session: UsageWindow? { snapshot?.usage.rateLimit?.primaryWindow }
    var credits: UsageCredits? { snapshot?.usage.credits }
    var updated: String {
        guard let snapshot else { return "—" }
        return RelativeTime.stamp(snapshot.updatedAt) + (snapshot.isStale() ? " · 数据已过期" : "")
    }
    var summary: QuotaSummary.Window? {
        QuotaSummary.tightest([.init(label: "5 小时", remaining: session?.remaining, reset: session?.resetDate),
                               .init(label: "每周", remaining: weekly?.remaining, reset: weekly?.resetDate)])
    }
    var body: some View {
        AppCard(title: title, caption: caption, systemImage: "chevron.left.forwardslash.chevron.right", palette: palette, expanded: $expanded,
                menu: AnyView(CardMenu(palette: palette, accountContext: title + " · " + caption) {
                    Button("刷新此账号", action: onRefresh).disabled(busy)
                    if canSelectWidget { Button("设为小组件左列账号", action: onSelectWidget) }
                    Button("添加账号 / 重新授权", action: onReauthorize)
                    Button("移除账号", role: .destructive, action: onRemove)
                }),
                mark: AnyView(BrandMark(brand: .codex, palette: palette))) {
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    QuotaRow(label: "5 小时", remaining: session?.remaining, reset: session?.resetDate, brand: .codex, palette: palette)
                    QuotaRow(label: "每周", remaining: weekly?.remaining, reset: weekly?.resetDate, brand: .codex, palette: palette)
                    Rectangle().fill(palette.divider).frame(height: 1).padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 0) {
                        AppRow(label: "本机独立授权账号", value: slotValue, palette: palette)
                        if let plan = AccountLabel.plan(snapshot?.usage.planType) { AppRow(label: "套餐", value: plan, palette: palette) }
                        if let credits {
                            if credits.balance != nil { AppRow(label: "额度", value: Money.text(credits.balance, currency: credits.currency), palette: palette) }
                            if let unlimited = credits.unlimited { AppRow(label: "无限额度", value: unlimited ? "是" : "否", palette: palette) }
                        }
                        if let count = snapshot?.usage.rateLimitResetCredits?.availableCount { AppRow(label: "重置额度", value: String(count), palette: palette) }
                        AppRow(label: "更新时间", value: updated, palette: palette)
                    }
                }
            } else {
                SummaryLine(window: summary, brand: .codex, palette: palette)
            }
            CardRefreshFeedback(error: refreshError, updatedAt: snapshot?.updatedAt, palette: palette, busy: busy, onRetry: onRefresh)
        }
    }
}

/// One DeepSeek account card: real currency amounts only — a balance has no denominator and no
/// reset, so this card never shows a percentage, a meter or a countdown.
struct DeepSeekAccountCard: View {
    let snapshot: DeepSeekSnapshot?
    @Binding var expanded: Bool
    var palette: AppPalette
    let onRefresh: () -> Void
    let onUpdateKey: () -> Void
    let onRemove: () -> Void
    let busy: Bool
    var refreshError: String? = nil
    var accountContext = "DeepSeek 账号"
    var info: DeepSeekBalance.BalanceInfo? { snapshot?.balance.balanceInfos.first }
    var updated: String { snapshot.map { RelativeTime.text($0.updatedAt) + ($0.isStale() ? " · 已过期" : "") } ?? "—" }
    var body: some View {
        AppCard(title: "DeepSeek", caption: "API 平台余额 · 非聊天订阅", systemImage: "water.waves", palette: palette, accessibilityContext: accountContext, expanded: $expanded,
                menu: AnyView(CardMenu(palette: palette, accountContext: accountContext) {
                    Button("刷新此账号", action: onRefresh).disabled(busy)
                    Button("更新 Key", action: onUpdateKey)
                    Button("移除账号", role: .destructive, action: onRemove)
                }),
                mark: AnyView(BrandMark(brand: .deepseek, palette: palette))) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("总余额").scaledFont(15, relativeTo: .subheadline).foregroundStyle(palette.secondary)
                    Text(Money.text(info?.total, currency: info?.currency))
                        .scaledFont(expanded ? 22 : 17, weight: .bold, relativeTo: .title2).monospacedDigit().foregroundStyle(palette.primary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Spacer(minLength: 8)
                    if !expanded {
                        Text("更新 " + updated).scaledFont(13, relativeTo: .footnote).foregroundStyle(palette.secondary).lineLimit(1)
                    }
                }
                if expanded {
                    Rectangle().fill(palette.divider).frame(height: 1).padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 0) {
                        AppRow(label: "赠送", value: Money.text(info?.granted, currency: info?.currency), palette: palette)
                        AppRow(label: "充值", value: Money.text(info?.toppedUp, currency: info?.currency), palette: palette)
                        AppRow(label: "接口状态", value: snapshot == nil ? "暂无余额数据" : (snapshot!.balance.isAvailable ? "API 余额可用" : "API 余额不可用"), palette: palette)
                        AppRow(label: "更新时间", value: updated, palette: palette)
                    }
                }
                CardRefreshFeedback(error: refreshError, updatedAt: snapshot?.updatedAt, palette: palette, busy: busy, onRetry: onRefresh)
            }
        }
    }
}

/// Antigravity usage: one number — the tightest model quota the backend reports — with its meter
/// and countdown; expanding only adds the plan and update time (no pool or per-model rows).
struct AntigravityCard: View {
    let snapshot: AntigravitySnapshot?
    @Binding var expanded: Bool
    var palette: AppPalette
    let onRefresh: () -> Void
    let onReauthorize: () -> Void
    let onRemove: () -> Void
    let busy: Bool
    var refreshError: String? = nil
    var summary: QuotaSummary.Window? {
        QuotaSummary.tightest((snapshot?.usage.quotas ?? []).map { .init(label: "模型额度", remaining: $0.remaining, reset: $0.reset) })
    }
    var body: some View {
        AppCard(title: "Antigravity", caption: "Google Antigravity 配额与额度",
                systemImage: "sparkles", palette: palette, expanded: $expanded,
                menu: AnyView(CardMenu(palette: palette, accountContext: "Antigravity") {
                    Button("刷新 Antigravity 用量", action: onRefresh).disabled(busy)
                    Button("重新授权", action: onReauthorize)
                    Button("移除 Antigravity 授权", role: .destructive, action: onRemove)
                }),
                mark: AnyView(BrandMark(brand: .antigravity, palette: palette))) {
            VStack(alignment: .leading, spacing: 12) {
                if expanded {
                    QuotaRow(label: "模型额度", remaining: summary?.remaining, reset: summary?.reset, brand: .antigravity, palette: palette)
                    Rectangle().fill(palette.divider).frame(height: 1).padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 0) {
                        AppRow(label: "套餐", value: snapshot?.usage.tier ?? "—", palette: palette)
                        AppRow(label: "更新时间", value: snapshot.map { RelativeTime.text($0.updatedAt) + ($0.isStale() ? " · 已过期" : "") } ?? "—", palette: palette)
                    }
                } else {
                    SummaryLine(window: summary, brand: .antigravity, palette: palette)
                }
                CardRefreshFeedback(error: refreshError, updatedAt: snapshot?.updatedAt, palette: palette, busy: busy, onRetry: onRefresh)
            }
        }
    }
}

@main
struct CodexUsageApp: App {
    // XCTest hosts must not read real account stores, render storage-backed settings or auto-fetch.
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    @StateObject private var model = UsageModel(loadStoredAccounts: !isTesting)
    var body: some Scene {
        WindowGroup {
            if Self.isTesting { Color.clear }
            else { ContentView(model: model) }
        }
    }
}
