import Foundation

/// Watches selected folders for changes and invokes a callback (debounced) so
/// the app can trigger a rescan. This is a best-effort signal: the app also
/// reconciles on launch and on explicit rescan, so missed events are not fatal.
///
/// Implemented with a `DispatchSource` vnode watcher per folder. For deep trees
/// this detects changes at the watched directory level; combined with periodic/
/// manual reconciliation it keeps the index fresh without relying on events
/// alone.
public final class FileChangeMonitor: @unchecked Sendable {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var descriptors: [Int32] = []
    private let queue = DispatchQueue(label: "com.recall.filemonitor")
    private let debounceInterval: TimeInterval
    private var pendingWork: DispatchWorkItem?
    private let onChange: @Sendable () -> Void

    public init(debounceInterval: TimeInterval = 1.5, onChange: @escaping @Sendable () -> Void) {
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    /// Begins watching the given folders. Replaces any existing watches.
    public func start(folders: [URL]) {
        stop()
        for folder in folders {
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .extend],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleCallback()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            sources.append(source)
            descriptors.append(fd)
        }
    }

    public func stop() {
        for source in sources { source.cancel() }
        sources.removeAll()
        descriptors.removeAll()
        pendingWork?.cancel()
        pendingWork = nil
    }

    private func scheduleCallback() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    deinit {
        stop()
    }
}
