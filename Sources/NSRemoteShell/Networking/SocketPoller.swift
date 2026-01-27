import Dispatch
import Foundation

struct SocketEvents: OptionSet {
    let rawValue: Int

    static let read = SocketEvents(rawValue: 1 << 0)
    static let write = SocketEvents(rawValue: 1 << 1)
}

enum SocketPoller {
    private final class WaitState: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var sources: [DispatchSourceProtocol] = []
        private var timeoutItem: DispatchWorkItem?
        private var continuation: CheckedContinuation<Bool, any Error>?

        func setup(
            continuation: CheckedContinuation<Bool, any Error>,
            sources: [DispatchSourceProtocol],
            timeoutItem: DispatchWorkItem?
        ) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
            self.sources = sources
            self.timeoutItem = timeoutItem
        }

        func finish(_ ready: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return }
            completed = true
            timeoutItem?.cancel()
            sources.forEach { $0.cancel() }
            continuation?.resume(returning: ready)
            continuation = nil
        }
    }

    static func waitAsync(socket: Int32, events: SocketEvents, timeout: TimeInterval?) async throws -> Bool {
        try Task.checkCancellation()
        guard !events.isEmpty else { return false }

        let state = WaitState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let queue = DispatchQueue.global(qos: .utility)
                var sources: [DispatchSourceProtocol] = []
                var timeoutItem: DispatchWorkItem?

                if let timeout, timeout <= 0 {
                    continuation.resume(returning: false)
                    return
                }

                if events.contains(.read) {
                    let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
                    source.setEventHandler { state.finish(true) }
                    source.setCancelHandler {}
                    source.resume()
                    sources.append(source)
                }

                if events.contains(.write) {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: socket, queue: queue)
                    source.setEventHandler { state.finish(true) }
                    source.setCancelHandler {}
                    source.resume()
                    sources.append(source)
                }

                if let timeout, timeout > 0 {
                    let item = DispatchWorkItem { state.finish(false) }
                    timeoutItem = item
                    queue.asyncAfter(deadline: .now() + timeout, execute: item)
                }

                state.setup(continuation: continuation, sources: sources, timeoutItem: timeoutItem)
            }
        } onCancel: {
            state.finish(false)
        }
    }
}
