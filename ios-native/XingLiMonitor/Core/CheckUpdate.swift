// GitHub release 检查 —— 对齐 Flutter 版 app/lib/check_update.dart。

import Foundation

struct CheckUpdateResult {
    var latestTag: String?
    var body: String?
    var isNewer = false
    var isError = false
    var error: String?

    var summary: String {
        if isError { return "检查失败：\(error ?? "")" }
        guard let tag = latestTag, !tag.isEmpty else { return "无 release 信息" }
        if isNewer { return "有新版本: v\(tag)" }
        return "当前已是最新版本 (v\(tag))"
    }
}

enum CheckUpdate {
    /// GitHub 仓库（owner/name）—— 跟 Dart 版写死同一个
    static let repo = "mzhscan/monitor-status"

    static var releasePage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }
    static var readmeUrl: URL { URL(string: "https://github.com/\(repo)#readme")! }

    static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.0.0"
    }

    /// Fetch the latest release. 网络 / 解析错 → isError
    static func fetchLatest() async -> CheckUpdateResult {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                var r = CheckUpdateResult(); r.isError = true; r.error = "响应不是 HTTP"; return r
            }
            if http.statusCode != 200 {
                var r = CheckUpdateResult(); r.isError = true
                r.error = "GitHub 返回 HTTP \(http.statusCode)"; return r
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let j = obj as? [String: Any] else {
                var r = CheckUpdateResult(); r.isError = true; r.error = "解析失败"; return r
            }
            let tag = j["tag_name"] as? String ?? ""
            let body = j["body"] as? String ?? ""
            let remote = parseSemver(tag)
            let local = parseSemver(currentVersion())
            var isNewer = false
            if let remote, let local {
                isNewer = compare(remote, local) > 0
            }
            return CheckUpdateResult(latestTag: tag, body: body, isNewer: isNewer)
        } catch {
            var r = CheckUpdateResult()
            r.isError = true
            r.error = "\(error.localizedDescription)"
            return r
        }
    }

    static func parseSemver(_ s: String) -> [Int]? {
        // ^v?(\d+)\.(\d+)\.(\d+)
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        var nums: [Int] = []
        var rest = Substring(trimmed)
        if rest.first == "v" { rest = rest.dropFirst() }
        for _ in 0..<3 {
            var digits = Substring()
            for ch in rest {
                if ch.isNumber { digits.append(ch) } else { break }
            }
            guard !digits.isEmpty, let n = Int(digits) else { return nil }
            nums.append(n)
            rest = rest.dropFirst(digits.count)
            if nums.count < 3 {
                guard rest.first == "." else { return nil }
                rest = rest.dropFirst()
            }
        }
        return nums
    }

    /// a > b 返回正数
    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<3 where a[i] != b[i] {
            return a[i] - b[i]
        }
        return 0
    }
}
