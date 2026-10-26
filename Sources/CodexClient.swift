import Foundation
import Darwin

enum CodexLocator {
    static func find(customPath: String? = nil) throws -> URL {
        let manager = FileManager.default
        if let customPath, !customPath.isEmpty {
            guard manager.isExecutableFile(atPath: customPath) else { throw QuotaError.cliMissing }
            return URL(fileURLWithPath: customPath)
        }
        let home = manager.homeDirectoryForCurrentUser.path
        let resources = [
            "/Applications/ChatGPT.app/Contents/Resources",
            "/Applications/Codex.app/Contents/Resources",
            "\(home)/Applications/ChatGPT.app/Contents/Resources",
            "\(home)/Applications/Codex.app/Contents/Resources"
        ]
        let candidates = resources.flatMap {
            ["\($0)/codex-cli/bin/codex", "\($0)/codex"]
        } + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex"]
          + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        guard let path = candidates.first(where: { manager.isExecutableFile(atPath: $0) }) else {
            throw QuotaError.cliMissing
        }
        return URL(fileURLWithPath: path)
    }
}

// All pipe parsing is confined to this worker. NSCondition also bounds waits if a
// child hangs, closes stdout, or emits notifications between RPC responses.
private final class RPCConnection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var closed = false
    private var stopped = false
    private var oversized = false

    init(executable: URL) throws {
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        // Never record tokens, model output, user configuration, or stderr logs.
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = paths.joined(separator: ":") + ":" + (environment["PATH"] ?? "")
        process.environment = environment
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.receive(data)
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.condition.lock()
            self.closed = true
            self.condition.broadcast()
            self.condition.unlock()
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    private func receive(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped else { return }
        if data.isEmpty {
            closed = true
        } else {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = object["id"] as? Int else { continue }
                responses[id] = object
            }
            if buffer.count > 4_194_304 {
                oversized = true
                buffer.removeAll()
            }
        }
        condition.broadcast()
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func request(id: Int, method: String, params: [String: Any]? = nil, deadline: Date) throws -> Data {
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        try send(message)
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil {
            if oversized { throw QuotaError.invalidResponse }
            if closed { throw QuotaError.serverClosed }
            guard condition.wait(until: deadline) else { throw QuotaError.timedOut }
        }
        guard let response = responses.removeValue(forKey: id) else { throw QuotaError.invalidResponse }
        if let error = response["error"] as? [String: Any] {
            throw QuotaError.rpc(error["code"] as? Int ?? -1, error["message"] as? String ?? "未知错误")
        }
        guard let result = response["result"], !(result is NSNull) else { throw QuotaError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: result)
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        // Close stdin first for a graceful shutdown, then bound termination time.
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? output.fileHandleForReading.close()
    }
}

enum CodexClient {
    static func fetch(customPath: String? = nil, timeout: TimeInterval = 25) throws -> QuotaSnapshot {
        let executable = try CodexLocator.find(customPath: customPath)
        let connection = try RPCConnection(executable: executable)
        defer { connection.stop() }
        let deadline = Date().addingTimeInterval(timeout)
        _ = try connection.request(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "codex_quota_bar", "title": "Codex Quota Bar", "version": "1.0.0"]
        ], deadline: deadline)
        try connection.send(["method": "initialized", "params": [:]])
        let data = try connection.request(id: 2, method: "account/rateLimits/read", deadline: deadline)
        let response: RateLimitResponse
        do {
            response = try JSONDecoder().decode(RateLimitResponse.self, from: data)
        } catch {
            throw QuotaError.invalidResponse
        }
        guard let bucket = response.codex else { throw QuotaError.unavailableBucket }
        return QuotaSnapshot(bucket: bucket, fetchedAt: Date(), executable: executable)
    }
}
