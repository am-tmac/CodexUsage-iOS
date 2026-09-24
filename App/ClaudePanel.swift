import SwiftUI
import Network
import SafariServices
import WidgetKit

/// One-shot loopback listener for the Claude redirect.
///
/// The Claude Code OAuth client registers exactly `http://localhost:54545/callback`, so the port is
/// not negotiable and there is no random-port fallback: a busy port fails the flow with a named
/// reason instead of registering a redirect the server would reject. The redirect lands on
/// 127.0.0.1 only, and the authorization code is exchanged directly with Anthropic — it never goes
/// through any third party. `ASWebAuthenticationSession` cannot receive a loopback redirect (it
/// only hands back a custom scheme), which is why the App runs this listener itself and presents
/// the consent page with `SFSafariViewController` in-app: the presenting process stays alive, so
/// the user cannot be suspended mid-login and the listener always answers.
final class ClaudeOAuthListener {
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
    private var listener: NWListener?
    private var finish: ((Result<ClaudeOAuth.Callback, Error>) -> Void)?
    private var settled = false
    private var expectedState = ""

    /// Binds 127.0.0.1:54545 and stays open until one valid callback arrives.
    func start(expectedState: String, completion: @escaping (Result<ClaudeOAuth.Callback, Error>) -> Void) async throws {
        guard listener == nil else { throw ClaudeFailure.listenerBusy }
        self.finish = completion
        self.settled = false
        self.expectedState = expectedState
        guard await bind() else {
            finish = nil
            throw ClaudeFailure.listenerBusy
        }
    }

    private func bind() async -> Bool {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                    port: NWEndpoint.Port(rawValue: ClaudeOAuth.callbackPort)!)
        guard let candidate = try? NWListener(using: parameters) else { return false }
        candidate.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener = candidate
        return await withCheckedContinuation { continuation in
            let gate = ResumeGate()
            candidate.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    candidate.stateUpdateHandler = nil
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    guard gate.claim() else { return }
                    candidate.cancel()
                    if self?.listener === candidate { self?.listener = nil }
                    continuation.resume(returning: false)
                default: break
                }
            }
            candidate.start(queue: .main)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        finish = nil
        settled = true
        expectedState = ""
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else { return }
            let line = text.split(separator: "\r\n").first.map(String.init) ?? text
            let result = ClaudeOAuth.parseCallback(line, expectedState: expectedState)
            let body: String
            switch result {
            case .code:
                body = Self.page(title: "登录完成", detail: "可以关闭此页，回到 Codex 用量继续。")
            case .failure:
                body = Self.page(title: "登录未完成", detail: "Claude 未完成授权，请回到 App 重试。")
            case nil:
                body = Self.page(title: "等待登录", detail: "这个地址只用于接收 Claude 登录回调。")
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard let result else { return }
            switch result {
            case .code: self.succeed(result)
            case .failure: self.fail(ClaudeFailure.unauthorized)
            }
        }
    }

    private func succeed(_ callback: ClaudeOAuth.Callback) {
        guard !settled else { return }
        settled = true
        listener?.cancel(); listener = nil
        let completion = finish; finish = nil
        completion?(.success(callback))
    }

    private func fail(_ error: Error) {
        guard !settled else { return }
        settled = true
        listener?.cancel(); listener = nil
        let completion = finish; finish = nil
        completion?(.failure(error))
    }

    private static func page(title: String, detail: String) -> String {
        "<!doctype html><meta name=viewport content=\"width=device-width,initial-scale=1\"><body style=\"font-family:-apple-system;padding:2rem;background:#0b0b0f;color:#fff\"><h2>\(title)</h2><p style=\"color:#aaa\">\(detail)</p></body>"
    }
}

/// In-app browser for the consent page: our own process keeps running, so the loopback redirect is
/// always caught. This is the same presentation the reference app uses for its system sign-in
/// sheet, without a custom scheme (which this client rejects).
struct ClaudeWebSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

@MainActor
final class ClaudeLogin: ObservableObject {
    @Published var authorizeURL: URL?
    @Published var message: String?
    @Published var busy = false
    /// The console flow shows a copyable `code#state`; the field only ever holds that one-time code.
    @Published var showCodePaste = false
    @Published var codeInput = ""
    private var listener: ClaudeOAuthListener?
    private var verifier = ""
    private var state = ""
    private var redirect = ClaudeOAuth.redirectURI

    /// Primary path: approve in-app and let the code come back on 127.0.0.1.
    func start() {
        guard authorizeURL == nil, !busy else { return }
        begin(redirectURI: ClaudeOAuth.redirectURI, showPaste: false)
    }
    /// Fallback when the loopback callback cannot be used on this device or network: approve in the
    /// same in-app browser, copy the one-time code the page shows, paste it here.
    func startCodePaste() {
        guard !busy else { return }
        // Any loopback attempt is abandoned first: the sheet is rebuilt around the console redirect
        // so the page the user is looking at is the one that shows the copyable code.
        listener?.stop()
        listener = nil
        authorizeURL = nil
        showCodePaste = true
        Task { @MainActor in begin(redirectURI: ClaudeOAuth.consoleRedirectURI, showPaste: true) }
    }

    private func begin(redirectURI: String, showPaste: Bool) {
        message = nil
        busy = true
        let verifier = ClaudeOAuth.codeVerifier()
        let state = ClaudeOAuth.codeVerifier()
        self.verifier = verifier
        self.state = state
        self.redirect = redirectURI
        self.showCodePaste = showPaste
        self.codeInput = ""
        let challenge = ClaudeOAuth.codeChallenge(verifier)
        guard redirectURI == ClaudeOAuth.redirectURI else {
            // No loopback listener for the console redirect: the code is copied by the user.
            authorizeURL = ClaudeOAuth.authorizeURL(state: state, challenge: challenge, redirectURI: redirectURI)
            listener = nil
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let listener = ClaudeOAuthListener()
            do {
                try await listener.start(expectedState: state) { [weak self] result in
                    Task { @MainActor in await self?.finished(result) }
                }
                self.listener = listener
                authorizeURL = ClaudeOAuth.authorizeURL(state: state, challenge: challenge, redirectURI: redirectURI)
            } catch {
                listener.stop()
                busy = false
                message = error.localizedDescription
            }
        }
    }

    /// Exchange the pasted one-time code. Everything else is rejected by the parser.
    func submitPastedCode() {
        guard case .code(let code, let pastedState)? = ClaudeOAuth.parsePastedCode(codeInput) else {
            message = "授权码格式无法识别，请粘贴页面上显示的整段内容。"
            return
        }
        let state = pastedState.isEmpty ? self.state : pastedState
        codeInput = ""
        showCodePaste = false
        authorizeURL = nil
        busy = true
        Task { @MainActor in await complete(code: code, state: state, redirectURI: ClaudeOAuth.consoleRedirectURI) }
    }

    func cancel() {
        listener?.stop()
        listener = nil
        authorizeURL = nil
        busy = false
        verifier = ""
        state = ""
        codeInput = ""
        showCodePaste = false
    }

    private func finished(_ result: Result<ClaudeOAuth.Callback, Error>) async {
        authorizeURL = nil
        switch result {
        case .success(.code(let code, let state)):
            busy = true
            await complete(code: code, state: state, redirectURI: redirect)
        case .success(.failure):
            busy = false
            message = "Claude 未完成授权，请重试。"
        case .failure(let error):
            busy = false
            message = error.localizedDescription
        }
        listener = nil
        verifier = ""
        state = ""
    }

    private func complete(code: String, state: String, redirectURI: String) async {
        defer { busy = false }
        do {
            let tokens = try await ClaudeAPI().exchange(code: code, verifier: verifier, state: state, redirectURI: redirectURI)
            guard let refresh = tokens.refreshToken else { throw ClaudeFailure.malformed }
            try await ClaudeService.shared.install(refreshToken: refresh)
            message = "登录成功，已保存刷新令牌（访问令牌未保存）。"
            NotificationCenter.default.post(name: .claudeSignedIn, object: nil)
        } catch {
            message = (error as? ClaudeFailure)?.localizedDescription ?? "Claude 登录失败，请重试。"
        }
    }
}

extension Notification.Name {
    static let claudeSignedIn = Notification.Name("CodexUsage.claudeSignedIn")
}

struct ClaudePanel: View {
    @ObservedObject var model: UsageModel
    let palette: AppPalette
    @StateObject private var login = ClaudeLogin()
    @State private var consent = false
    @State private var message: String?
    var body: some View {
        AppCard(title: "Claude · Claude 账号登录", caption: "Claude Code 的 OAuth 客户端 · 非官方兼容方式",
                systemImage: "sparkle", palette: palette) {
            VStack(alignment: .leading, spacing: 12) {
                // Said plainly and up front: this is a compatibility mechanism, not an approval.
                Text("Anthropic 不授权第三方 App 提供 Claude.ai 登录，也不授权收集、存储或转交 Claude.ai 会话令牌。此面板用 Claude Code 自己的 OAuth 客户端登录（与你本机 CLIProxyAPI 用的是同一机制），只读取订阅用量；它是兼容做法，可能随时被更改或封禁，随时可能失效。App 不会接收你的密码。")
                    .font(.footnote).foregroundStyle(palette.warning)
                if model.claudeInstalled {
                    Text("已保存一个刷新令牌（未保存访问令牌）。每次刷新时用它换取短期访问令牌，只调用账号用量接口，不代你发起任何模型请求。若失效，请在下方移除后重新登录。")
                        .font(.footnote).foregroundStyle(palette.secondary)
                    HStack(spacing: 12) {
                        Button("立即刷新用量") { Task { await model.refresh() } }.disabled(model.busy)
                        Button("移除 Claude 授权", role: .destructive) {
                            Task {
                                do {
                                    try await ClaudeService.shared.remove()
                                    try DashboardStore.publish()
                                    model.reloadAccounts()
                                    WidgetCenter.shared.reloadAllTimelines()
                                    message = "已移除 Claude 授权"
                                } catch { message = (error as? ClaudeFailure)?.localizedDescription ?? "移除失败，请检查本机储存" }
                            }
                        }
                    }.font(.footnote)
                } else {
                    Toggle("我理解这不是 Anthropic 授权的方式、存在合规与兼容风险，并同意在本机保存刷新令牌", isOn: $consent)
                        .font(.footnote).tint(palette.accent)
                    Button {
                        login.start()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.badge.key")
                            Text(login.busy ? "正在等待 Claude 登录…" : "用 Claude 账号登录")
                        }
                    }.disabled(!consent || login.busy || model.busy).font(.footnote.bold())
                    Text("会弹出 Claude 的官方登录页面（App 内浏览器，与你见到的其他 App 的登录方式一致）。登录完成后授权码直接回到本机 127.0.0.1:54545，只经过 Anthropic。")
                        .font(.footnote).foregroundStyle(palette.secondary)
                    DisclosureGroup("回调端口被占用，或页面无法回到本机？改用授权码") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("打开授权页面") { login.startCodePaste() }
                                .font(.footnote).disabled(!consent || login.busy)
                            Text("在页面里同意后，页面会显示一段 code#state；长按拷贝，关闭页面后粘贴到这里。这只接受一次性的登录授权码。")
                                .font(.footnote).foregroundStyle(palette.secondary)
                            TextField("粘贴一次性授权码（形如 code#state）", text: $login.codeInput)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .font(.system(.footnote, design: .monospaced))
                            Button("完成登录") { login.submitPastedCode() }
                                .font(.footnote).disabled(login.codeInput.isEmpty || login.busy)
                        }.padding(.top, 4)
                    }.font(.footnote).tint(palette.accent)
                }
                Text("刷新令牌只写入本机 Keychain（本机专用、首次解锁后可用），不写共享快照、不写日志、不进聊天。同一签名组的其他 App 可能读取该项目；service 名不是权限隔离。小组件需先通过共享权限握手并明确同意才能自行刷新，否则它显示「打开 App 刷新」按钮——那个按钮只是打开 App，不是组件内刷新。")
                    .font(.footnote).foregroundStyle(palette.secondary)
                if let message { Text(message).font(.footnote).foregroundStyle(palette.secondary) }
                if let loginMessage = login.message { Text(loginMessage).font(.footnote).foregroundStyle(palette.secondary) }
            }
        }
        .sheet(isPresented: Binding(get: { login.authorizeURL != nil }, set: { presented in if !presented { login.cancel() } })) {
            if let url = login.authorizeURL { ClaudeWebSheet(url: url).ignoresSafeArea() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeSignedIn)) { _ in
            model.reloadAccounts()
            Task { await model.refresh() }
        }
    }
}

struct ClaudeAccountCard: View {
    let snapshot: ClaudeSnapshot?
    let palette: AppPalette
    let onRefresh: () -> Void
    let busy: Bool
    var body: some View {
        AppCard(title: "Claude", caption: "Claude 订阅额度 · Claude Code OAuth 兼容方式", systemImage: "sparkle", palette: palette,
                menu: AnyView(Button("刷新 Claude 用量", action: onRefresh).disabled(busy))) {
            VStack(alignment: .leading, spacing: 9) {
                row("5 小时", snapshot?.fiveHour)
                row("7 天", snapshot?.sevenDay)
                Text("更新：" + (snapshot.map { RelativeTime.stamp($0.updatedAt) + ($0.isStale() ? " · 已过期" : "") } ?? "—"))
                    .font(.footnote).foregroundStyle(palette.secondary)
            }
        }
    }
    private func row(_ title: String, _ window: ClaudeWindow?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(palette.secondary)
                Spacer()
                Text(window?.remaining.map { "\(Int($0.rounded()))%" } ?? "—").foregroundStyle(palette.primary)
            }.font(.subheadline).monospacedDigit()
            DashMeter(remainingPercent: window?.remaining, palette: palette)
            Text(ResetTimestamp.text(window?.reset)).font(.caption).foregroundStyle(palette.secondary)
        }
    }
}
