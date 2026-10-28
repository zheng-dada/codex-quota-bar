import Foundation

struct CompletedRun: Codable, Equatable {
    let turnID: String
    let completedAt: Date
    let duration: TimeInterval?
    let outputTokens: Int?
    let firstTokenMilliseconds: Double?

    var averageRate: Double? {
        guard let tokens = outputTokens, tokens > 0, let duration, duration > 0 else { return nil }
        let rate = Double(tokens) / duration
        return rate.isFinite ? rate : nil
    }

    func merged(with previous: CompletedRun?) -> CompletedRun {
        guard let previous else { return self }
        if turnID == previous.turnID {
            return CompletedRun(turnID: turnID, completedAt: max(completedAt, previous.completedAt),
                                duration: duration ?? previous.duration, outputTokens: outputTokens ?? previous.outputTokens,
                                firstTokenMilliseconds: firstTokenMilliseconds ?? previous.firstTokenMilliseconds)
        }
        if completedAt == previous.completedAt { return turnID > previous.turnID ? self : previous }
        return completedAt > previous.completedAt ? self : previous
    }
}

struct ActiveRun: Equatable {
    let turnID: String
    let startedAt: Date?
    var lastEventAt: Date
    var outputTokens: Int?

    func averageRate(at now: Date) -> Double? {
        guard let startedAt else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard let tokens = outputTokens, tokens > 0, elapsed > 0 else { return nil }
        let rate = Double(tokens) / elapsed
        return rate.isFinite ? rate : nil
    }
}

enum RunStatus: String, CaseIterable {
    case idle, running, completed, cancelled, failed, unavailable

    var title: String {
        switch self {
        case .idle: return "待机"
        case .running: return "运行中"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        case .failed: return "任务失败"
        case .unavailable: return "监控异常"
        }
    }

    static let transientDuration: TimeInterval = 4

    static func resolve(activeCount: Int, notice: String?, outcome: RunOutcome?, lastStartedAt: Date?, now: Date) -> RunStatus {
        if activeCount > 0 { return .running }
        if notice != nil { return .unavailable }
        guard let outcome, lastStartedAt.map({ $0 <= outcome.at }) ?? true else { return .idle }
        if outcome.kind == .failed { return .failed }
        guard now >= outcome.at, now.timeIntervalSince(outcome.at) < transientDuration else { return .idle }
        return outcome.kind == .completed ? .completed : .cancelled
    }
}

struct RunOutcome: Equatable {
    enum Kind { case completed, cancelled, failed }
    let turnID: String
    let kind: Kind
    let at: Date

    func isNewer(than other: RunOutcome?) -> Bool {
        guard let other else { return true }
        return at == other.at ? turnID > other.turnID : at > other.at
    }
}

struct RunActivity: Equatable {
    var activeCount = 0
    var currentRate: Double?
    var lastCompleted: CompletedRun?
    var notice: String?
    var status: RunStatus = .idle

    static let empty = RunActivity()
    var menuLabel: String? { activeCount > 0 ? (currentRate.map { RunFormatting.rate($0, compact: true) } ?? "…") : nil }
    var displayStatus: RunStatus { activeCount > 0 ? .running : (notice != nil ? .unavailable : status) }

    func hasSameDisplay(as other: RunActivity) -> Bool {
        activeCount == other.activeCount && menuLabel == other.menuLabel && lastCompleted == other.lastCompleted && notice == other.notice && displayStatus == other.displayStatus
    }
}

enum RunFormatting {
    static func rate(_ rate: Double?, compact: Bool = false) -> String {
        guard let rate, rate.isFinite, rate > 0 else { return "—" }
        let unit = compact ? "t/s" : " tok/s"
        if rate < 0.1 { return "<0.1\(unit)" }
        if rate < 1 { return String(format: "%.1f", rate) + unit }
        if rate >= 1_000 { return String(format: "%.1fk", rate / 1_000) + unit }
        return String(format: "%.0f", rate) + unit
    }

    static func latency(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return "—" }
        if milliseconds < 1_000 { return String(format: "%.0f ms", milliseconds) }
        return String(format: "%.1f s", milliseconds / 1_000)
    }
}

// Probe only the bounded header of the normal JSONL envelope. Unknown field
// orders or incomplete headers fall back to full JSON decoding for correctness.
// Large chat/tool bodies in irrelevant record kinds never become dictionaries.
private struct RunLogHeader {
    var kind: String?
    var event: String?
    var timestamp: String?

    static func probe(_ data: Data) -> RunLogHeader {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let limit = min(bytes.count, 1_024)
            var index = 0, depth = 0
            var payloadDepth: Int?
            var header = RunLogHeader()
            func whitespace(_ index: inout Int) {
                while index < limit && [UInt8(32), 9, 10, 13].contains(bytes[index]) { index += 1 }
            }
            func string(_ index: inout Int) -> String? {
                guard index < limit, bytes[index] == 34 else { return nil }
                index += 1
                let start = index
                var escaped = false
                while index < limit {
                    if bytes[index] == 92 { escaped = true; index += 2; continue }
                    if bytes[index] == 34 {
                        let end = index
                        index += 1
                        return escaped ? nil : String(bytes: bytes[start..<end], encoding: .utf8)
                    }
                    index += 1
                }
                return nil
            }
            while index < limit {
                switch bytes[index] {
                case 123, 91: depth += 1; index += 1
                case 125, 93:
                    if depth == payloadDepth { payloadDepth = nil }
                    depth -= 1; index += 1
                case 34:
                    guard let key = string(&index) else { return header }
                    whitespace(&index)
                    if index < limit, bytes[index] == 58 {
                        index += 1; whitespace(&index)
                        if depth == 1, key == "payload", index < limit, bytes[index] == 123 { payloadDepth = 2 }
                        if depth == 1, key == "type" { header.kind = string(&index) }
                        else if depth == 1, key == "timestamp" { header.timestamp = string(&index) }
                        else if depth == payloadDepth, key == "type" { header.event = string(&index) }
                    }
                default: index += 1
                }
                if let kind = header.kind, kind != "event_msg" { return header }
                if header.kind == "event_msg", header.event != nil, header.timestamp != nil { return header }
            }
            return header
        }
    }
}

// Rollout files are an optional, version-dependent local data source. Only timing
// and usage fields survive parsing; no prompt, tool output or message is retained.
final class RunLogParser {
    private(set) var active: ActiveRun?
    private(set) var lastCompleted: CompletedRun?
    private(set) var lastOutcome: RunOutcome?
    private(set) var lastStartedAt: Date?
    private(set) var ignored = false
    private var threadOutput: Int?
    private var turnBaseline: Int?
    private var explicitUsage = false
    private var hasLifecycle = false
    private var pendingUsage: (id: String, tokens: Int)?
    private let fractionalDate = ISO8601DateFormatter()
    private let plainDate = ISO8601DateFormatter()

    init() {
        fractionalDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func consume(_ line: Data) {
        guard !ignored else { return }
        let header = RunLogHeader.probe(line)
        if let kind = header.kind, !["session_meta", "event_msg", "token_usage_record"].contains(kind) { return }
        if header.kind == "event_msg", let event = header.event,
           !["task_started", "task_complete", "turn_aborted", "token_count"].contains(event) {
            if active == nil { return }
            if let timestamp = header.timestamp { touch(date(timestamp)); return }
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = object["type"] as? String, let payload = object["payload"] as? [String: Any] else { return }
        if kind == "session_meta" {
            if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
                ignored = true
                active = nil
                lastCompleted = nil
                lastOutcome = nil
                lastStartedAt = nil
            }
            return
        }
        let timestamp = date(object["timestamp"])
        if kind == "token_usage_record" {
            guard let id = payload["turn_id"] as? String,
                  let usage = payload["turn_token_usage"] as? [String: Any],
                  let tokens = count(usage["output_tokens"]) else { return }
            pendingUsage = (id, tokens)
            if active?.turnID == id {
                active?.outputTokens = tokens
                explicitUsage = true
                touch(timestamp)
            } else if let previous = lastCompleted, previous.turnID == id {
                lastCompleted = CompletedRun(turnID: id, completedAt: previous.completedAt, duration: previous.duration,
                                            outputTokens: tokens, firstTokenMilliseconds: previous.firstTokenMilliseconds)
            } else if active == nil, !hasLifecycle, let timestamp {
                // A bounded tail may start after a long task's start record.
                // Recognize activity, but never invent a start time or rate.
                active = ActiveRun(turnID: id, startedAt: nil, lastEventAt: timestamp, outputTokens: tokens)
                lastStartedAt = timestamp
                explicitUsage = true
            }
            return
        }
        guard kind == "event_msg", let event = payload["type"] as? String else { return }
        touch(timestamp)
        switch event {
        case "task_started":
            hasLifecycle = true
            guard let start = date(payload["started_at"]) ?? timestamp else { return }
            let id = payload["turn_id"] as? String ?? "legacy-\(start.timeIntervalSince1970)"
            guard active?.turnID != id, lastCompleted?.turnID != id else { return }
            active = ActiveRun(turnID: id, startedAt: start, lastEventAt: timestamp ?? start)
            lastStartedAt = start
            turnBaseline = threadOutput
            explicitUsage = false
            pendingUsage = nil
        case "token_count":
            guard let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let tokens = count(total["output_tokens"]) else { return }
            threadOutput = tokens
            // Legacy totals can reset during compaction. Never mistake the full
            // conversation's token count for the current turn's output.
            if !explicitUsage, let baseline = turnBaseline, tokens >= baseline {
                active?.outputTokens = tokens - baseline
            } else if !explicitUsage, let baseline = turnBaseline, tokens < baseline {
                turnBaseline = nil
                active?.outputTokens = nil
            }
        case "task_complete":
            hasLifecycle = true
            let id = payload["turn_id"] as? String ?? active?.turnID
            guard let id else { return }
            let matches = active?.turnID == id
            let running = matches ? active : nil
            if matches { active = nil }
            let end = date(payload["completed_at"]) ?? timestamp
            guard let end else { return }
            let outcomeDate = max(end, timestamp ?? end)
            if let error = payload["error"], !(error is NSNull) {
                recordOutcome(RunOutcome(turnID: id, kind: .failed, at: outcomeDate))
                return
            }
            recordOutcome(RunOutcome(turnID: id, kind: .completed, at: outcomeDate))
            let start = date(payload["started_at"]) ?? running?.startedAt
            let duration = number(payload["duration_ms"]).map { $0 / 1_000 } ?? start.map { end.timeIntervalSince($0) }
            let tokens = pendingUsage?.id == id ? pendingUsage?.tokens : running?.outputTokens
            let latency = number(payload["time_to_first_token_ms"])
            let result = CompletedRun(turnID: id, completedAt: end,
                                      duration: duration.flatMap { $0 > 0 ? $0 : nil },
                                      outputTokens: tokens, firstTokenMilliseconds: latency)
            lastCompleted = result.merged(with: lastCompleted)
        case "turn_aborted":
            hasLifecycle = true
            if active == nil || payload["turn_id"] == nil || payload["turn_id"] as? String == active?.turnID {
                if let end = date(payload["completed_at"]) ?? timestamp,
                   let id = payload["turn_id"] as? String ?? active?.turnID {
                    recordOutcome(RunOutcome(turnID: id, kind: .cancelled, at: max(end, timestamp ?? end)))
                }
                active = nil
            }
        default: break
        }
    }

    private func recordOutcome(_ outcome: RunOutcome) {
        if outcome.isNewer(than: lastOutcome) { lastOutcome = outcome }
    }

    private func touch(_ date: Date?) {
        if let date, let old = active?.lastEventAt, date > old { active?.lastEventAt = date }
    }

    private func date(_ value: Any?) -> Date? {
        if let value = value as? String { return fractionalDate.date(from: value) ?? plainDate.date(from: value) }
        guard let value = number(value) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 ? value : nil
    }

    private func count(_ value: Any?) -> Int? {
        guard let value = number(value), value < Double(Int.max) else { return nil }
        return Int(value)
    }
}

// Incremental JSONL framing, including split UTF-8 and a trailing partial record.
// Huge tool output lines are discarded without keeping an unbounded buffer.
struct RunLogFramer {
    private var buffer = Data()
    private var discarding = false
    private let limit = 4_194_304

    init(discardFirstLine: Bool = false) { discarding = discardFirstLine }

    mutating func append(_ data: Data, consume: (Data) -> Void) {
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 10)
            let end = newline ?? data.endIndex
            if !discarding {
                if buffer.count + end - start <= limit { buffer.append(contentsOf: data[start..<end]) }
                else { buffer.removeAll(keepingCapacity: false); discarding = true }
            }
            if let newline {
                if !discarding, !buffer.isEmpty { consume(buffer) }
                if buffer.count > 65_536 { buffer = Data() }
                else { buffer.removeAll(keepingCapacity: true) }
                discarding = false
                start = data.index(after: newline)
            } else { break }
        }
    }
}

final class RunLogTail {
    let parser = RunLogParser()
    private var offset: UInt64 = 0
    private var inode: UInt64?
    private var framer = RunLogFramer()
    private var initialized = false
    private(set) var openCount = 0
    private(set) var bytesRead: UInt64 = 0
    private var lastSize: UInt64?
    private var lastModified: Date?

    // Returns false while catching up, so historical starts don't briefly appear
    // as live tasks before their matching completion has been read.
    func poll(_ url: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let modified = attributes[.modificationDate] as? Date
        if initialized && (size < offset || inode != fileID) { return false }
        if initialized && size == offset && lastSize == size && lastModified == modified { return true }
        let handle = try FileHandle(forReadingFrom: url)
        openCount += 1
        defer { try? handle.close() }
        if !initialized {
            inode = fileID
            // Parse metadata even when replaying only the end of a large file.
            var header = RunLogFramer()
            var data = Data()
            while data.count < 1_048_576 {
                let part = try handle.read(upToCount: 4_096) ?? Data()
                bytesRead += UInt64(part.count)
                data.append(part)
                if let newline = data.firstIndex(of: 10) { header.append(Data(data[...newline]), consume: parser.consume); break }
                if part.isEmpty { break }
            }
            offset = size > 8_388_608 ? size - 8_388_608 : 0
            framer = RunLogFramer(discardFirstLine: offset > 0)
            initialized = true
        }
        if parser.ignored { offset = size; lastSize = size; lastModified = modified; return true }
        try handle.seek(toOffset: offset)
        var budget = 2_097_152
        while budget > 0 {
            let chunk = try handle.read(upToCount: min(budget, 262_144)) ?? Data()
            if chunk.isEmpty { break }
            offset += UInt64(chunk.count)
            bytesRead += UInt64(chunk.count)
            budget -= chunk.count
            framer.append(chunk, consume: parser.consume)
        }
        lastSize = size
        lastModified = modified
        return offset >= size
    }

    func needsReset(_ url: URL) -> Bool {
        guard initialized, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return size < offset || inode != fileID
    }
}

// All scanning and parsing stays on a utility queue. No model request is made.
struct RunMonitorCounters {
    var fullScans = 0
    var logOpens = 0
    var bytesRead: UInt64 = 0
    var mainReports = 0
}

final class RunMetricsMonitor {
    private let root: URL
    private let queue = DispatchQueue(label: "local.codex.quota-bar.run-metrics", qos: .utility, autoreleaseFrequency: .workItem)
    private var timer: DispatchSourceTimer?
    private var watcher: SessionFileWatcher?
    private var tails: [URL: RunLogTail] = [:]
    private var candidates: [URL: Date] = [:]
    private var catalogueTruncated = false
    private var ignoredPaths = Set<URL>()
    private var knownDirectories = Set<URL>()
    private var dirty = Set<URL>()
    private var pendingRead: DispatchWorkItem?
    private var stateExpiry: DispatchWorkItem?
    private var stateExpiryDate: Date?
    private var running = false
    private var lastScan = Date.distantPast
    private var timerInterval: TimeInterval?
    private var timerFallback: TimeInterval?
    private var lastReport: RunActivity?
    private var counters = RunMonitorCounters()
    private var discoveryNotice: String?
    private var latest: CompletedRun?
    private var latestOutcome: RunOutcome?
    private var latestStart: Date?
    private var unreadableLogs = Set<URL>()
    private let cache: UserDefaults?
    private let useFileEvents: Bool
    private let scanInterval: TimeInterval
    private let report: (RunActivity) -> Void

    init(root: URL? = nil, cache: UserDefaults? = .standard, useFileEvents: Bool = true, scanInterval: TimeInterval = 300, report: @escaping (RunActivity) -> Void) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let path = root ?? (home.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true))
            .appendingPathComponent("sessions", isDirectory: true)
        self.root = path.standardizedFileURL.resolvingSymlinksInPath()
        self.cache = cache
        self.useFileEvents = useFileEvents
        self.scanInterval = max(0.1, scanInterval)
        if let data = cache?.data(forKey: "lastCompletedRun.v1") { latest = try? JSONDecoder().decode(CompletedRun.self, from: data) }
        latestOutcome = latest.map { RunOutcome(turnID: $0.turnID, kind: .completed, at: $0.completedAt) }
        self.report = report
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            if self.useFileEvents {
                self.watcher = SessionFileWatcher(root: self.root, queue: self.queue) { [weak self] changes in self?.filesChanged(changes) }
            }
            self.rescan()
            self.readChanges()
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    func diagnostics(_ receive: @escaping (RunMonitorCounters) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.counters
            DispatchQueue.main.async { receive(snapshot) }
        }
    }

    private func stopOnQueue() {
        running = false
        timer?.cancel(); timer = nil; timerInterval = nil; timerFallback = nil
        pendingRead?.cancel(); pendingRead = nil
        stateExpiry?.cancel(); stateExpiry = nil; stateExpiryDate = nil
        watcher?.stop(); watcher = nil
        // Release parsers and any partial tool-output buffers during sleep.
        tails.removeAll(); candidates.removeAll(); dirty.removeAll(); ignoredPaths.removeAll(); knownDirectories.removeAll(); unreadableLogs.removeAll()
    }

    deinit { timer?.cancel(); pendingRead?.cancel(); stateExpiry?.cancel(); watcher?.stop() }

    private func filesChanged(_ changes: SessionFileChanges) {
        guard running else { return }
        if changes.needsFullScan { rescan() }
        else {
            for directory in changes.directories {
                let target = root.path.hasPrefix(directory.path + "/") ? root : directory
                if FileManager.default.fileExists(atPath: target.path) {
                    do { try scan(target, watchNewDirectories: true); discoveryNotice = nil }
                    catch { continue }
                } else {
                    candidates = candidates.filter { !$0.key.path.hasPrefix(directory.path + "/") }
                    tails = tails.filter { !$0.key.path.hasPrefix(directory.path + "/") }
                    knownDirectories = knownDirectories.filter { $0.path != directory.path && !$0.path.hasPrefix(directory.path + "/") }
                }
            }
            for url in changes.files {
                if let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]), values.isRegularFile == true {
                    candidates[url] = values.contentModificationDate ?? .distantPast
                    dirty.insert(url)
                    discoveryNotice = nil
                } else { candidates.removeValue(forKey: url); tails.removeValue(forKey: url) }
            }
            selectTails()
        }
        scheduleRead()
    }

    private func scheduleRead() {
        guard pendingRead == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.pendingRead = nil
            self.readChanges()
        }
        pendingRead = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func rescan() {
        lastScan = Date()
        counters.fullScans += 1
        if useFileEvents && watcher == nil {
            watcher = SessionFileWatcher(root: root, queue: queue) { [weak self] changes in self?.filesChanged(changes) }
        }
        do {
            candidates.removeAll(keepingCapacity: true)
            catalogueTruncated = false
            knownDirectories.removeAll(keepingCapacity: true)
            try scan(root)
            discoveryNotice = nil
            selectTails()
            dirty.formUnion(tails.keys)
        } catch {
            discoveryNotice = "无法读取本机会话记录，运行统计暂不可用。"
            tails.removeAll(); candidates.removeAll(); dirty.removeAll()
            unreadableLogs.removeAll()
        }
    }

    private func readChanges() {
        guard running else { return }
        let changed = dirty
        dirty.removeAll(keepingCapacity: true)
        for url in changed {
            guard let oldTail = tails[url] else { continue }
            let tail: RunLogTail
            if oldTail.needsReset(url) { tail = RunLogTail(); tails[url] = tail }
            else { tail = oldTail }
            let previousOpens = tail.openCount, previousBytes = tail.bytesRead
            do {
                let caughtUp = try autoreleasepool { try tail.poll(url) }
                unreadableLogs.remove(url)
                if tail.parser.ignored { ignoredPaths.insert(url) }
                if !caughtUp { dirty.insert(url) }
                if caughtUp {
                    if let started = tail.parser.lastStartedAt { latestStart = max(latestStart ?? .distantPast, started) }
                    if let outcome = tail.parser.lastOutcome, outcome.isNewer(than: latestOutcome) { latestOutcome = outcome }
                }
                if caughtUp, let completed = tail.parser.lastCompleted {
                    let merged = completed.merged(with: latest)
                    if latest != merged {
                        latest = merged
                        if let data = try? JSONEncoder().encode(merged) { cache?.set(data, forKey: "lastCompletedRun.v1") }
                    }
                }
            } catch {
                tails.removeValue(forKey: url)
                if FileManager.default.fileExists(atPath: url.path) { unreadableLogs.insert(url) }
            }
            counters.logOpens += tail.openCount - previousOpens
            counters.bytesRead += tail.bytesRead - previousBytes
        }
        // Internal subagents don't occupy the sixteen useful session slots.
        if !ignoredPaths.isDisjoint(with: tails.keys) { selectTails() }
        publish()
        if !dirty.isEmpty { scheduleRead() }
    }

    private func publish() {
        let now = Date()
        var notice = discoveryNotice ?? (unreadableLogs.isEmpty ? nil : "部分会话记录无法读取，运行状态暂不可用。")
        var activeByID: [String: ActiveRun] = [:]
        for (url, tail) in tails where !dirty.contains(url) && !tail.parser.ignored {
            if let active = tail.parser.active, now.timeIntervalSince(active.lastEventAt) < 1_800,
               (active.startedAt.map { $0 <= now } ?? true), activeByID[active.turnID] == nil {
                activeByID[active.turnID] = active
            }
        }
        if !tails.isEmpty && dirty.count == tails.count { notice = "正在读取本机会话记录。" }
        let current = activeByID.values.max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        let status = RunStatus.resolve(activeCount: activeByID.count, notice: notice, outcome: latestOutcome, lastStartedAt: latestStart, now: now)
        let activity = RunActivity(activeCount: activeByID.count, currentRate: current?.averageRate(at: now), lastCompleted: latest, notice: notice, status: status)
        scheduleStateExpiry(status: status)
        configureTimer(active: !activeByID.isEmpty)
        if lastReport.map({ activity.hasSameDisplay(as: $0) }) != true {
            lastReport = activity
            counters.mainReports += 1
            DispatchQueue.main.async { [report] in report(activity) }
        }
    }

    private func scheduleStateExpiry(status: RunStatus) {
        let deadline = (status == .completed || status == .cancelled)
            ? latestOutcome?.at.addingTimeInterval(RunStatus.transientDuration) : nil
        guard deadline != stateExpiryDate else { return }
        stateExpiry?.cancel(); stateExpiry = nil; stateExpiryDate = deadline
        guard let deadline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.stateExpiry = nil; self.stateExpiryDate = nil
            self.publish()
        }
        stateExpiry = work
        queue.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: work)
    }

    private func configureTimer(active: Bool) {
        // Vnode directory events don't report writes to old, unselected files.
        // Keep a short discovery fallback when history exceeds our FD budget.
        let unwatched = catalogueTruncated || candidates.keys.contains { tails[$0] == nil && !ignoredPaths.contains($0) }
        let fallback = watcher?.isHealthy == true && !unwatched ? scanInterval : min(scanInterval, 30)
        let interval = active ? min(1, fallback) : fallback
        guard timerInterval != interval || timerFallback != fallback else { return }
        timer?.cancel()
        timerInterval = interval
        timerFallback = fallback
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        let tolerance = Int(min(active ? 0.2 : 3, interval * 0.1) * 1_000)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(tolerance))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if Date().timeIntervalSince(self.lastScan) >= fallback { self.rescan(); self.readChanges() }
            else { self.publish() }
        }
        timer.resume()
    }

    private func selectTails() {
        if candidates.count > 64 { catalogueTruncated = true }
        let recent = candidates.sorted { $0.value > $1.value }.prefix(64)
        candidates = Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })
        unreadableLogs.formIntersection(candidates.keys)
        ignoredPaths.formIntersection(candidates.keys)
        var selected = Set(recent.filter { !ignoredPaths.contains($0.key) }.prefix(16).map { $0.key })
        let cutoff = Date().addingTimeInterval(-1_800)
        for (url, tail) in tails where (tail.parser.active?.lastEventAt ?? .distantPast) > cutoff {
            if selected.count < 32, !ignoredPaths.contains(url) { selected.insert(url) }
        }
        tails = tails.filter { selected.contains($0.key) }
        for url in selected where tails[url] == nil { tails[url] = RunLogTail(); dirty.insert(url) }
        dirty.formIntersection(tails.keys)
        watcher?.setFiles(Set(tails.keys), directories: knownDirectories)
    }

    private func scan(_ directory: URL, watchNewDirectories: Bool = false) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles], errorHandler: { _, error in scanError = error; return true }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        for case let entry as URL in enumerator {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            // macOS enumeration may return /private/var while the configured
            // root resolves to /var. Watcher keys must use the same spelling.
            let url = entry.standardizedFileURL.resolvingSymlinksInPath()
            if values?.isDirectory == true {
                // Subscribe before descending: a directory may still be empty
                // when mkdir notifies us, with its log created moments later.
                if watchNewDirectories && !knownDirectories.contains(url) { watcher?.hintDirectory(url) }
                if knownDirectories.count < 8_192 { knownDirectories.insert(url) }
            } else if url.pathExtension == "jsonl", values?.isRegularFile == true {
                candidates[url] = values?.contentModificationDate ?? .distantPast
            }
        }
        if candidates.isEmpty, let scanError { throw scanError }
    }
}
