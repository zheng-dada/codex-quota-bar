import Foundation
import Darwin

struct SessionFileChanges {
    var files = Set<URL>()
    var directories = Set<URL>()
    var needsFullScan = false
}

// Kernel vnode notifications also work when the FSEvents daemon is unavailable.
// Watch only selected logs and their parent directories, never every historical
// file. Every descriptor is close-on-exec and is closed by its cancel handler.
final class SessionFileWatcher {
    private let root: URL
    private let queue: DispatchQueue
    private let receive: (SessionFileChanges) -> Void
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var watchedFiles = Set<URL>()
    private var historyDirectories = Set<URL>()
    private var directoryHints: [URL] = []
    private var stopped = false
    private(set) var isHealthy = true

    init?(root: URL, queue: DispatchQueue, receive: @escaping (SessionFileChanges) -> Void) {
        self.root = root
        self.queue = queue
        self.receive = receive
        setFiles([])
        if sources.isEmpty { return nil }
    }

    func setFiles(_ files: Set<URL>, directories history: Set<URL> = []) {
        guard !stopped else { return }
        watchedFiles = files
        historyDirectories = history
        var directories = Set<URL>()
        var covered = true
        var ancestor = root
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        directories.insert(ancestor)
        for file in files.sorted(by: { $0.path < $1.path }) {
            var parent = file.deletingLastPathComponent()
            while parent.path == root.path || parent.path.hasPrefix(root.path + "/") {
                if directories.count < 48 || directories.contains(parent) { directories.insert(parent) }
                else { covered = false }
                if parent == root { break }
                parent.deleteLastPathComponent()
            }
        }
        for directory in directoryHints.reversed() where directories.count < 48 { directories.insert(directory) }
        for directory in history {
            if directories.count >= 48 { break }
            directories.insert(directory)
        }
        if history.count > directories.count || !history.isSubset(of: directories) { covered = false }
        let desired = files.union(directories)
        for url in Array(sources.keys) where !desired.contains(url) { sources.removeValue(forKey: url)?.cancel() }
        isHealthy = covered
        for url in desired where sources[url] == nil {
            let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { isHealthy = false; continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete, .revoke], queue: queue)
            let directory = directories.contains(url)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source, !self.stopped else { return }
                let event = source.data
                if !event.intersection([.rename, .delete, .revoke]).isEmpty {
                    if let current = self.sources[url], current === source { self.sources.removeValue(forKey: url)?.cancel() }
                }
                var changes = SessionFileChanges()
                if directory { changes.directories.insert(url) }
                else { changes.files.insert(url) }
                self.receive(changes)
            }
            source.setCancelHandler { close(descriptor) }
            sources[url] = source
            source.resume()
        }
    }

    func hintDirectory(_ directory: URL) {
        guard !stopped, directory.path == root.path || directory.path.hasPrefix(root.path + "/") else { return }
        directoryHints.removeAll { $0 == directory }
        directoryHints.append(directory)
        if directoryHints.count > 16 { directoryHints.removeFirst() }
        setFiles(watchedFiles, directories: historyDirectories)
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            for source in sources.values { source.cancel() }
            sources.removeAll()
        }
    }
    deinit { for source in sources.values { source.cancel() } }
}
