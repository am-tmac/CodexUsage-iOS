import SwiftUI

/// Credential panel for the App-only Antigravity provider. Same rules as the DeepSeek panel: the
/// token is typed here, written straight to this device's Keychain, never echoed back, and the save
/// button stays disabled until the user acknowledges the same-group Keychain risk.
struct AntigravityPanel: View {
    @ObservedObject var model: UsageModel
    var palette: AppPalette
    @StateObject private var login = AntigravityLogin()
    @State private var token = ""
    @State private var acknowledged = false
    @State private var message: String?
    var body: some View {
        AppCard(title: "Antigravity 用量", caption: "Google 刷新令牌 · 只写本机钥匙串",
                systemImage: "sparkles", palette: palette, mark: AnyView(BrandMark(brand: .antigravity, palette: palette))) {
            VStack(alignment: .leading, spacing: 12) {
                if model.antigravityInstalled {
                    Text("已保存一个 Google 刷新令牌。App 用它换取短期访问令牌，只调用 Antigravity 的配额与额度接口，不发送任何请求到模型。")
                        .font(.footnote).foregroundStyle(palette.secondary)
                    HStack(spacing: 12) {
                        Button("立即刷新用量") { Task { await model.refresh() } }.disabled(model.busy)
                        Button("移除刷新令牌", role: .destructive) {
                            Task {
                                do { try await AntigravityService.shared.remove(); model.reloadAccounts(); message = "已移除 Antigravity 令牌" }
                                catch { message = error.localizedDescription }
                            }
                        }
                    }.font(.footnote)
                } else {
                    // Sign-in is the primary path, exactly like the desktop flow CLIProxyAPI uses:
                    // Google only accepts a loopback redirect for this client, so the consent page
                    // opens in-app and the code comes back on 127.0.0.1.
                    Button {
                        login.start()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.badge.key")
                            Text(login.busy ? "正在等待 Google 登录…" : "使用 Google 账号登录")
                        }
                    }.disabled(login.busy || !AntigravityAPI.isConfigured).font(.footnote.bold())
                    if !AntigravityAPI.isConfigured {
                        Text("此开源构建未配置 Antigravity OAuth；请在本机 Private.xcconfig 中提供你有权使用的客户端。")
                            .font(.footnote).foregroundStyle(palette.warning)
                    }
                    Text("在弹出的页面里用你的 Google 账号登录并同意；回调只落在本机 127.0.0.1，授权码不经过任何第三方。")
                        .font(.footnote).foregroundStyle(palette.secondary)
                    Text("或者手动粘贴刷新令牌：").font(.footnote).foregroundStyle(palette.secondary)
                    SecureField("在 iPhone 输入 Google 刷新令牌（refresh token）", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                    Toggle("知悉同组钥匙串风险，允许保存此令牌", isOn: $acknowledged).tint(palette.accent).font(.footnote)
                    Button("保存并刷新用量") {
                        Task {
                            do {
                                try await AntigravityService.shared.install(token: token)
                                token = ""
                                acknowledged = false
                                model.reloadAccounts()
                                await model.refresh()
                                message = "已保存 Antigravity 令牌"
                            } catch { message = error.localizedDescription }
                        }
                    }
                    .disabled(!acknowledged || token.isEmpty || model.busy)
                    .font(.footnote)
                }
                Text("令牌仅写入本机 Keychain，不写快照或日志。购买证书的同组其他 App 可能读取令牌，service 名不是权限隔离。换取访问令牌使用 Antigravity 桌面客户端内置的公开 OAuth 客户端值，不是新的授权范围；App 只读配额与额度，不代你发起任何模型请求。")
                    .font(.footnote).foregroundStyle(palette.secondary)
                if let message { Text(message).font(.footnote).foregroundStyle(palette.secondary) }
                if let loginMessage = login.message { Text(loginMessage).font(.footnote).foregroundStyle(palette.secondary) }
            }
        }
        .sheet(isPresented: Binding(get: { login.authorizeURL != nil }, set: { presented in if !presented { login.cancel() } })) {
            if let url = login.authorizeURL { AntigravityWebSheet(url: url).ignoresSafeArea() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .antigravitySignedIn)) { _ in
            model.reloadAccounts()
            Task { await model.refresh() }
        }
    }
}
