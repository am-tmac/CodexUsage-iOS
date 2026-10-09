import SwiftUI

// build 27: brand marks, collapsed-card summaries and the Nowdex-style 连接账号 flow.
// Everything here is presentation: the sign-in flows are the existing panels, moved, not rewritten.

/// One provider's look: its official mark (App-only asset catalog) and its meter colours.
/// Codex keeps the palette's original blue so its card is pixel-identical to before.
enum ServiceBrand: String, CaseIterable, Identifiable {
    case codex, claude, deepseek, antigravity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .deepseek: return "DeepSeek"
        case .antigravity: return "Antigravity"
        }
    }
    var connectCaption: String {
        switch self {
        case .codex: return "ChatGPT 设备代码"
        case .claude: return "Claude 账号登录"
        case .deepseek: return "API Key 余额"
        case .antigravity: return "Google 账号登录"
        }
    }
    var connectBlurb: String {
        switch self {
        case .codex: return "用 ChatGPT 账号授权，查看 5 小时和每周额度。"
        case .claude: return "登录 Claude 账号，查看 5 小时和 7 天用量。"
        case .deepseek: return "保存 DeepSeek API Key，查看 API 平台余额。"
        case .antigravity: return "登录 Google 账号，查看 Antigravity 模型额度。"
        }
    }
    /// Asset names in App/Assets.xcassets. OpenAI's mark is a template (follows the text colour);
    /// the others keep their official colours.
    var logoAsset: String {
        switch self {
        case .codex: return "LogoOpenAI"
        case .claude: return "LogoClaude"
        case .deepseek: return "LogoDeepSeek"
        case .antigravity: return "LogoAntigravity"
        }
    }
    /// The colours live in `MeterTint` (Shared/UsageViews.swift) so the widget uses the same ones.
    var tint: MeterTint { MeterTint(rawValue: rawValue) ?? .codex }
}

/// 设置 › 用量显示, read by every card without threading it through each initializer.
private struct UsageDisplayKey: EnvironmentKey { static let defaultValue: UsageDisplay = .remaining }
extension EnvironmentValues {
    var usageDisplay: UsageDisplay {
        get { self[UsageDisplayKey.self] }
        set { self[UsageDisplayKey.self] = newValue }
    }
}

/// The provider's official mark, sized for the 42pt header tile (24pt) or larger tiles.
struct BrandMark: View {
    let brand: ServiceBrand
    var palette: AppPalette
    var size: CGFloat = 24
    var body: some View {
        Group {
            if brand == .codex {
                Image(brand.logoAsset).renderingMode(.template).resizable().foregroundStyle(palette.primary)
            } else {
                Image(brand.logoAsset).renderingMode(.original).resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Meter colours for one reading: the brand's own, or the danger red at ≤20% left.
struct MeterColors {
    let lit: Color
    let rest: Color
    init(brand: ServiceBrand, remaining: Double?, palette: AppPalette, dark: Bool) {
        (lit, rest) = brand.tint.colors(remaining: remaining, dark: dark)
    }
}

/// The single line a collapsed card shows under its header: short meter, remaining %, which
/// window it is, and the live countdown to that window's reported reset.
struct SummaryLine: View {
    let window: QuotaSummary.Window?
    let brand: ServiceBrand
    var palette: AppPalette
    @Environment(\.colorScheme) private var scheme
    @Environment(\.usageDisplay) private var display
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        if let window, let remaining = window.remaining {
            let colors = MeterColors(brand: brand, remaining: remaining, palette: palette, dark: scheme == .dark)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(display.text(remaining)).scaledFont(17, weight: .bold, relativeTo: .headline)
                            .monospacedDigit().foregroundStyle(palette.primary).fixedSize(horizontal: false, vertical: true)
                        Text(window.label).scaledFont(12, relativeTo: .caption).foregroundStyle(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(Countdown.short(window.reset, now: context.date))
                            .scaledFont(13, relativeTo: .footnote).monospacedDigit().foregroundStyle(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
            HStack(alignment: .center, spacing: 10) {
                DashMeter(remainingPercent: remaining, palette: palette, dashes: 22, height: 12,
                          litColor: colors.lit, restColor: colors.rest, display: display)
                    .frame(width: 110)
                Text(display.text(remaining)).scaledFont(17, weight: .bold, relativeTo: .headline)
                    .monospacedDigit().foregroundStyle(palette.primary).lineLimit(1).fixedSize()
                Text(window.label).scaledFont(12, relativeTo: .caption).foregroundStyle(palette.secondary)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 6)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Countdown.short(window.reset, now: context.date))
                        .scaledFont(13, relativeTo: .footnote).monospacedDigit().foregroundStyle(palette.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .accessibilityElement(children: .combine)
            }
        } else {
            Text("暂无额度数据").scaledFont(13, relativeTo: .footnote).foregroundStyle(palette.secondary)
        }
    }
}

/// "5天19时后重置 · 10月3日 09:12", kept current while the card is on screen.
struct ResetLine: View {
    let date: Date?
    var palette: AppPalette
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(Countdown.resetLine(date, now: context.date))
                .scaledFont(13, relativeTo: .footnote).monospacedDigit().foregroundStyle(palette.secondary)
        }
    }
}

// MARK: - 连接账号

/// What the connect sheet opens on: the service grid, or straight into one service's page (the
/// empty state and the per-card "重新授权" menu items open a specific one).
enum ConnectEntry: Identifiable, Hashable {
    case picker
    case service(ServiceBrand)
    var id: String { if case .service(let brand) = self { return brand.rawValue }; return "picker" }
}

struct ConnectSheet: View {
    @ObservedObject var model: UsageModel
    let entry: ConnectEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var path: [ServiceBrand] = []
    var palette: AppPalette { .resolve(scheme) }
    var body: some View {
        NavigationStack(path: $path) {
            picker
                .navigationDestination(for: ServiceBrand.self) { brand in ConnectServicePage(model: model, brand: brand) }
        }
        .onAppear { if case .service(let brand) = entry, path.isEmpty { path = [brand] } }
    }
    func connectedCount(_ brand: ServiceBrand) -> Int {
        switch brand {
        case .codex: return model.accounts.count
        case .claude: return model.claudeInstalled ? 1 : 0
        case .deepseek: return model.deepSeekIDs.count
        case .antigravity: return model.antigravityInstalled ? 1 : 0
        }
    }
    var picker: some View {
        ScrollView {
            VStack(spacing: 18) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(ServiceBrand.allCases) { brand in
                        NavigationLink(value: brand) { tile(brand) }.buttonStyle(.plain)
                    }
                }
                Text("Codex 和 DeepSeek 可以连接多个账号\n令牌只存本机钥匙串")
                    .scaledFont(13, relativeTo: .footnote).foregroundStyle(palette.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("连接账号")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭")
            }
        }
    }
    func tile(_ brand: ServiceBrand) -> some View {
        let count = connectedCount(brand)
        return VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.tile)
                .frame(width: 54, height: 54)
                .overlay { BrandMark(brand: brand, palette: palette, size: 30) }
            Text(brand.title).scaledFont(16, weight: .semibold, relativeTo: .callout).foregroundStyle(palette.primary)
            Text(brand.connectCaption).scaledFont(12, relativeTo: .caption).foregroundStyle(palette.secondary)
            if count > 0 {
                Label("已连接 \(count) 个", systemImage: "circle.fill")
                    .labelStyle(ConnectedLabelStyle())
                    .scaledFont(11, weight: .semibold, relativeTo: .caption2)
                    .foregroundStyle(MeterTint.antigravity.lit(dark: scheme == .dark))
            } else {
                Text("未连接").scaledFont(11, relativeTo: .caption2).foregroundStyle(palette.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20).padding(.horizontal, 12)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct ConnectedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 6)); configuration.title }
    }
}

/// One service's sign-in page: the brand hero, then that provider's existing sign-in panel.
struct ConnectServicePage: View {
    @ObservedObject var model: UsageModel
    let brand: ServiceBrand
    @Environment(\.colorScheme) private var scheme
    var palette: AppPalette { .resolve(scheme) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(palette.tile)
                        .frame(width: 76, height: 76)
                        .overlay { BrandMark(brand: brand, palette: palette, size: 42) }
                    Text("连接 \(brand.title)").scaledFont(24, weight: .bold, relativeTo: .title2).foregroundStyle(palette.primary)
                    Text(brand.connectBlurb).scaledFont(15, relativeTo: .subheadline).foregroundStyle(palette.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
                switch brand {
                case .codex: CodexConnectPanel(model: model, palette: palette)
                case .claude: ClaudePanel(model: model, palette: palette)
                case .deepseek: DeepSeekPanel(model: model)
                case .antigravity: AntigravityPanel(model: model, palette: palette)
                }
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(palette.danger)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(brand.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The ChatGPT device-code sign-in, moved out of the status page unchanged (same copy, same
/// keychain-boundary confirmation before the flow starts).
struct CodexConnectPanel: View {
    @ObservedObject var model: UsageModel
    let palette: AppPalette
    @State private var confirmKeychainRisk = false
    var body: some View {
        AppCard(title: "ChatGPT 账号", caption: model.accounts.isEmpty ? "尚未登录" : "已在本机保存授权",
                systemImage: "person.crop.circle", palette: palette,
                mark: AnyView(BrandMark(brand: .codex, palette: palette))) {
            VStack(alignment: .leading, spacing: 14) {
                Text("使用 ChatGPT 设备代码登录，无需 Mac 或代理服务。令牌仅存储在本机钥匙串。此 App 非 OpenAI 官方产品，使用非公开接口，可能随时失效。")
                    .font(.footnote).foregroundStyle(palette.secondary)
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
                            Button(model.accounts.isEmpty ? "使用 ChatGPT 登录" : "添加账号 / 重新授权") { confirmKeychainRisk = true }.buttonStyle(.glassProminent)
                        } else {
                            Button(model.accounts.isEmpty ? "使用 ChatGPT 登录" : "添加账号 / 重新授权") { confirmKeychainRisk = true }.buttonStyle(.borderedProminent).padding(6).background(.regularMaterial, in: Capsule())
                        }
                    }.disabled(model.busy)
                }
            }
        }
        .alert("确认钥匙串安全边界", isPresented: $confirmKeychainRisk) {
            Button("取消", role: .cancel) {}
            Button("知悉风险，继续登录") { model.login() }
        } message: {
            Text("当前签名默认组：\(SharedStorage.diagnostics.observedDefaultGroup ?? "未知")。购买证书可能让同组其他 App 读取或修改本 App 保存的令牌，private 服务名不能隔离权限。继续只授权在现有默认钥匙串保存本次登录，不授权共享迁移或组件独立刷新。若不接受，请取消；已有令牌的暴露不能被此提示撤销。")
        }
    }
}

/// Status page with no account at all: a drawn illustration (no borrowed artwork, no sample
/// numbers) and one button into the connect sheet.
struct EmptyConnectView: View {
    let palette: AppPalette
    let onConnect: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous).fill(palette.card)
                    .frame(width: 220, height: 170)
                    .shadow(color: .black.opacity(0.06), radius: 14, y: 8)
                Circle().trim(from: 0, to: 0.62)
                    .stroke(palette.meterUsed, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .background(Circle().stroke(palette.meterRest, lineWidth: 11))
                    .frame(width: 85, height: 85)
                Image(systemName: "chart.bar.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(palette.meterUsed)
                chip("5 小时").offset(x: -68, y: -58)
                chip("每周").offset(x: 74, y: 58)
            }
            .accessibilityHidden(true)
            Text("连接账号").scaledFont(24, weight: .bold, relativeTo: .title2).foregroundStyle(palette.primary).padding(.top, 28)
            Text("点「连接账号」添加 Codex、Claude、DeepSeek 或 Antigravity，每个账号会在这里单独显示额度。")
                .scaledFont(15, relativeTo: .subheadline).foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center).padding(.top, 10)
            Button(action: onConnect) {
                Text("连接账号").scaledFont(17, weight: .semibold, relativeTo: .headline)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .foregroundStyle(palette.background)
                    .background(palette.primary, in: Capsule())
            }.buttonStyle(.plain).padding(.top, 26)
        }
        .padding(.horizontal, 12)
        .padding(.top, 36)
    }
    func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .bold)).foregroundStyle(palette.primary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(palette.tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
