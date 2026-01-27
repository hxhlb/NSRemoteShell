import CSSH2
import Foundation

final class SSHSession: @unchecked Sendable {
    let session: OpaquePointer
    let socket: Int32
    var timeout: TimeInterval
    private let lock = NSLock()

    init(session: OpaquePointer, socket: Int32, timeout: TimeInterval) {
        self.session = session
        self.socket = socket
        self.timeout = timeout
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func waitForSocket(isolation _: isolated (any Actor)? = #isolation, deadline: Date?) async throws {
        let blockDirections = withLock { libssh2_session_block_directions(session) }
        var events: SocketEvents = []
        if (blockDirections & LIBSSH2_SESSION_BLOCK_INBOUND) != 0 {
            events.insert(.read)
        }
        if (blockDirections & LIBSSH2_SESSION_BLOCK_OUTBOUND) != 0 {
            events.insert(.write)
        }
        if events.isEmpty {
            events.insert(.read)
        }

        while true {
            try Task.checkCancellation()
            let waitInterval: TimeInterval
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    throw RemoteShellError.timeout
                }
                waitInterval = min(remaining, SSHConstants.socketWaitSlice)
            } else {
                // No deadline: wait up to socketWaitSlice, then loop to check cancellation
                waitInterval = SSHConstants.socketWaitSlice
            }
            let ready = try await SocketPoller.waitAsync(socket: socket, events: events, timeout: waitInterval)
            if ready {
                return
            }
        }
    }

    // MARK: - Retry Helpers

    func retrying<T>(isolation _: isolated (any Actor)? = #isolation, timeout: TimeInterval?, operation: @autoclosure () -> T, shouldRetry: (T) -> Bool) async throws -> T {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            try Task.checkCancellation()
            let result = withLock { operation() }
            if shouldRetry(result) {
                try await waitForSocket(deadline: deadline)
                continue
            }
            return result
        }
    }

    func retryingForPointer(isolation _: isolated (any Actor)? = #isolation, timeout: TimeInterval?, operation: () -> OpaquePointer?) async throws -> OpaquePointer {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            try Task.checkCancellation()
            if let deadline, deadline.timeIntervalSinceNow <= 0 {
                throw RemoteShellError.timeout
            }

            if let result = withLock({ operation() }) {
                return result
            }
            let lastErrno = withLock { libssh2_session_last_errno(session) }
            guard lastErrno == LIBSSH2_ERROR_EAGAIN else {
                throw lastError(fallback: "Operation failed")
            }
            try await waitForSocket(deadline: deadline)
        }
    }

    // MARK: - Async Close Helpers

    func closeChannelAsync(isolation _: isolated (any Actor)? = #isolation, _ channel: OpaquePointer, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        do {
            _ = try await retrying(
                timeout: timeout,
                operation: libssh2_channel_send_eof(channel),
                shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
            )
        } catch {}

        do {
            _ = try await retrying(
                timeout: max(0, deadline.timeIntervalSinceNow),
                operation: libssh2_channel_close(channel),
                shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
            )
        } catch {}

        do {
            _ = try await retrying(
                timeout: max(0, deadline.timeIntervalSinceNow),
                operation: libssh2_channel_wait_closed(channel),
                shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
            )
        } catch {}

        _ = withLock { libssh2_channel_free(channel) }
    }

    func closeFileTransferHandleAsync(isolation _: isolated (any Actor)? = #isolation, _ handle: OpaquePointer, timeout: TimeInterval) async {
        do {
            _ = try await retrying(
                timeout: timeout,
                operation: libssh2_sftp_close_handle(handle),
                shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
            )
        } catch {}
    }

    func closeFileTransferSessionAsync(isolation _: isolated (any Actor)? = #isolation, _ sftp: OpaquePointer, timeout: TimeInterval) async {
        do {
            _ = try await retrying(
                timeout: timeout,
                operation: libssh2_sftp_shutdown(sftp),
                shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
            )
        } catch {}
    }

    // MARK: - Error

    func lastError(fallback: String) -> RemoteShellError {
        withLock { RemoteShellError.lastError(session: session, fallback: fallback) }
    }
}
