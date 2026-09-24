import SwiftUI
import WidgetKit
import AppIntents

struct DashboardEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "服务 / 账号"
    static var defaultQuery = DashboardQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}
struct DashboardQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DashboardEntity] {
        // Keep deleted identifiers resolvable as empty selections; never silently switch accounts.
        identifiers.map { id in DashboardEntity(id: id, title: DashboardStore.accounts().first(where: { $0.id == id })?.title ?? "账号已移除") }
    }
    func suggestedEntities() async throws -> [DashboardEntity] {
        DashboardStore.accounts().map { DashboardEntity(id: $0.id, title: $0.title) }
    }
}
struct DashboardConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "服务与独立账号"
    static var description = IntentDescription("小号显示左栏；中号显示两栏。每栏独立选择 Codex、Claude 或其他服务。")
    @Parameter(title: "左栏 / 小号账号") var leftAccount: DashboardEntity?
    @Parameter(title: "右栏账号") var rightAccount: DashboardEntity?
}
struct DashboardColumn {
    let id: String?
    let provider: String
    let title: String
    let usage: UsageSnapshot?
    let balance: DeepSeekSnapshot?
    let antigravity: AntigravitySnapshot?
    let claude: ClaudeSnapshot?
    let canRefresh: Bool
    let failed: Bool
    let refreshing: Bool
    static func load(_ id: String?, defaultProvider: String = "codex") -> Self {
        let row = DashboardStore.accounts().first { $0.id == id }
        let provider = row?.provider ?? defaultProvider
        let attempt = id.map { WidgetRefreshAttempt.load($0) }
        return Self(id: id, provider: provider, title: row?.title ?? "未选择 / 账号已移除",
                    usage: id.flatMap { SharedStorage.snapshot(account: $0) },
                    balance: id.flatMap { DeepSeekStore.snapshot($0) },
                    antigravity: id.flatMap { _ in AntigravityStore.snapshot() },
                    claude: provider == "claude" ? ClaudeStore.snapshot() : nil,
                    canRefresh: id.map { DashboardStore.canRefreshAnyProvider($0) } ?? false,
                    failed: attempt?.failed ?? false, refreshing: attempt?.isRefreshing(at: Date()) ?? false)
    }
}
struct UsageEntry: TimelineEntry {
    let date: Date
    let left: DashboardColumn
    let right: DashboardColumn
    var theme: ThemePreference = .system
}
struct UsageProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), left: .load(nil), right: .load(nil, defaultProvider: "deepseek"))
    }
    func entry(_ configuration: DashboardConfiguration) -> UsageEntry {
        let leftID = configuration.leftAccount?.id ?? SharedStorage.selectedAccount() ?? DashboardStore.accounts().first?.id
        let rightID = configuration.rightAccount?.id ?? DashboardStore.accounts().first(where: { $0.id != leftID && $0.provider == "deepseek" })?.id ?? DashboardStore.accounts().first(where: { $0.id != leftID })?.id
        return UsageEntry(date: Date(), left: .load(leftID), right: .load(rightID, defaultProvider: "deepseek"), theme: ThemePreference.load())
    }
    func snapshot(for configuration: DashboardConfiguration, in context: Context) async -> UsageEntry {
        SharedStorage.recordWidgetDiagnostics()
        return entry(configuration)
    }
    func timeline(for configuration: DashboardConfiguration, in context: Context) async -> Timeline<UsageEntry> {
        SharedStorage.recordWidgetDiagnostics()
        let cached = entry(configuration)
        let columns = context.family == .systemMedium ? [cached.left, cached.right] : [cached.left]
        for id in RefreshTargets.unique(columns.map { $0.id }) {
            let column = columns.first { $0.id == id }
            guard let column, column.canRefresh, !column.refreshing else { continue }
            do {
                if column.provider == "deepseek" { _ = try await DeepSeekService.shared.refresh(id: id) }
                else if column.provider == "antigravity" { _ = try await AntigravityService.shared.refresh() }
                else if column.provider == "claude" { _ = try await ClaudeService.shared.refresh() }
                else { _ = try await UsageService.shared.refresh(account: id, widget: true, permission: { DashboardStore.canRefresh(id, provider: "codex") }) }
            } catch is CancellationError {
                return Timeline(entries: [entry(configuration)], policy: .after(Date().addingTimeInterval(900)))
            } catch { /* Last successful cache and persisted failure are preserved. */ }
        }
        return Timeline(entries: [entry(configuration)], policy: .after(Date().addingTimeInterval(900)))
    }
}
struct DashboardWidgetView: View {
    @Environment(\.widgetFamily) var family
    @Environment(\.colorScheme) var scheme
    let entry: UsageEntry
    var palette: ThemePalette { .resolve(entry.theme, scheme: scheme) }
    @ViewBuilder func column(_ value: DashboardColumn) -> some View {
        if value.provider == "deepseek" {
            if family == .systemSmall {
                DeepSeekStackedCardView(snapshot: value.balance, failed: value.failed, cacheOnly: !value.canRefresh)
            } else {
                DeepSeekCompactView(snapshot: value.balance, label: value.title, failed: value.failed,
                                    cacheOnly: !value.canRefresh, palette: palette)
            }
        } else if value.provider == "antigravity" {
            AntigravityWidgetView(snapshot: value.antigravity, palette: palette)
        } else if value.provider == "claude" {
            ClaudeCompactView(snapshot: value.claude, failed: value.failed, cacheOnly: !value.canRefresh, palette: palette)
        } else {
            CompactUsageView(snapshot: value.usage, failed: value.failed, refreshing: value.refreshing,
                             sharingUnavailable: !SharedStorage.cacheSharingAvailable, cacheOnly: !value.canRefresh,
                             palette: palette)
        }
    }
    var isMedium: Bool { family == .systemMedium }
    /// Only `.systemSmall` + DeepSeek uses the stacked card; the medium family and every Codex
    /// slot keep the build-14 layout.
    var stackedCard: Bool { family == .systemSmall && entry.left.provider == "deepseek" }
    /// Exactly one control per widget, pinned to the top-right corner of both families.
    /// The medium control carries both slots and refreshes them with a single tap; the small
    /// widget passes no right slot, so it never refreshes an account it does not display.
    /// Columns never draw their own button.
    var hasConfiguredAccount: Bool { isMedium ? (entry.left.id != nil || entry.right.id != nil) : entry.left.id != nil }
    var refreshControl: RefreshAffordance {
        RefreshAffordance(canRefresh: isMedium ? (entry.left.canRefresh || entry.right.canRefresh) : entry.left.canRefresh,
                          leftID: entry.left.id, rightID: isMedium ? entry.right.id : nil,
                          palette: palette, label: isMedium ? "刷新组件内的账号" : "刷新该账号",
                          inset: stackedCard ? 4 : 0, topInset: 0,
                          bottomInset: stackedCard ? 4 : 0, bottomAligned: stackedCard)
    }
    var body: some View {
        Group {
            if stackedCard {
                // The stack paints the whole widget, margins are off in the configuration and the
                // refresh control moves into the black layer so it cannot cover the balance.
                column(entry.left)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            column(entry.left)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        if isMedium {
                            Rectangle().fill(palette.divider).frame(width: 1)
                            VStack(alignment: .leading, spacing: 4) {
                                column(entry.right)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                }
                // Content margins are disabled in the configuration, so build 14's 16pt inset is
                // applied here instead of being supplied by WidgetKit.
                .padding(16)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hasConfiguredAccount { refreshControl }
        }
    }
}
struct DashboardWidgetRoot: View {
    @Environment(\.colorScheme) var scheme
    let entry: UsageEntry
    var body: some View {
        let palette = ThemePalette.resolve(entry.theme, scheme: scheme)
        DashboardWidgetView(entry: entry)
            .environment(\.colorScheme, entry.theme == .light ? .light : (entry.theme == .dark ? .dark : scheme))
            .containerBackground(palette.background, for: .widget)
    }
}
@main struct CodexUsageWidget: Widget {
    let kind = "CodexUsageWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: DashboardConfiguration.self, provider: UsageProvider()) { entry in
            DashboardWidgetRoot(entry: entry)
        }.configurationDisplayName("Codex / DeepSeek")
            .description("长按编辑组件，独立选择服务与账号；中号右上角一个刷新按钮同时刷新两栏。")
            .supportedFamilies([.systemSmall, .systemMedium])
            // The stacked DeepSeek card is a full-bleed card stack: it draws its own 8pt/16pt
            // insets. Every other layout re-applies build 14's 16pt margin in the view.
            .contentMarginsDisabled()
    }
}
