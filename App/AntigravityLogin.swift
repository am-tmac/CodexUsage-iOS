import SwiftUI
import Network
import SafariServices

/// One-shot loopback listener for the Google redirect. Google rejects custom schemes for the
/// Antigravity OAuth client (verified: `invalid_request`) and only accepts `http://localhost:…`,
/// so the App opens the consent page in an in-app browser and catches the redirect itself on
/// 127.0.0.1. Nothing is exposed beyond this device.
final class LoopbackOAuthListener {
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
    private var port: UInt16 = AntigravityOAuth.preferredPort
    private var finish: ((Result<String, Error>) -> Void)?
    private var settled = false
    private var expectedState = ""

    enum ListenerError: LocalizedError {
        case busy, alreadyStarted
        var errorDescription: String? {
            switch self {
            case .busy: return "本机端口被占用，登录无法开始（可改用手动粘贴刷新令牌）"
            case .alreadyStarted: return "登录已在进行中"
            }
        }
    }

    /// Binds 127.0.0.1 on the IDE's port, falling back to another loopback port (Google allows any
    /// port for a loopback client). Returns the port the redirect URI must name.
    func start(expectedState: String, completion: @escaping (Result<String, Error>) -> Void) async throws -> UInt16 {
        guard listener == nil else { throw ListenerError.alreadyStarted }
        finish = completion
        settled = false
        self.expectedState = expectedState
        for candidate in [AntigravityOAuth.preferredPort, UInt16.random(in: 49_152...65_535)] {
            if await bind(candidate) { return candidate }
        }
        finish = nil
        throw ListenerError.busy
    }

    private func bind(_ candidate: UInt16) async -> Bool {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: candidate)!)
        guard let candidateListener = try? NWListener(using: parameters) else { return false }
        candidateListener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener = candidateListener
        return await withCheckedContinuation { continuation in
            let gate = ResumeGate()
            candidateListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    self?.port = candidate
                    candidateListener.stateUpdateHandler = nil
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    guard gate.claim() else { return }
                    candidateListener.cancel()
                    if self?.listener === candidateListener { self?.listener = nil }
                    continuation.resume(returning: false)
                default: break
                }
            }
            candidateListener.start(queue: .main)
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
            let result = AntigravityOAuth.parseCallback(line, expectedState: expectedState)
            let body: String
            switch result {
            case .code:
                body = Self.page(title: "登录完成", detail: "可以关闭此页，回到 Codex 用量继续。")
            case .failure:
                body = Self.page(title: "登录未完成", detail: "Google 未完成授权，请回到 App 重试。")
            case nil:
                body = Self.page(title: "等待登录", detail: "这个地址只用于接收 Google 登录回调。")
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard let result else { return }
            switch result {
            case .code(let code): self.succeed(code)
            case .failure: self.fail(AntigravityError.unauthorized)
            }
        }
    }

    private func succeed(_ code: String) {
        guard !settled else { return }
        settled = true
        listener?.cancel(); listener = nil
        let completion = finish; finish = nil
        completion?(.success(code))
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

/// In-app browser: the consent page runs inside our own process, so the App is never suspended
/// while the user signs in and the loopback redirect is caught immediately.
struct AntigravityWebSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

@MainActor
final class AntigravityLogin: ObservableObject {
    @Published var authorizeURL: URL?
    @Published var message: String?
    @Published var busy = false
    private var listener: LoopbackOAuthListener?
    private var verifier = ""
    private var redirect = ""
    private var state = ""

    func start() {
        guard authorizeURL == nil, !busy else { return }
        guard AntigravityAPI.isConfigured else {
            message = "当前构建未配置 Antigravity OAuth 客户端"
            return
        }
        message = nil
        busy = true
        Task { @MainActor [weak self] in
          guard let self else { return }
          let listener = LoopbackOAuthListener()
          do {
            let verifier = AntigravityOAuth.codeVerifier()
            let challenge = AntigravityOAuth.codeChallenge(verifier)
            let state = AntigravityOAuth.codeVerifier()
            let port = try await listener.start(expectedState: state) { [weak self] result in
                Task { @MainActor in await self?.finished(result) }
            }
            self.verifier = verifier
            self.state = state
            self.redirect = AntigravityOAuth.redirectURI(port: port)
            self.listener = listener
            authorizeURL = AntigravityOAuth.authorizeURL(redirectURI: redirect, challenge: challenge, state: state)
          } catch {
            listener.stop()
            busy = false
            message = error.localizedDescription
          }
        }
    }

    func cancel() {
        listener?.stop()
        listener = nil
        authorizeURL = nil
        busy = false
        verifier = ""
        state = ""
    }

    private func finished(_ result: Result<String, Error>) async {
        authorizeURL = nil
        // Stay busy until the exchange is done: a second tap on 登录 during the await would
        // otherwise start a new flow whose verifier/state this one then wipes.
        defer { busy = false; listener = nil; verifier = ""; state = "" }
        switch result {
        case .success(let code):
            do {
                let api = AntigravityAPI()
                let refresh = try await api.exchange(code: code, verifier: verifier, redirectURI: redirect)
                try await AntigravityService.shared.install(token: refresh)
                message = "登录成功，已保存刷新令牌"
                NotificationCenter.default.post(name: .antigravitySignedIn, object: nil)
            } catch { message = error.localizedDescription }
        case .failure(let error):
            message = error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let antigravitySignedIn = Notification.Name("CodexUsage.antigravitySignedIn")
}
