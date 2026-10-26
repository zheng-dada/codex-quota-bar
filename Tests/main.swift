import Foundation
import Darwin

signal(SIGPIPE, SIG_IGN)
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

func decode(_ json: String) throws -> RateLimitResponse {
    try JSONDecoder().decode(RateLimitResponse.self, from: Data(json.utf8))
}

let response = try decode("""
{"rateLimits":{"limitId":"other","primary":{"usedPercent":99,"windowDurationMins":300}},
 "rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":13,"windowDurationMins":10080},"secondary":{"usedPercent":40,"windowDurationMins":300}}}}
""")
check(response.codex?.window(minutes: 300)?.remaining == 60, "prefer codex bucket and match duration, not primary position")
check(response.codex?.window(minutes: 10080)?.remaining == 87, "weekly duration")
let legacy = try decode("""
{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300},"secondary":null}}
""")
check(legacy.codex?.window(minutes: 300)?.remaining == 75, "legacy response")
check(legacy.codex?.window(minutes: 10080) == nil, "missing weekly is unknown")
let wrong = try decode("""
{"rateLimits":{"limitId":"other","primary":{"usedPercent":20,"windowDurationMins":300}}}
""")
check(wrong.codex == nil, "never use another quota bucket")
let unknown = LimitWindow(usedPercent: nil, windowDurationMins: 300, resetsAt: nil)
check(unknown.percentage(showUsed: false) == "—", "null is not zero usage")
check(unknown.resetDate == nil, "null reset")
let exhausted = LimitWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: 1)
check(exhausted.percentage(showUsed: false) == "0%", "exhausted")
check(exhausted.hasExpired(), "expired window remains explicit")
check(exhausted.remaining == 0, "never infer reset from clock")
check(LimitWindow(usedPercent: 120, windowDurationMins: 300, resetsAt: nil).remaining == 0, "clamp overshoot")
check(LimitWindow(usedPercent: -5, windowDurationMins: 300, resetsAt: nil).remaining == 100, "clamp negative")
check(LimitWindow(usedPercent: 99.9, windowDurationMins: 300, resetsAt: nil).percentage(showUsed: false) == "<1%", "small positive remaining")
check(LimitWindow(usedPercent: 0.1, windowDurationMins: 300, resetsAt: nil).percentage(showUsed: false) == ">99%", "almost full")
check(LimitWindow(usedPercent: 40, windowDurationMins: 300, resetsAt: nil).percentage(showUsed: true) == "40%", "used mode")

let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
let requestLog = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.path
setenv("CODEX_QUOTA_TEST_MODE", "normal", 1)
setenv("CODEX_QUOTA_TEST_LOG", requestLog, 1)
try? FileManager.default.removeItem(atPath: requestLog)
let snapshot = try CodexClient.fetch(customPath: fixture)
check(snapshot.fiveHour?.remaining == 60, "real transport reads fragmented five-hour frame")
check(snapshot.weekly?.remaining == 87, "real transport reads weekly")
let methods = try String(contentsOfFile: requestLog, encoding: .utf8).split(separator: "\n").map(String.init)
check(methods == ["initialize", "initialized", "account/rateLimits/read"], "only quota requests, no thread or turn")
unsetenv("CODEX_QUOTA_TEST_LOG")

for mode in ["auth", "missing", "invalid", "exit", "timeout"] {
    setenv("CODEX_QUOTA_TEST_MODE", mode, 1)
    let started = Date()
    do {
        _ = try CodexClient.fetch(customPath: fixture, timeout: 0.35)
        check(false, "\(mode) must fail")
    } catch let error as QuotaError {
        switch (mode, error) {
        case ("auth", .rpc), ("missing", .unavailableBucket), ("invalid", .invalidResponse), ("exit", .serverClosed), ("timeout", .timedOut):
            check(true, "\(mode) categorized")
        default: check(false, "unexpected \(mode) error: \(error)")
        }
        if mode == "auth" { check(error.localizedDescription.contains("登录"), "actionable auth error") }
    }
    check(Date().timeIntervalSince(started) < 3, "\(mode) cleanup bounded")
}
unsetenv("CODEX_QUOTA_TEST_MODE")
do {
    _ = try CodexLocator.find(customPath: "/nonexistent/codex")
    check(false, "invalid custom executable must fail")
} catch { check(true, "invalid path") }
print("PASS: \(checks) checks (models, bucket selection, stdio framing, handshake, failures, timeout, cleanup)")
