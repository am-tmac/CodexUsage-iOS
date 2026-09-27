import SwiftUI
import WidgetKit
import AppIntents

/// Colour set for one appearance. Both families render with the same palette so the
/// App-side theme choice and the home-screen widget cannot drift apart.
struct ThemePalette {
    let background: Color
    let primary: Color
    let secondary: Color
    let track: Color
    let divider: Color
    let refresh: Color
    let warning: Color
    static let dark = ThemePalette(background: Color(red: 0.035, green: 0.065, blue: 0.13),
                                   primary: .white, secondary: Color(white: 0.68),
                                   track: Color(white: 1).opacity(0.14), divider: Color(white: 1).opacity(0.12),
                                   refresh: Color(white: 0.72), warning: .orange)
    static let light = ThemePalette(background: Color(red: 0.955, green: 0.965, blue: 0.98),
                                    primary: Color(red: 0.06, green: 0.09, blue: 0.16),
                                    secondary: Color(red: 0.36, green: 0.40, blue: 0.46),
                                    track: Color(red: 0.06, green: 0.09, blue: 0.16).opacity(0.12),
                                    divider: Color(red: 0.06, green: 0.09, blue: 0.16).opacity(0.12),
                                    refresh: Color(red: 0.29, green: 0.34, blue: 0.42), warning: Color(red: 0.72, green: 0.36, blue: 0.02))
    static func resolve(_ theme: ThemePreference, scheme: ColorScheme) -> ThemePalette {
        switch theme {
        case .light: return .light
        case .dark: return .dark
        case .system: return scheme == .light ? .light : .dark
        }
    }
    static func resolve(scheme: ColorScheme) -> ThemePalette { resolve(.system, scheme: scheme) }
}

#if CODEX_WIDGET
/// One control for the whole widget: it refreshes every configured slot that is allowed to
/// refresh, and never the same account twice. A slot that may not refresh is skipped rather
/// than silently re-pointed at another account.
struct RefreshDashboardIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新组件账号"
    static var openAppWhenRun = false
    @Parameter(title: "左栏账号") var leftID: String?
    @Parameter(title: "右栏账号") var rightID: String?
    init() {}
    init(leftID: String?, rightID: String?) { self.leftID = leftID; self.rightID = rightID }
    func perform() async throws -> some IntentResult {
        defer { WidgetCenter.shared.reloadAllTimelines() }
        let targets = RefreshTargets.unique([leftID, rightID]).filter { DashboardStore.canRefreshAnyProvider($0) }
        let accounts = DashboardStore.accounts()
        // Both slots at once (build 28): the tap now waits for the slower slot, not the sum.
        await withTaskGroup(of: Void.self) { group in
            for id in targets {
                let provider = accounts.first(where: { $0.id == id })?.provider ?? "codex"
                group.addTask { _ = try? await WidgetRefresh.one(id: id, provider: provider) }
            }
        }
        try Task.checkCancellation()
        return .result()
    }
}

/// One slot's refresh, the same for the timeline and the button. The last good cache and the
/// persisted failure flag survive any error.
enum WidgetRefresh {
    static func one(id: String, provider: String) async throws {
        switch provider {
        case "deepseek": _ = try await DeepSeekService.shared.refresh(id: id)
        case "claude": _ = try await ClaudeService.shared.refresh()
        case "antigravity": _ = try await AntigravityService.shared.refresh()
        default: _ = try await UsageService.shared.refresh(account: id, widget: true, permission: { DashboardStore.canRefresh(id, provider: "codex") })
        }
    }
}
#endif

struct RefreshAffordance: View {
    let canRefresh: Bool
    let leftID: String?
    let rightID: String?
    var palette: ThemePalette = .dark
    var label: String = "刷新组件账号"
    /// Inset belongs to the 44pt hit region, not to the visible glyph. With zero inset the
    /// symbol centre is already 22pt from the widget edge, aligned with the content margin.
    var inset: CGFloat = 0
    var topInset: CGFloat = 0
    /// DeepSeek places the 44pt hit region 4pt from the wallet's bottom-right edge.
    /// The amount reserves horizontal room for this region, so the glyph stays at the
    /// actual corner instead of being lifted halfway up the black card.
    var bottomInset: CGFloat = 0
    var bottomAligned = false
    /// Authorised: the circular refresh glyph, on the real in-widget AppIntent refresh.
    var glyph: some View {
        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.refresh)
    }
    /// Not authorised: a deliberately different glyph. Opening the App is not an in-widget
    /// refresh, so it must never wear the circular refresh symbol — the user reads that symbol as
    /// "this refreshes here", and build 19 was rejected for exactly that disguise.
    var openAppGlyph: some View {
        Image(systemName: "arrow.up.forward.app").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.refresh)
    }
    /// The open-App branch is a `Link` (the only way a widget can launch its App); the widget root
    /// carries no `widgetURL`, so no other tap is routed around the AppIntent button.
    static let openAppURL = URL(string: "codexusage://refresh")!
    var body: some View {
        #if CODEX_WIDGET
        if canRefresh {
            placed(Button(intent: RefreshDashboardIntent(leftID: leftID, rightID: rightID)) {
                glyph
            }.buttonStyle(.plain).frame(width: 44, height: 44).contentShape(Rectangle()).accessibilityLabel(label))
        } else {
            // The control is present in BOTH states. Without the sharing handshake and the user's
            // consent an extension cannot fetch, so the honest control opens the App where the
            // fetch is allowed — under a different glyph and its own label.
            placed(Link(destination: Self.openAppURL) {
                openAppGlyph
            }.frame(width: 44, height: 44).contentShape(Rectangle()).accessibilityLabel("打开 App 刷新"))
        }
        #else
        if canRefresh { placed(glyph) }
        #endif
    }
    @ViewBuilder func placed<V: View>(_ control: V) -> some View {
        if bottomAligned {
            // A full-height frame inside the topTrailing overlay puts the icon at the bottom edge.
            control.padding(.trailing, inset).padding(.bottom, bottomInset)
                .frame(maxHeight: .infinity, alignment: .bottom)
        } else {
            control.padding(.top, topInset).padding(.trailing, inset)
        }
    }
}

struct DeepSeekCompactView: View {
    let snapshot: DeepSeekSnapshot?
    let label: String
    var failed = false
    var cacheOnly = false
    var palette: ThemePalette = .dark
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DeepSeek").font(.system(size: 19, weight: .bold)).foregroundStyle(palette.primary).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 9)).foregroundStyle(palette.secondary).lineLimit(1).truncationMode(.middle)
            if let snapshot {
                ForEach(Array(snapshot.balance.balanceInfos.prefix(2).enumerated()), id: \.offset) { _, info in
                    Text(info.currency + " " + NSDecimalNumber(decimal: info.total).stringValue)
                        .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(palette.primary).lineLimit(1).minimumScaleFactor(0.5)
                }
                Text(snapshot.balance.isAvailable ? "API 可用余额" : "API 余额不可用").font(.system(size: 9)).foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
                Text("更新 \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))\(snapshot.isStale() ? " · 已过期" : "")")
                    .font(.system(size: 9)).foregroundStyle(palette.secondary).lineLimit(1)
            } else {
                Text("—").font(.system(size: 22, weight: .bold)).foregroundStyle(palette.primary)
                Spacer(minLength: 0)
                Text("打开 App 添加 Key").font(.system(size: 9)).foregroundStyle(palette.secondary)
            }
            if cacheOnly { Text("仅缓存 · 组件无刷新授权，打开 App").font(.system(size: 9)).foregroundStyle(palette.secondary).lineLimit(1).minimumScaleFactor(0.7) }
            else if failed { Text("刷新失败 · 保留缓存").font(.system(size: 9)).foregroundStyle(palette.warning) }
        }
    }
}

/// DeepSeek's whale: the official mark from the DeepSeek brand SVG (viewBox 512 x 509.64),
/// converted to vector code so the widget target needs no image catalog and no asset. Coordinates
/// below are the source SVG's own; `box` is the mark's tight bounds inside that viewBox (measured
/// from the converted path), so the shape fills whatever frame it is given.
struct DeepSeekWhale: Shape {
    private static let box = (x: CGFloat(67.1438), y: CGFloat(115.8345), w: CGFloat(377.7177), h: CGFloat(277.9756))
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.box.w, rect.height / Self.box.h)
        let dx = rect.minX + (rect.width - Self.box.w * scale) / 2
        let dy = rect.minY + (rect.height - Self.box.h * scale) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: dx + (x - Self.box.x) * scale, y: dy + (y - Self.box.y) * scale)
        }
        var path = Path()
        path.move(to: p(440.8980, 139.1670))
        path.addCurve(to: p(432.8360, 142.8400), control1: p(436.8970, 137.2060), control2: p(435.1750, 140.9430))
        path.addCurve(to: p(430.6820, 144.9810), control1: p(432.0350, 143.4520), control2: p(431.3570, 144.2470))
        path.addCurve(to: p(409.0750, 154.8400), control1: p(424.8340, 151.2270), control2: p(418.0010, 155.3300))
        path.addCurve(to: p(375.0350, 168.1880), control1: p(396.0270, 154.1060), control2: p(384.8830, 158.2080))
        path.addCurve(to: p(355.4000, 143.8180), control1: p(372.9420, 155.8810), control2: p(365.9870, 148.5300))
        path.addCurve(to: p(340.3800, 133.5910), control1: p(349.8600, 141.3690), control2: p(344.2590, 138.9180))
        path.addCurve(to: p(335.5790, 121.4060), control1: p(337.6720, 129.7960), control2: p(336.9330, 125.5700))
        path.addCurve(to: p(330.9610, 115.8940), control1: p(334.7180, 118.8970), control2: p(333.8540, 116.3240))
        path.addCurve(to: p(325.3600, 120.2430), control1: p(327.8220, 115.4040), control2: p(326.5890, 118.0360))
        path.addCurve(to: p(318.7130, 149.2050), control1: p(320.4350, 129.2450), control2: p(318.5270, 139.1640))
        path.addCurve(to: p(347.6450, 202.6020), control1: p(319.1450, 171.8020), control2: p(328.6850, 189.8020))
        path.addCurve(to: p(349.6770, 207.6840), control1: p(349.7990, 204.0720), control2: p(350.3520, 205.5410))
        path.addCurve(to: p(345.4910, 220.7890), control1: p(348.3840, 212.0940), control2: p(346.8450, 216.3790))
        path.addCurve(to: p(340.3190, 222.9940), control1: p(344.6290, 223.6060), control2: p(343.3340, 224.2180))
        path.addCurve(to: p(312.9870, 204.4410), control1: p(329.9170, 218.6480), control2: p(320.9280, 212.2160))
        path.addCurve(to: p(272.1140, 165.7390), control1: p(299.5060, 191.3970), control2: p(287.3190, 177.0070))
        path.addCurve(to: p(261.2800, 158.3300), control1: p(268.5952, 163.1367), control2: p(264.9814, 160.6653))
        path.addCurve(to: p(267.3740, 129.4280), control1: p(245.7680, 143.2670), control2: p(263.3120, 130.8960))
        path.addCurve(to: p(255.1230, 122.6920), control1: p(271.6210, 127.8960), control2: p(268.8520, 122.6310))
        path.addCurve(to: p(212.8350, 133.4690), control1: p(241.3960, 122.7530), control2: p(228.8380, 127.3450))
        path.addCurve(to: p(205.5090, 135.6110), control1: p(210.4950, 134.3890), control2: p(208.0340, 135.0620))
        path.addCurve(to: p(160.1420, 134.0180), control1: p(190.9820, 132.8550), control2: p(175.9010, 132.2430))
        path.addCurve(to: p(89.3540, 175.2900), control1: p(130.4710, 137.3230), control2: p(106.7740, 151.3470))
        path.addCurve(to: p(69.5330, 270.8800), control1: p(68.4260, 204.0750), control2: p(63.5000, 236.7720))
        path.addCurve(to: p(122.4090, 359.8540), control1: p(75.8730, 306.8230), control2: p(94.2160, 336.5840))
        path.addCurve(to: p(223.7290, 393.5310), control1: p(151.6480, 383.9770), control2: p(185.3200, 395.7970))
        path.addCurve(to: p(302.3360, 364.2610), control1: p(247.0580, 392.1850), control2: p(273.0360, 389.0630))
        path.addCurve(to: p(330.3440, 370.5070), control1: p(309.7230, 367.9340), control2: p(317.4780, 369.4050))
        path.addCurve(to: p(357.1830, 368.4880), control1: p(340.2550, 371.4270), control2: p(349.7960, 370.0170))
        path.addCurve(to: p(363.7690, 353.3640), control1: p(368.7560, 366.0390), control2: p(367.9560, 355.3220))
        path.addCurve(to: p(330.5290, 338.7910), control1: p(329.8540, 337.5670), control2: p(337.2990, 343.9960))
        path.addCurve(to: p(383.8980, 228.5690), control1: p(347.7640, 318.4010), control2: p(373.7420, 297.2140))
        path.addCurve(to: p(383.8980, 215.2820), control1: p(384.6980, 223.1210), control2: p(384.0190, 219.6920))
        path.addCurve(to: p(387.5300, 211.2410), control1: p(383.8370, 212.5900), control2: p(384.4510, 211.5480))
        path.addCurve(to: p(411.8440, 203.7700), control1: p(396.0240, 210.2600), control2: p(404.2720, 207.9360))
        path.addCurve(to: p(444.7770, 148.4150), control1: p(433.8190, 191.7680), control2: p(442.6840, 172.0510))
        path.addCurve(to: p(440.8980, 139.1700), control1: p(445.0840, 144.8030), control2: p(444.7160, 141.0670))
        path.addLine(to: p(440.8980, 139.1670))
        path.closeSubpath()
        path.move(to: p(249.4000, 351.8900))
        path.addCurve(to: p(194.0000, 317.9060), control1: p(216.5280, 326.0520), control2: p(200.5860, 317.5380))
        path.addCurve(to: p(190.3060, 329.9080), control1: p(187.8450, 318.2740), control2: p(188.9520, 325.3160))
        path.addCurve(to: p(196.1540, 341.5420), control1: p(191.7210, 334.4400), control2: p(193.5700, 337.5620))
        path.addCurve(to: p(194.3700, 351.0350), control1: p(197.9390, 344.1760), control2: p(199.1710, 348.0930))
        path.addCurve(to: p(164.5140, 348.4000), control1: p(183.7830, 357.5850), control2: p(165.3770, 348.8300))
        path.addCurve(to: p(112.5600, 296.3530), control1: p(143.0930, 335.7860), control2: p(125.1800, 319.1310))
        path.addCurve(to: p(92.1250, 225.8110), control1: p(100.3730, 274.4290), control2: p(93.2930, 250.9180))
        path.addCurve(to: p(99.6340, 216.5040), control1: p(91.8170, 219.7500), control2: p(93.6030, 217.6040))
        path.addCurve(to: p(123.7020, 215.8890), control1: p(107.5740, 215.0330), control2: p(115.7610, 214.7260))
        path.addCurve(to: p(209.7560, 259.5490), control1: p(157.2490, 220.7890), control2: p(185.8100, 235.7910))
        path.addCurve(to: p(244.4140, 305.0450), control1: p(223.4220, 273.0800), control2: p(233.7630, 289.2480))
        path.addCurve(to: p(283.4400, 350.9100), control1: p(255.7400, 321.8230), control2: p(267.9280, 337.8060))
        path.addCurve(to: p(297.4750, 361.5660), control1: p(288.9190, 355.5020), control2: p(293.2880, 358.9930))
        path.addCurve(to: p(249.4000, 351.8900), control1: p(284.8550, 362.9730), control2: p(263.8020, 363.2800))
        path.closeSubpath()
        path.move(to: p(265.2990, 249.3710))
        path.addCurve(to: p(270.0210, 245.7130), control1: p(265.8200, 247.2600), control2: p(267.7200, 245.7130))
        path.addCurve(to: p(271.6820, 246.0180), control1: p(270.5885, 245.7144), control2: p(271.1511, 245.8177))
        path.addCurve(to: p(273.4680, 247.1810), control1: p(272.3600, 246.2640), control2: p(272.9750, 246.6320))
        path.addCurve(to: p(274.8220, 250.5490), control1: p(274.3290, 248.0400), control2: p(274.8220, 249.2640))
        path.addCurve(to: p(269.9600, 255.3860), control1: p(274.8220, 253.2440), control2: p(272.6680, 255.3860))
        path.addCurve(to: p(265.2220, 251.3520), control1: p(267.5968, 255.4079), control2: p(265.5773, 253.6884))
        path.addCurve(to: p(265.2990, 249.3710), control1: p(265.1155, 250.6931), control2: p(265.1416, 250.0196))
        path.closeSubpath()
        path.move(to: p(312.5070, 276.2860))
        path.addCurve(to: p(304.8000, 278.1660), control1: p(309.9010, 277.2820), control2: p(307.3070, 278.0640))
        path.addCurve(to: p(292.2440, 274.1850), control1: p(300.1210, 278.4100), control2: p(295.0130, 276.5120))
        path.addCurve(to: p(283.5650, 262.2440), control1: p(287.9360, 270.5730), control2: p(284.8580, 268.5540))
        path.addCurve(to: p(283.8110, 252.9980), control1: p(283.0110, 259.5490), control2: p(283.3180, 255.3860))
        path.addCurve(to: p(280.0570, 241.5470), control1: p(284.9190, 247.8540), control2: p(283.6870, 244.5470))
        path.addCurve(to: p(269.2230, 238.4250), control1: p(277.1030, 239.0980), control2: p(273.3460, 238.4250))
        path.addCurve(to: p(265.2220, 237.2010), control1: p(267.6840, 238.4250), control2: p(266.2690, 237.7520))
        path.addCurve(to: p(263.4370, 231.5670), control1: p(263.4980, 236.3450), control2: p(262.0830, 234.2010))
        path.addCurve(to: p(266.4550, 228.2620), control1: p(263.8690, 230.7110), control2: p(265.9620, 228.6280))
        path.addCurve(to: p(284.4890, 228.5060), control1: p(272.0550, 225.0770), control2: p(278.5200, 226.1180))
        path.addCurve(to: p(300.2480, 240.8130), control1: p(290.0290, 230.7720), control2: p(294.2160, 234.9350))
        path.addCurve(to: p(311.0210, 255.2030), control1: p(306.4030, 247.9150), control2: p(307.5110, 249.8760))
        path.addCurve(to: p(318.0390, 268.5510), control1: p(313.7920, 259.3660), control2: p(316.3150, 263.6540))
        path.addCurve(to: p(315.6980, 274.8280), control1: p(318.9160, 271.1120), control2: p(318.1100, 273.2910))
        path.addCurve(to: p(312.5070, 276.2860), control1: p(314.7170, 275.4530), control2: p(313.5890, 275.8720))
        path.closeSubpath()
        return path
    }
}

/// The DeepSeek wallet's black base (build 29): a rounded dome over the card column whose sides
/// flare back out (concave) to the widget edge `flareDrop` below the top, so the lower body spans
/// the full width like a wallet pocket. The convex corner and the concave flare meet with a
/// vertical tangent on the card column, so the outline has no kink.
struct DeepSeekPocketShape: Shape {
    var inset: CGFloat
    var corner: CGFloat
    var flareDrop: CGFloat
    func path(in r: CGRect) -> Path {
        let l = r.minX + inset, rr = r.maxX - inset, t = r.minY
        let flareY = t + flareDrop
        let joint = min(t + corner * 0.9, flareY - 4)
        let run = flareY - joint
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: flareY))
        p.addCurve(to: CGPoint(x: l, y: joint), control1: CGPoint(x: r.minX + inset * 0.6, y: flareY), control2: CGPoint(x: l, y: joint + run * 0.6))
        p.addCurve(to: CGPoint(x: l + corner, y: t), control1: CGPoint(x: l, y: t + (joint - t) * 0.4), control2: CGPoint(x: l + corner * 0.35, y: t))
        p.addLine(to: CGPoint(x: rr - corner, y: t))
        p.addCurve(to: CGPoint(x: rr, y: joint), control1: CGPoint(x: rr - corner * 0.35, y: t), control2: CGPoint(x: rr, y: t + (joint - t) * 0.4))
        p.addCurve(to: CGPoint(x: r.maxX, y: flareY), control1: CGPoint(x: rr, y: joint + run * 0.6), control2: CGPoint(x: r.maxX - inset * 0.6, y: flareY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// `.systemSmall` DeepSeek card: a three-layer wallet-style stack.
///
/// Layer order is the whole design — the purple card is drawn *behind* the near-white card and
/// both are drawn behind the black base card, each overlapping the previous layer so the lower
/// card's bottom edge is covered. This is a wallet-style stack on a black base, **not** a width
/// progression: the purple card and the black base share the same width (7.5pt inset, only the
/// purple's top corners are rounded and its bottom edge is straight), and the near-white card is
/// just 2.5pt narrower so its rounded bottom corners read as a card tucked between the two.
/// The stack fills the widget edge to edge (the configuration disables content margins).
///
/// No percentage is ever drawn here: a balance has no denominator, so a percent would be invented.
struct DeepSeekStackedCardView: View {
    let snapshot: DeepSeekSnapshot?
    var failed = false
    var cacheOnly = false
    /// Design colours are fixed so the card looks the same in either appearance.
    static let purple = Color(red: 0.494, green: 0.510, blue: 0.914)
    static let paper = Color(red: 0.925, green: 0.925, blue: 0.933)
    static let ink = Color(red: 0.110, green: 0.110, blue: 0.118)
    static let surface = Color(red: 0.012, green: 0.012, blue: 0.016)
    /// The black layer is not flat: its upper half lifts a few percent so the wallet reads as a
    /// solid stack with a light from above, then settles back to the base colour by mid-height.
    static let surfaceLift = Color(red: 0.085, green: 0.085, blue: 0.098)
    static var surfaceGradient: LinearGradient {
        LinearGradient(stops: [.init(color: surfaceLift, location: 0),
                               .init(color: surface, location: 0.5),
                               .init(color: surface, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
    /// build 29: the base card itself is lit from above — charcoal at the dome, black by the
    /// amount — so it reads as a raised card instead of a hole in the widget.
    static var baseGradient: LinearGradient {
        LinearGradient(stops: [.init(color: Color(red: 0.16, green: 0.16, blue: 0.175), location: 0),
                               .init(color: Color(red: 0.055, green: 0.055, blue: 0.064), location: 0.45),
                               .init(color: surface, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
    /// Hairline on the base's top contour only; masked off before the flare so no light line runs
    /// down the sides.
    static var rimLight: LinearGradient {
        LinearGradient(colors: [Color(white: 1, opacity: 0.54), Color(white: 1, opacity: 0.11), .clear],
                       startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3))
    }
    static let logoTint = Color(white: 0.72)
    /// Each coloured card: a soft darkening toward its tucked-in bottom and a light top edge.
    static func cardSurface(_ colour: Color) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 14)
        return shape.fill(colour)
            .overlay(shape.fill(LinearGradient(colors: [.clear, Color(white: 0, opacity: 0.10)], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color(white: 1, opacity: 0.43), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25)), lineWidth: 0.8))
    }
    static let muted = Color(white: 0.60)
    static let onPaper = Color(red: 0.145, green: 0.145, blue: 0.153)
    var info: DeepSeekBalance.BalanceInfo? { snapshot?.balance.balanceInfos.first }
    /// Purple card, near-white card and black base all share this inset, so the stack's left and
    /// right edges line up exactly; the bands differ only in corner rounding and height. Every
    /// band's text keeps the same 15.5pt column, so labels and amounts stay aligned too.
    static let cardInset: CGFloat = 8.5
    /// Exactly the same inset as the purple card: the two cards' left/right edges line up (user
    /// correction: 紫卡凸出来 was wrong — one wallet stack, not a stepped one).
    static let paperInset: CGFloat = 8.5
    static let purpleTop: CGFloat = 10
    static let purpleHeight: CGFloat = 52
    static let paperTop: CGFloat = 45
    static let paperHeight: CGFloat = 58
    static let baseTop: CGFloat = 76
    /// All three cards share one text column: in the reference 赠送 / 充值 / 总余额 and the amount
    /// all start at the same x, ~15pt in from the widget edge, so each band's inner inset cancels
    /// its own outer inset instead of stepping the text inwards.
    static let textColumn: CGFloat = 15.5
    static var purpleTextInset: CGFloat { textColumn - cardInset }
    static var paperTextInset: CGFloat { textColumn - paperInset }
    static let baseTextInset: CGFloat = textColumn - 8.5
    var body: some View {
        ZStack(alignment: .top) {
            band(title: "赠送", value: Money.text(info?.granted, currency: info?.currency), foreground: Color(white: 1), inset: Self.purpleTextInset)
                .frame(height: Self.purpleHeight, alignment: .top).padding(.top, 6)
                .background(Self.cardSurface(Self.purple))
                .padding(.horizontal, Self.cardInset)
                .padding(.top, Self.purpleTop)
            band(title: "充值", value: Money.text(info?.toppedUp, currency: info?.currency), foreground: Self.onPaper, inset: Self.paperTextInset)
                .frame(height: Self.paperHeight, alignment: .top).padding(.top, 7)
                // Runs down behind the black base; casts a soft shadow up onto the purple card.
                .background(Self.cardSurface(Self.paper).shadow(color: .black.opacity(0.36), radius: 3.5, y: -1.5))
                .padding(.horizontal, Self.paperInset)
                .padding(.top, Self.paperTop)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    DeepSeekWhale().fill(Self.logoTint).frame(width: 18, height: 13.3)
                    Text("DeepSeek").font(.system(size: 13, weight: .bold))
                }.foregroundStyle(Self.logoTint).frame(maxWidth: .infinity, alignment: .center).padding(.top, 7)
                Spacer(minLength: 2)
                Text("总余额").font(.system(size: 10)).foregroundStyle(Self.muted)
                Text(Money.text(info?.total, currency: info?.currency))
                    .font(.system(size: 24, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Color(white: 1)).lineLimit(1).minimumScaleFactor(0.45)
                    .padding(.trailing, 48)
                if let note = note {
                    Text(note).font(.system(size: 9)).foregroundStyle(failed ? Color.orange : Self.muted).lineLimit(1)
                }
            }
            .padding(.horizontal, Self.baseTextInset).padding(.bottom, 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Text keeps the card column; only the black shape widens to the widget edge.
            .padding(.horizontal, Self.cardInset)
            .background {
                let pocket = DeepSeekPocketShape(inset: Self.cardInset, corner: 18, flareDrop: 20)
                pocket.fill(Self.baseGradient)
                    .overlay(pocket.stroke(Self.rimLight, lineWidth: 0.75)
                        .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.2))))
                    .shadow(color: .black.opacity(0.45), radius: 4, y: -2)
            }
            .padding(.top, Self.baseTop)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The widget's own black surface carries the same lift, so the outermost band above the
        // cards is not dead flat either.
        .background(Self.surfaceGradient)
    }
    /// Only truthful status lines; the normal state adds nothing but the balance itself.
    var note: String? {
        if snapshot == nil { return cacheOnly ? "无缓存 · 打开 App 添加 Key" : "打开 App 添加 Key" }
        if cacheOnly { return "组件无刷新授权 · 打开 App" }
        if failed { return "刷新失败 · 保留上次余额" }
        if snapshot?.isStale() == true { return "保留上次余额 · 已过期" }
        return nil
    }
    func band(title: String, value: String, foreground: Color, inset: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, inset)
    }
}

/// Per-service meter colours, shared by the App cards and the widget (build 28) so the two can
/// never drift apart. Codex and DeepSeek keep the original blue; ≤20% left turns danger red.
enum MeterTint: String {
    case codex, claude, deepseek, antigravity
    func lit(dark: Bool) -> Color {
        switch self {
        case .codex, .deepseek: return dark ? Color(red: 0.212, green: 0.620, blue: 0.961) : Color(red: 0.129, green: 0.522, blue: 0.929)
        case .claude: return dark ? Color(red: 0.910, green: 0.537, blue: 0.290) : Color(red: 0.851, green: 0.467, blue: 0.169)
        case .antigravity: return dark ? Color(red: 0.208, green: 0.753, blue: 0.541) : Color(red: 0.122, green: 0.620, blue: 0.431)
        }
    }
    func rest(dark: Bool) -> Color {
        switch self {
        case .codex, .deepseek: return dark ? Color(red: 0.133, green: 0.204, blue: 0.282) : Color(red: 0.851, green: 0.878, blue: 0.918)
        case .claude: return dark ? Color(red: 0.239, green: 0.165, blue: 0.114) : Color(red: 0.945, green: 0.878, blue: 0.824)
        case .antigravity: return dark ? Color(red: 0.098, green: 0.227, blue: 0.176) : Color(red: 0.827, green: 0.922, blue: 0.882)
        }
    }
    static func lowLit(dark: Bool) -> Color { dark ? Color(red: 1.0, green: 0.35, blue: 0.32) : Color(red: 0.80, green: 0.16, blue: 0.13) }
    static func lowRest(dark: Bool) -> Color { dark ? Color(red: 0.239, green: 0.122, blue: 0.125) : Color(red: 0.965, green: 0.851, blue: 0.851) }
    /// The pair for one reading. The warning is decided on the reported *remaining* share, so
    /// switching the display to 已用 never changes when a meter turns red.
    func colors(remaining: Double?, dark: Bool) -> (lit: Color, rest: Color) {
        if let remaining, remaining <= 20 { return (Self.lowLit(dark: dark), Self.lowRest(dark: dark)) }
        return (lit(dark: dark), rest(dark: dark))
    }
}

/// The widget meter: the same segmented, brand-coloured meter as the App. It lights the share the
/// 用量显示 setting asks for (剩余 or 已用). A missing value lights no segment and never invents one.
struct QuotaBar: View {
    let remaining: Double?
    var tint: MeterTint = .codex
    var display: UsageDisplay = .remaining
    var height: CGFloat = 6
    var palette: ThemePalette = .dark
    var segments = 28
    @Environment(\.colorScheme) private var scheme
    private var lit: Int {
        guard let shown = display.shown(remaining) else { return 0 }
        return min(segments, max(0, Int((shown / 100 * Double(segments)).rounded())))
    }
    var body: some View {
        let colors = tint.colors(remaining: remaining, dark: scheme == .dark)
        HStack(spacing: 1) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                    .fill(index < lit ? colors.lit : colors.rest)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
        .accessibilityLabel(display.accessibility(remaining))
    }
}


/// Antigravity in the widget, drawn in the Codex slot's shape: one row per shared pool (the
/// tightest model inside it), each with its remaining share, the bar and the reset time. The mark
/// is Antigravity's own (a sparkle), not the ChatGPT blossom the Codex slot wears.
struct AntigravityWidgetView: View {
    let snapshot: AntigravitySnapshot?
    var palette: ThemePalette = .dark
    var display: UsageDisplay = .remaining
    /// 用户要求：组件里的 Antigravity 也只显示总用量，不列池、不列模型。
    private var total: Double? { snapshot?.usage.tightestRemaining }
    private var totalReset: Date? { (snapshot?.usage.pools ?? []).compactMap(\.reset).min() }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 14, weight: .bold)).foregroundStyle(palette.primary)
                Text("Antigravity").font(.system(size: 17, weight: .bold)).foregroundStyle(palette.primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("总用量").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.primary).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 2)
                    Text(display.text(total))
                        .font(.system(size: 14, weight: .bold)).monospacedDigit().foregroundStyle(palette.primary)
                }
                QuotaBar(remaining: total, tint: .antigravity, display: display, palette: palette)
                Label(ResetTimestamp.text(totalReset), systemImage: "clock")
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                if let tier = snapshot?.usage.tier { Text(tier).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 2)
                HStack(spacing: 3) {
                    Text("更新")
                    if let updatedAt = snapshot?.updatedAt { Text(updatedAt, style: .time) } else { Text("—") }
                    if snapshot?.isStale() == true { Text("· 已过期") }
                }.layoutPriority(1)
            }.font(.system(size: 9)).foregroundStyle(palette.secondary)
            if snapshot == nil { Text("打开 App 刷新 Antigravity").font(.system(size: 9)).foregroundStyle(palette.secondary) }
        }
    }
}

struct ClaudeCompactView: View {
    let snapshot: ClaudeSnapshot?
    let failed: Bool
    let cacheOnly: Bool
    let palette: ThemePalette
    var display: UsageDisplay = .remaining
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude").font(.system(size: 19, weight: .bold)).foregroundStyle(palette.primary)
            row("5h", snapshot?.fiveHour)
            row("7d", snapshot?.sevenDay)
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                Text("更新")
                if let date = snapshot?.updatedAt { Text(date, style: .time) } else { Text("—") }
            }.font(.system(size: 9)).foregroundStyle(palette.secondary)
            if cacheOnly { Text("仅缓存 · 组件无刷新授权，打开 App").font(.system(size: 9)).foregroundStyle(palette.secondary).lineLimit(1).minimumScaleFactor(0.7) }
            else if failed { Text("刷新失败 · 保留缓存").font(.system(size: 9)).foregroundStyle(palette.secondary) }
        }
    }
    func row(_ title: String, _ window: ClaudeWindow?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 2)
                Text(display.text(window?.remaining))
                    .font(.system(size: 14, weight: .bold)).monospacedDigit()
            }.foregroundStyle(palette.primary)
            QuotaBar(remaining: window?.remaining, tint: .claude, display: display, palette: palette)
            Label(ResetTimestamp.text(window?.reset), systemImage: "clock")
                .font(.system(size: 9)).monospacedDigit().foregroundStyle(palette.secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct CompactUsageView: View {
    let snapshot: UsageSnapshot?
    var failed = false
    var refreshing = false
    var sharingUnavailable = false
    var cacheOnly = false
    var palette: ThemePalette = .dark
    var display: UsageDisplay = .remaining
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Codex").font(.system(size: 19, weight: .bold)).foregroundStyle(palette.primary).lineLimit(1).minimumScaleFactor(0.7)
            // Both quota rows are always rendered, in a fixed order, so the 7-day row cannot be
            // pushed out by a longer label or by a missing 5-hour window.
            row("5h", window: snapshot?.usage.rateLimit?.primaryWindow)
            row("7d", window: snapshot?.usage.rateLimit?.secondaryWindow)
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                if let label = snapshot?.accountLabel, !label.isEmpty {
                    Text(label).lineLimit(1).truncationMode(.middle)
                    Text("·")
                }
                HStack(spacing: 3) {
                    Text("更新")
                    if let updatedAt = snapshot?.updatedAt { Text(updatedAt, style: .time) }
                    else { Text("—") }
                    if snapshot?.isStale() == true { Text("· 已过期") }
                }.layoutPriority(1)
            }.font(.system(size: 9)).foregroundStyle(palette.secondary)
            if sharingUnavailable { Text("共享容器不可用 · 打开 App 诊断").font(.system(size: 9)).foregroundStyle(palette.secondary) }
            else if cacheOnly { Text(snapshot == nil ? "无缓存 · 组件无刷新授权，打开 App" : "仅缓存 · 组件无刷新授权，打开 App").font(.system(size: 9)).foregroundStyle(palette.secondary).lineLimit(1).minimumScaleFactor(0.7) }
            else if refreshing { Text("刷新中…").font(.system(size: 9)).foregroundStyle(palette.secondary).accessibilityLabel("刷新中") }
            else if failed { Text("刷新失败 · 保留缓存").font(.system(size: 9)).foregroundStyle(palette.secondary) }
            else if snapshot == nil { Text("打开 App 登录").font(.system(size: 9)).foregroundStyle(palette.secondary) }
        }
    }
    func row(_ label: String, window: UsageWindow?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.primary)
                Spacer(minLength: 2)
                Text(display.text(window?.remaining))
                    .font(.system(size: 14, weight: .bold)).monospacedDigit().foregroundStyle(palette.primary)
            }
            QuotaBar(remaining: window?.remaining, tint: .codex, display: display, palette: palette)
            Label(ResetTimestamp.text(window?.resetDate), systemImage: "clock")
                .font(.system(size: 9)).monospacedDigit().foregroundStyle(palette.secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct DeepSeekBalanceView: View {
    let snapshot: DeepSeekSnapshot?
    var palette: ThemePalette = .dark
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DeepSeek").font(.system(size: 19, weight: .bold)).foregroundStyle(palette.primary)
            if let snapshot {
                ForEach(Array(snapshot.balance.balanceInfos.enumerated()), id: \.offset) { _, info in
                    Text(info.currency + " 余额").font(.system(size: 10)).foregroundStyle(palette.secondary)
                    Text(NSDecimalNumber(decimal: info.total).stringValue)
                        .font(.system(size: 24, weight: .bold)).monospacedDigit().foregroundStyle(palette.primary)
                        .lineLimit(1).minimumScaleFactor(0.4)
                }
                Text(snapshot.balance.isAvailable ? "可供 API 调用" : "余额不可供 API 调用").font(.system(size: 9)).foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
                Text("更新 \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))\(snapshot.isStale() ? " · 已过期" : "")")
                    .font(.system(size: 9)).foregroundStyle(palette.secondary).lineLimit(1)
            } else {
                Text("—").font(.system(size: 22, weight: .bold)).foregroundStyle(palette.primary)
                Spacer(minLength: 0)
                Text("打开 App 添加 Key").font(.system(size: 9)).foregroundStyle(palette.secondary)
            }
        }
    }
}
