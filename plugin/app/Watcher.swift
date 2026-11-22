// Spyglass: reacts to file changes (FSEvents) instead of re-reading everything every second.
import CoreServices
import Foundation

/// Calls `onChange` (on the main queue, coalesced by `latency`) when a file under `paths` changes,
/// unless every changed path is one `ignore` says to skip (files the panel writes itself, chatty folders).
final class Watcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let ignore: (String) -> Bool

    init(paths: [String], latency: Double = 0.3, ignore: @escaping (String) -> Bool, onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.ignore = ignore
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if list.prefix(count).contains(where: { !me.ignore($0) }) { me.onChange() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
