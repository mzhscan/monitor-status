// Per-agent HTTP client —— 对齐 Flutter 版 app/lib/api.dart。
//
// 没有中心 backend：每台 server 的 agent 直接 HTTP(S) 拉，X-Agent-Token
// 做身份验证。自签/不可信证书走 TOFU pin（TrustStore）。
//
// relay 模式（v2.4.26+）：endpoint 是 relay 的 base URL，token 是
// reverse-agent push 用的 token（relay 按 token 路由到内网机器）。

import Foundation

// MARK: - 错误类型 + 中文解释（对齐 errors.dart）

enum AgentError: Error {
    case httpStatus(Int)
    case untrustedCert(fingerprint: String)
    case parseFailed
    case network(String)
    case timedOut
}

/// 用户面向的错误信息。永远返回中文（对齐 Dart explainError）。
func explainError(_ e: Error) -> String {
    switch e {
    case let AgentError.httpStatus(code):
        return "agent 返回 HTTP \(code)：\(httpStatusText(code))"
    case AgentError.untrustedCert:
        return "证书不被系统信任（自签/未知 CA）"
    case AgentError.parseFailed:
        return "数据格式错误"
    case AgentError.timedOut:
        return "请求超时（5 秒）"
    case let AgentError.network(msg):
        return msg
    case let urlError as URLError:
        switch urlError.code {
        case .cannotConnectToHost:
            return "连接被拒：agent 没在跑，或端口/防火墙拦了"
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "网络不通：手机没网或到 server 的路由断了"
        case .cannotFindHost:
            return "DNS 解析失败：域名打错或者 DNS 不通"
        case .timedOut:
            return "连接超时：网络太慢或 server 没响应"
        case .serverCertificateUntrusted, .secureConnectionFailed,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
            return "证书校验失败"
        case .cancelled:
            return "请求已取消"
        default:
            return "网络错误：\(urlError.localizedDescription)"
        }
    default:
        return "\(e)"
    }
}

/// 常见 HTTP 状态码的中文解释（对齐 errors.dart _httpStatusText）
func httpStatusText(_ code: Int) -> String {
    switch code {
    case 400: return "请求格式错"
    case 401: return "token 无效或缺失"
    case 403: return "被拒绝"
    case 404: return "路径不存在（agent 没装好？）"
    case 408: return "请求超时"
    case 429: return "请求太频繁，被限流"
    case 500: return "agent 内部错误"
    case 502: return "agent 上游错误（bad gateway）"
    case 503: return "agent 数据未就绪（启动中 / 长时间没更新）"
    case 504: return "agent 上游超时"
    default: return "见 HTTP 标准"
    }
}

// MARK: - TLS delegate（TOFU）

final class AgentSessionDelegate: NSObject, URLSessionDelegate {
    /// 测试连接场景：系统校验失败 + 没 pin 时，捕获叶子证书指纹后失败，
    /// 让 UI 弹「信任此证书？」对话框。
    let captureMode: Bool
    private(set) var capturedFingerprint: String?

    init(captureMode: Bool) {
        self.captureMode = captureMode
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 1) 系统信任优先（Let's Encrypt / DigiCert 等自动通过）
        var cfError: CFError?
        if SecTrustEvaluateWithError(trust, &cfError) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fp = TrustStore.fingerprint(of: leaf)
        // 2) 用户 TOFU pin（key 格式跟 Flutter 版一致：scheme://host:port）
        let ps = challenge.protectionSpace
        let scheme = (ps.protocol ?? "").isEmpty ? "https" : ps.protocol!
        let candidates = ["\(scheme)://\(ps.host):\(ps.port)", "\(scheme)://\(ps.host)"]
        if candidates.contains(where: { TrustStore.isTrusted(origin: $0, fingerprint: fp) }) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        // 3) 主流公签 issuer 放行（对齐 Dart badCertificateCallback 的 workaround：
        //    IP SAN / hostname check 差异；token 仍做身份验证）
        if TrustStore.issuerIsKnown(leaf) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        // 4) 不可信：capture 模式记录指纹供 UI 弹信任框，否则直接失败
        if captureMode {
            capturedFingerprint = fp
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

// MARK: - AgentClient

struct AgentTestResult {
    var success: Bool
    var message: String?
    var error: String?
    /// 非空 = TLS 不可信，UI 应弹信任确认框（展示指纹）
    var untrustedFingerprint: String?
}

final class AgentClient {
    /// 拉数据的 base URL（不含 /api/report）：直连 = agent URL，relay = relay URL
    let endpoint: String
    let token: String
    private let session: URLSession
    private let delegate: AgentSessionDelegate

    init(endpoint: String, token: String, captureMode: Bool = false) {
        self.endpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        self.token = token
        self.delegate = AgentSessionDelegate(captureMode: captureMode)
        let config = URLSessionConfiguration.ephemeral
        // Bug #6 fix: 5s client-side timeout，跟 agent 自己的 5s probe 间隔对齐
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private var headers: [String: String] {
        ["X-Agent-Token": token, "Accept": "application/json"]
    }

    /// Health probe —— agent / relay 都在根 /health 监听
    private func health() async throws -> (Int, Data) {
        try await get("\(endpoint)/health")
    }

    /// Full report。非 200 抛错让 store 标离线。
    func fetchReport() async throws -> AgentData {
        let (status, body) = try await get("\(endpoint)/api/report")
        if status != 200 {
            // 抛带 HTTP 码的错误，explainError 会翻译成中文
            throw AgentError.httpStatus(status)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body),
              let j = obj as? JSON,
              let data = AgentData(j) else {
            throw AgentError.parseFailed
        }
        return data
    }

    /// 测试连接：永不抛错，结果编码进 AgentTestResult（对齐 Dart test()）
    func test() async -> AgentTestResult {
        do {
            let (status, _) = try await health()
            if status == 200 {
                return AgentTestResult(success: true, message: "连接成功")
            }
            return AgentTestResult(success: false,
                                   error: "agent 返回 HTTP \(status)")
        } catch {
            // TLS 被拒 + capture 到指纹 → 让 UI 弹信任框
            if let fp = delegate.capturedFingerprint {
                return AgentTestResult(success: false,
                                       error: explainError(error),
                                       untrustedFingerprint: fp)
            }
            return AgentTestResult(success: false, error: explainError(error))
        }
    }

    private func get(_ urlStr: String) async throws -> (Int, Data) {
        guard let url = URL(string: urlStr) else {
            throw AgentError.network("URL 无效：\(urlStr)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw AgentError.network("响应不是 HTTP")
        }
        return (http.statusCode, data)
    }
}
