import Foundation

struct LimitWindow: Codable, Equatable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?

    var used: Double? {
        guard let value = usedPercent, value.isFinite else { return nil }
        return min(100, max(0, value))
    }

    var remaining: Double? { used.map { 100 - $0 } }
    var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }

    func percentage(showUsed: Bool) -> String {
        guard let value = showUsed ? used : remaining else { return "—" }
        // Do not round a nearly depleted quota up to 100% or down to zero.
        if value > 0 && value < 1 { return "<1%" }
        if value < 100 && value > 99 { return ">99%" }
        return "\(Int(value.rounded()))%"
    }

    func hasExpired(at date: Date = Date()) -> Bool {
        resetDate.map { $0 <= date } ?? false
    }
}

struct RateLimitBucket: Codable {
    let limitId: String?
    let primary: LimitWindow?
    let secondary: LimitWindow?
    let planType: String?

    func window(minutes: Int) -> LimitWindow? {
        [primary, secondary].compactMap { $0 }.first { $0.windowDurationMins == minutes }
    }
}

struct RateLimitResponse: Decodable {
    let rateLimits: RateLimitBucket?
    let rateLimitsByLimitId: [String: RateLimitBucket]?

    var codex: RateLimitBucket? {
        if let bucket = rateLimitsByLimitId?["codex"] { return bucket }
        guard let legacy = rateLimits,
              legacy.limitId == nil || legacy.limitId == "codex" else { return nil }
        return legacy
    }
}

struct QuotaSnapshot {
    let bucket: RateLimitBucket
    let fetchedAt: Date
    let executable: URL

    var fiveHour: LimitWindow? { bucket.window(minutes: 300) }
    var weekly: LimitWindow? { bucket.window(minutes: 10_080) }
    var hasExpiredWindow: Bool {
        [fiveHour, weekly].compactMap { $0 }.contains { $0.hasExpired() }
    }
}

enum QuotaError: LocalizedError {
    case cliMissing
    case timedOut
    case serverClosed
    case invalidResponse
    case unavailableBucket
    case rpc(Int, String)

    var errorDescription: String? {
        switch self {
        case .cliMissing:
            return "未找到 Codex。请安装 Codex 桌面端或 CLI，或在设置中选择 Codex 可执行文件。"
        case .timedOut:
            return "读取额度超时，请检查网络后重试。"
        case .serverClosed:
            return "Codex 服务提前退出。请确认 Codex 能正常启动，且本地配置有效。"
        case .invalidResponse:
            return "Codex 返回的数据格式无法识别，请更新 Codex 后重试。"
        case .unavailableBucket:
            return "当前账户未提供 Codex 额度。请使用 ChatGPT 账户登录 Codex；API Key 登录不提供此额度。"
        case .rpc(_, let message):
            let lower = message.lowercased()
            if lower.contains("auth") || lower.contains("login") || lower.contains("sign in") || lower.contains("401") {
                return "Codex 登录已失效或尚未登录。请打开 Codex 登录，再点击刷新。"
            }
            return "读取额度失败：\(message.prefix(240))"
        }
    }
}
