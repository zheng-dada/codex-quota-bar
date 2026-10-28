import Foundation
import Darwin

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    checks += 1
    if (try? condition()) != true { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let base = Date(timeIntervalSince1970: 1_700_000_000)
func record(_ kind: String, _ payload: [String: Any], at date: Date = base) -> Data {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return try! JSONSerialization.data(withJSONObject: ["type": kind, "timestamp": formatter.string(from: date), "payload": payload])
}
func event(_ type: String, _ fields: [String: Any] = [:], at date: Date = base) -> Data {
    var payload = fields
    payload["type"] = type
    return record("event_msg", payload, at: date)
}
func start(_ id: String, at date: Date = base) -> Data {
    event("task_started", ["turn_id": id, "started_at": date.timeIntervalSince1970], at: date)
}
func usage(_ id: String, _ tokens: Any, at date: Date = base) -> Data {
    record("token_usage_record", ["turn_id": id, "turn_token_usage": ["output_tokens": tokens]], at: date)
}
func finish(_ id: String, at date: Date = base.addingTimeInterval(10), extra: [String: Any] = [:]) -> Data {
    var fields: [String: Any] = ["turn_id": id, "started_at": date.addingTimeInterval(-10).timeIntervalSince1970,
                               "completed_at": date.timeIntervalSince1970, "duration_ms": 10_000,
                               "time_to_first_token_ms": 1_250, "error": NSNull()]
    fields.merge(extra) { _, new in new }
    return event("task_complete", fields, at: date)
}
func total(_ tokens: Int) -> Data {
    event("token_count", ["info": ["total_token_usage": ["output_tokens": tokens]]])
}

let parser = RunLogParser()
parser.consume(start("one"))
check(parser.active?.turnID == "one", "start detects a running turn")
check(parser.active?.averageRate(at: base.addingTimeInterval(2)) == nil, "no usage is unknown, never zero")
parser.consume(usage("one", 100, at: base.addingTimeInterval(5)))
parser.consume(usage("one", 100, at: base.addingTimeInterval(5)))
check(parser.active?.averageRate(at: base.addingTimeInterval(5)) == 20, "cumulative usage is not double counted")
check(parser.active?.averageRate(at: base.addingTimeInterval(10)) == 10, "elapsed wait stays in the mean")
parser.consume(usage("different-turn", 999_999))
check(parser.active?.outputTokens == 100, "unrelated turn usage never leaks into running rate")
parser.consume(usage("one", 200))
parser.consume(finish("one"))
check(parser.active == nil, "completion restores idle state")
check(parser.lastCompleted?.averageRate == 20, "completed rate uses final duration and usage")
check(parser.lastCompleted?.firstTokenMilliseconds == 1_250, "latency comes from the recorded first token field")
let previous = parser.lastCompleted
parser.consume(start("two", at: base.addingTimeInterval(20)))
parser.consume(usage("two", 400))
check(parser.lastCompleted == previous, "new running turn preserves previous speed and latency")
parser.consume(event("turn_aborted", ["turn_id": "two"]))
check(parser.active == nil && parser.lastCompleted == previous, "cancel restores weekly quota without replacing successful statistics")
parser.consume(start("three"))
parser.consume(finish("three", extra: ["error": ["message": "failure"]]))
check(parser.active == nil && parser.lastCompleted == previous, "failed task preserves previous completed result")
parser.consume(start("four"))
parser.consume(event("turn_aborted", ["turn_id": "other"]))
check(parser.active?.turnID == "four", "another turn's abort does not stop the current task")
parser.consume(finish("four", at: base.addingTimeInterval(40), extra: ["time_to_first_token_ms": NSNull()]))
check(parser.lastCompleted?.firstTokenMilliseconds == nil && parser.lastCompleted?.averageRate == nil, "missing metrics stay unknown")
parser.consume(usage("four", 300))
check(parser.lastCompleted?.averageRate == 30, "late final usage updates the matching completed record")

let legacy = RunLogParser()
legacy.consume(total(10_000))
legacy.consume(start("legacy"))
legacy.consume(total(10_200))
check(legacy.active?.outputTokens == 200, "legacy cumulative totals subtract the pre-turn baseline")
legacy.consume(total(100))
check(legacy.active?.outputTokens == nil, "compaction counter reset does not create a false speed")
let noBaseline = RunLogParser()
noBaseline.consume(start("tail"))
noBaseline.consume(total(900_000))
check(noBaseline.active?.outputTokens == nil, "tail replay without baseline never uses entire history")
noBaseline.consume(usage("tail", 100))
noBaseline.consume(total(999_999))
check(noBaseline.active?.outputTokens == 100, "explicit per-turn usage takes precedence")
noBaseline.consume(usage("tail", -10))
check(noBaseline.active?.outputTokens == 100, "negative token counts are discarded")
let missingStart = RunLogParser()
missingStart.consume(usage("long-running", 800, at: base))
check(missingStart.active?.turnID == "long-running", "bounded log replay still recognizes a task whose start is outside the tail")
check(missingStart.active?.averageRate(at: base.addingTimeInterval(10)) == nil, "unknown start never invents a live rate")
missingStart.consume(finish("long-running"))
check(missingStart.active == nil && missingStart.lastCompleted?.averageRate == 80, "completion timing recovers bounded-tail statistics")
missingStart.consume(event("turn_aborted", ["turn_id": "cancelled"]))
missingStart.consume(usage("cancelled", 50))
check(missingStart.active == nil, "late usage cannot resurrect a terminated task")

let headerParser = RunLogParser()
headerParser.consume(start("header"))
headerParser.consume(Data("{\"timestamp\":\"2023-11-14T22:13:25.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"text\":\"\(String(repeating: "tool output ", count: 10_000))\"}}}".utf8))
check(headerParser.active?.lastEventAt == base.addingTimeInterval(5), "fast-skipped large events still update task liveness")
headerParser.consume(Data("{\"payload\":{\"type\":\"task_started\",\"turn_id\":\"reordered\",\"started_at\":1700000010},\"type\":\"event_msg\",\"timestamp\":\"2023-11-14T22:13:30Z\"}".utf8))
check(headerParser.active?.turnID == "reordered", "unusual JSON field order retains correct lifecycle parsing")
headerParser.consume(Data("{\"timestamp\":\"2023-11-14T22:13:40Z\",\"type\":\"event\\u005fmsg\",\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"reordered\"}}".utf8))
check(headerParser.active == nil, "escaped header values fall back to full JSON decoding")

let statusLog = RunLogParser()
statusLog.consume(start("success"))
statusLog.consume(usage("success", 200))
statusLog.consume(finish("success"))
check(statusLog.lastOutcome?.kind == .completed, "successful completion records its status")
check(RunStatus.resolve(activeCount: 0, notice: nil, outcome: statusLog.lastOutcome, lastStartedAt: statusLog.lastStartedAt, now: base.addingTimeInterval(11)) == .completed, "completion is briefly green")
check(RunStatus.resolve(activeCount: 0, notice: nil, outcome: statusLog.lastOutcome, lastStartedAt: statusLog.lastStartedAt, now: base.addingTimeInterval(20)) == .idle, "old completions do not flash during historical replay")
statusLog.consume(start("cancel", at: base.addingTimeInterval(20)))
statusLog.consume(event("turn_aborted", ["turn_id": "cancel"], at: base.addingTimeInterval(25)))
check(statusLog.lastOutcome?.kind == .cancelled, "manual cancellation records its own status")
check(RunStatus.resolve(activeCount: 0, notice: nil, outcome: statusLog.lastOutcome, lastStartedAt: statusLog.lastStartedAt, now: base.addingTimeInterval(26)) == .cancelled, "cancellation is briefly yellow")
check(RunStatus.resolve(activeCount: 0, notice: nil, outcome: statusLog.lastOutcome, lastStartedAt: statusLog.lastStartedAt, now: base.addingTimeInterval(30)) == .idle, "cancellation returns to gray")
statusLog.consume(start("failure", at: base.addingTimeInterval(30)))
statusLog.consume(finish("failure", at: base.addingTimeInterval(40), extra: ["error": ["message": "fixture failure"]]))
check(statusLog.lastOutcome?.kind == .failed && statusLog.lastCompleted?.turnID == "success", "failure changes status while retaining previous successful statistics")
check(RunStatus.resolve(activeCount: 0, notice: nil, outcome: statusLog.lastOutcome, lastStartedAt: statusLog.lastStartedAt, now: base.addingTimeInterval(300)) == .failed, "failure remains visible until a new task starts")
check(RunStatus.resolve(activeCount: 2, notice: "fixture warning", outcome: statusLog.lastOutcome, lastStartedAt: nil, now: base) == .running, "known parallel running tasks take precedence over terminal states")
check(RunStatus.resolve(activeCount: 0, notice: "cannot read logs", outcome: statusLog.lastOutcome, lastStartedAt: nil, now: base) == .unavailable, "unreadable monitoring is distinct from a task failure")
statusLog.consume(start("next", at: base.addingTimeInterval(50)))
check(RunStatus.resolve(activeCount: 0, notice: nil, outcome: statusLog.lastOutcome, lastStartedAt: statusLog.lastStartedAt, now: base.addingTimeInterval(500)) == .idle, "old failures do not reappear after a newer task")
check(!RunActivity(status: .completed).hasSameDisplay(as: .empty), "status-only changes notify the UI")
check(RunActivity(activeCount: 1, currentRate: 38.1).hasSameDisplay(as: RunActivity(activeCount: 1, currentRate: 38.2)), "same rendered speed still suppresses redundant redraws")

let child = RunLogParser()
child.consume(record("session_meta", ["source": ["subagent": ["other": "guardian"]]]))
child.consume(start("child"))
child.consume(finish("child"))
check(child.ignored && child.active == nil && child.lastCompleted == nil, "internal subagents never replace user task statistics")
let broken = RunLogParser()
broken.consume(Data("{broken".utf8))
broken.consume(event("task_started"))
check(broken.active != nil, "legacy timestamp can identify a task without an ID")
broken.consume(event("turn_aborted"))
check(broken.active == nil, "legacy abort with no ID returns to idle")

check(RunActivity.empty.menuLabel == nil, "idle keeps weekly quota")
check(RunActivity(activeCount: 1).menuLabel == "…", "running before token usage shows ellipsis")
check(RunActivity(activeCount: 1, currentRate: 38).menuLabel == "38t/s", "running replaces only the weekly cell")
check(RunFormatting.rate(nil) == "—", "missing completed rate is explicit")
check(RunFormatting.rate(.infinity) == "—", "nonfinite rate is hidden")
check(RunFormatting.rate(0.05, compact: true) == "<0.1t/s", "small positive rate never rounds to zero")
check(RunFormatting.rate(1_200, compact: true) == "1.2kt/s", "large rate remains compact")
check(RunFormatting.latency(nil) == "—" && RunFormatting.latency(-1) == "—", "invalid latency is not invented")
check(RunFormatting.latency(0) == "0 ms" && RunFormatting.latency(1_250) == "1.2 s", "latency units")

var framer = RunLogFramer()
var lines: [Data] = []
let unicode = event("unknown", ["text": "中文测试"])
var stream = unicode; stream.append(10); stream.append(start("framed")); stream.append(10)
for index in stride(from: 0, to: stream.count, by: 3) {
    framer.append(Data(stream[index..<min(index + 3, stream.count)])) { lines.append($0) }
}
check(lines.count == 2 && lines[0] == unicode, "partial UTF-8 and multiple JSONL records survive framing")
var partial = RunLogFramer()
var partialLines = 0
partial.append(start("partial")) { _ in partialLines += 1 }
check(partialLines == 0, "unterminated JSON record waits for newline")
partial.append(Data([10])) { _ in partialLines += 1 }
check(partialLines == 1, "trailing partial record completes exactly once")
var oversized = RunLogFramer()
var oversizedLines = 0
oversized.append(Data(repeating: 65, count: 4_194_305)) { _ in oversizedLines += 1 }
oversized.append(Data([10]) + start("after-huge-line") + Data([10])) { _ in oversizedLines += 1 }
check(oversizedLines == 1, "huge tool output is skipped and framing recovers")

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("quota-run-tests-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let log = temporary.appendingPathComponent("rollout.jsonl")
func append(_ data: Data, to url: URL = log) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}
try (start("tail") + Data([10])).write(to: log)
let tail = RunLogTail()
check(try tail.poll(log), "initial tail catches up")
check(tail.parser.active?.turnID == "tail", "tail detects preexisting active turn")
try append(usage("tail", 200))
check(try tail.poll(log), "partial write read")
check(tail.parser.active?.outputTokens == nil, "partial write does not publish uncommitted JSON")
try append(Data([10]) + finish("tail") + Data([10]))
check(try tail.poll(log), "appended completion read")
check(tail.parser.active == nil && tail.parser.lastCompleted?.averageRate == 20, "append updates without rereading previous usage")
let openCount = tail.openCount, byteCount = tail.bytesRead
for _ in 0..<20 { _ = try tail.poll(log) }
check(tail.openCount == openCount && tail.bytesRead == byteCount, "unchanged log files are neither reopened nor reread")
try Data().write(to: log)
check(tail.needsReset(log), "truncated log requests a fresh parser")
try (record("session_meta", ["source": "vscode"]) + Data([10])).write(to: log, options: .atomic)
check(tail.needsReset(log), "atomic file replacement requests a fresh parser")

let retained = CompletedRun(turnID: "saved", completedAt: base, duration: 10, outputTokens: 100, firstTokenMilliseconds: 600)
let missing = CompletedRun(turnID: "saved", completedAt: base, duration: nil, outputTokens: nil, firstTokenMilliseconds: nil)
check(missing.merged(with: retained) == retained, "duplicate history never clears known previous statistics")
check(try JSONDecoder().decode(CompletedRun.self, from: JSONEncoder().encode(retained)) == retained, "numeric statistics cache round-trip")

// Exercise the actual background monitor, main-thread delivery and restart cache
// against isolated fixtures. No real Codex data or account is accessed.
let now = Date()
let root = temporary.appendingPathComponent("sessions", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let mainLog = root.appendingPathComponent("main.jsonl")
let secondLog = root.appendingPathComponent("second.jsonl")
try (start("finished", at: now.addingTimeInterval(-30)) + Data([10])
    + usage("finished", 300) + Data([10]) + finish("finished", at: now.addingTimeInterval(-20)) + Data([10])
    + start("running", at: now.addingTimeInterval(-10)) + Data([10]) + usage("running", 100, at: now) + Data([10])).write(to: mainLog)
try (start("parallel", at: now.addingTimeInterval(-5)) + Data([10]) + usage("parallel", 200, at: now) + Data([10])).write(to: secondLog)
try (start("stale", at: now.addingTimeInterval(-7_200)) + Data([10])).write(to: root.appendingPathComponent("stale.jsonl"))
try (record("session_meta", ["source": ["subagent": ["other": "guardian"]]]) + Data([10])
    + start("internal", at: now) + Data([10]) + finish("internal", at: now) + Data([10])).write(to: root.appendingPathComponent("child.jsonl"))
let suite = "quota-run-tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
var delivered: RunActivity?
let monitor = RunMetricsMonitor(root: root, cache: defaults) { activity in
    check(Thread.isMainThread, "monitor reports on main thread")
    delivered = activity
}
var waitSequence = 0
func waitFor(timeout: TimeInterval = 4, _ predicate: () -> Bool) {
    waitSequence += 1
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(predicate(), "monitor state \(waitSequence) arrives before deadline")
}
monitor.start()
waitFor { delivered?.activeCount == 2 }
check((delivered?.currentRate ?? 0) > 20, "most recently started task supplies rate without summing parallel tasks")
check(delivered?.lastCompleted?.turnID == "finished", "popup retains previous result while two new tasks run")
try append(finish("running", at: Date()) + Data([10]), to: mainLog)
try append(event("turn_aborted", ["turn_id": "parallel"], at: Date()) + Data([10]), to: secondLog)
waitFor { delivered?.activeCount == 0 }
check(delivered?.lastCompleted?.turnID == "running", "completion updates previous result and restores weekly cell")
check(defaults.data(forKey: "lastCompletedRun.v1") != nil, "last completed metrics persist for restart")

var firstCounters: RunMonitorCounters?
monitor.diagnostics { firstCounters = $0 }
waitFor { firstCounters != nil }
RunLoop.main.run(until: Date().addingTimeInterval(1.2))
var secondCounters: RunMonitorCounters?
monitor.diagnostics { secondCounters = $0 }
waitFor { secondCounters != nil }
check(firstCounters?.logOpens == secondCounters?.logOpens, "idle monitor does not poll or reopen unchanged logs")
check(firstCounters?.fullScans == secondCounters?.fullScans, "idle monitor does not repeatedly scan history")
check(firstCounters?.mainReports == secondCounters?.mainReports, "identical idle state does not wake the UI")
check(delivered?.displayStatus == .completed || delivered?.displayStatus == .cancelled, "live monitor publishes the latest terminal state while retaining successful metrics")
waitFor(timeout: 6) { delivered?.displayStatus == .idle }
check(delivered?.lastCompleted?.turnID == "running", "one-shot status expiry preserves previous metrics")

// New nested date directories and atomic replacement must wake the monitor
// without waiting for its five-minute maintenance timer.
let nested = root.appendingPathComponent("2027/01/01", isDirectory: true)
try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
let newLog = nested.appendingPathComponent("new.jsonl")
try (start("new-task", at: Date()) + Data([10])).write(to: newLog)
waitFor { delivered?.activeCount == 1 }
try (start("replacement", at: Date()) + Data([10]) + usage("replacement", 400, at: Date()) + Data([10])).write(to: newLog, options: .atomic)
waitFor { (delivered?.currentRate ?? 0) > 0 }
try append(finish("replacement", at: Date()) + Data([10]), to: newLog)
waitFor { delivered?.activeCount == 0 && delivered?.lastCompleted?.turnID == "replacement" }
check(delivered?.displayStatus == .completed, "successful completion reaches the live status indicator")

try (start("deleted", at: Date()) + Data([10])).write(to: newLog)
waitFor { delivered?.activeCount == 1 }
try FileManager.default.removeItem(at: nested)
waitFor { delivered?.activeCount == 0 }
monitor.stop()
let restart = RunMetricsMonitor(root: temporary.appendingPathComponent("absent"), cache: defaults) { delivered = $0 }
restart.start()
waitFor { delivered?.notice != nil }
check(delivered?.lastCompleted?.turnID == "replacement", "missing log source retains previous metrics after restart")
check(delivered?.menuLabel == nil, "unavailable logs fall back to weekly quota")
restart.stop()

var fallbackActivity: RunActivity?
let fallback = RunMetricsMonitor(root: root, cache: nil, useFileEvents: false, scanInterval: 0.2) { fallbackActivity = $0 }
fallback.start()
waitFor { fallbackActivity != nil }
try (start("fallback", at: Date()) + Data([10])).write(to: secondLog)
waitFor { fallbackActivity?.activeCount == 1 }
try append(event("turn_aborted", ["turn_id": "fallback"], at: Date()) + Data([10]), to: secondLog)
waitFor { fallbackActivity?.activeCount == 0 }
fallback.stop()

// A repeated open/close cycle catches descriptor and source ownership leaks.
func descriptorCount() -> Int { (0..<1_024).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) } }
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
let descriptorsBefore = descriptorCount()
for _ in 0..<25 {
    var cycle: RunMetricsMonitor? = RunMetricsMonitor(root: root, cache: nil) { _ in }
    cycle?.start()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    cycle?.stop()
    cycle = nil
}
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
check(descriptorCount() <= descriptorsBefore + 3, "repeated monitor lifecycle releases file descriptors")
print("PASS: \(checks) run-metrics checks (lifecycle, usage, latency, framing, tails, concurrency, cache, unavailable logs)")
