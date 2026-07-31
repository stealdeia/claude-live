import Foundation
import CoreServices

/// Watches a directory for changes to the files *inside* it.
///
/// A `DispatchSource` vnode watch on the directory would be simpler but wrong
/// here: writing to a file inside a directory does not change the directory
/// itself, so content updates would be missed. FSEvents with
/// `kFSEventStreamCreateFlagFileEvents` reports per-file changes, which is what
/// both users of this class need (hook status files, VS Code workspace storage).
final class DirectoryWatcher {
    private let url: URL
    private let onChange: () -> Void
    private let queue: DispatchQueue

    private var stream: FSEventStreamRef?

    /// Coalescing window. Long enough that a burst of writes becomes one
    /// callback, short enough to feel immediate.
    private let latency: CFTimeInterval

    init(url: URL, latency: CFTimeInterval = 0.15, onChange: @escaping () -> Void) {
        self.url = url
        self.latency = latency
        self.onChange = onChange
        self.queue = DispatchQueue(
            label: "it.aldeialab.ClaudeLive.fsevents.\(url.lastPathComponent)",
            qos: .utility
        )
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }

        // The directory must exist before the stream is created, otherwise
        // FSEvents watches a path that never resolves.
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.debug("Watcher non avviato, directory assente: \(url.path)", category: .status)
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            Log.error("FSEventStreamCreate fallito per \(url.path)", category: .status)
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            Log.error("FSEventStreamStart fallito per \(url.path)", category: .status)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }

        self.stream = stream
        Log.debug("Watcher FSEvents attivo su \(url.path)", category: .status)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
