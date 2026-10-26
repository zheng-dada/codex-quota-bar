import AppKit
import Darwin

signal(SIGPIPE, SIG_IGN)

if CommandLine.arguments.contains("--check") {
    do {
        let snapshot = try CodexClient.fetch()
        print("5 小时剩余：\(snapshot.fiveHour?.percentage(showUsed: false) ?? "—")")
        print("每周剩余：\(snapshot.weekly?.percentage(showUsed: false) ?? "—")")
        print("Codex：\(snapshot.executable.path)")
        exit(0)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
