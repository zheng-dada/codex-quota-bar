import Foundation
import Darwin

func cpu() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
func memory() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}
let mode = CommandLine.arguments[1]
if mode == "parser" {
    // Match the observed Codex envelope order and use identical bytes in both executables.
    let noise = Data("{\"timestamp\":\"2026-10-27T00:00:00.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\"\(String(repeating: "tool output 中文 ", count: 5_000))\"}}".utf8)
    let eventNoise = Data("{\"timestamp\":\"2026-10-27T00:00:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"item\":{\"text\":\"\(String(repeating: "large completed item ", count: 5_000))\"}}}".utf8)
    let parser = RunLogParser()
    let start = Date(); let beginCPU = cpu()
    for _ in 0..<2_000 { parser.consume(noise); parser.consume(eventNoise) }
    print("parser wall_seconds=\(Date().timeIntervalSince(start)) cpu_seconds=\(cpu()-beginCPU) peak_rss_bytes=\(memory()) input_bytes=\((noise.count+eventNoise.count)*2_000)")
} else {
    let steadySeconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 60 : 60
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("quota-perf-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    for i in 0..<2_000 {
        let directory = root.appendingPathComponent("day-\(i/100)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"type\":\"session_meta\",\"payload\":{\"source\":\"vscode\"}}\n".utf8).write(to: directory.appendingPathComponent("file-\(i).jsonl"))
    }
    var reports = 0
    let monitor = RunMetricsMonitor(root: root, cache: nil) { _ in reports += 1 }
    let begin = Date(); let beginCPU = cpu()
    monitor.start()
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    let warmCPU = cpu(); let warmReports = reports
    RunLoop.main.run(until: Date().addingTimeInterval(steadySeconds))
    monitor.stop()
    print("idle wall_seconds=\(Date().timeIntervalSince(begin)) cpu_seconds=\(cpu()-beginCPU) steady_seconds=\(steadySeconds) steady_cpu_seconds=\(cpu()-warmCPU) steady_main_reports=\(reports-warmReports) peak_rss_bytes=\(memory()) files=2000")
}
