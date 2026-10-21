import CoreServices
import Foundation

/// FSEvents observer for the local sync folder. The handler fires (coalesced by `latency`) on any change below it.
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "de.martini-labs.boxsync.fsevents")

    public init(path: URL, latency: TimeInterval = 2, handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            Unmanaged<FolderWatcher>.fromOpaque(info!).takeUnretainedValue().handler()
        }
        stream = FSEventStreamCreate(nil, callback, &ctx, [path.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
