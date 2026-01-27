import CoreGraphics
import CSSH2
import Foundation

public extension NSRemoteShell {
    @discardableResult
    func execute(
        _ command: String,
        timeout: TimeInterval? = nil,
        onCreate: (() -> Void)? = nil,
        onOutput: @Sendable (String) -> Void,
        shouldContinue: @Sendable () -> Bool = { true }
    ) async throws -> Int32 {
        guard let session else { throw RemoteShellError.disconnected }
        let effectiveTimeout = timeout ?? configuration.timeout
        let channel = try await openSessionChannel(session: session)

        do {
            let execName = "exec"
            let rc: Int32 = try await session.retrying(
                timeout: effectiveTimeout,
                operation: execName.withCString { execPtr in
                    command.withCString { commandPtr in
                        libssh2_channel_process_startup(
                            channel,
                            execPtr,
                            UInt32(execName.utf8.count),
                            commandPtr,
                            UInt32(strlen(commandPtr))
                        )
                    }
                },
                shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
            )
            guard rc == 0 else {
                throw session.lastError(fallback: "Failed to exec command")
            }
            onCreate?()

            var outputBuffer = [UInt8](repeating: 0, count: SSHConstants.bufferSize)
            var errorBuffer = [UInt8](repeating: 0, count: SSHConstants.bufferSize)
            let deadline = Date().addingTimeInterval(effectiveTimeout)

            while true {
                try Task.checkCancellation()
                if deadline.timeIntervalSinceNow <= 0 {
                    break
                }
                if !shouldContinue() {
                    break
                }

                var didRead = false
                let stdout = try await readChannelBytes(
                    session: session,
                    channel: channel,
                    buffer: &outputBuffer,
                    stderr: false,
                    deadline: deadline
                )
                if stdout > 0 {
                    let output = String(decoding: outputBuffer.prefix(stdout), as: UTF8.self)
                    onOutput(output)
                    didRead = true
                }
                let stderr = try await readChannelBytes(
                    session: session,
                    channel: channel,
                    buffer: &errorBuffer,
                    stderr: true,
                    deadline: deadline
                )
                if stderr > 0 {
                    let output = String(decoding: errorBuffer.prefix(stderr), as: UTF8.self)
                    onOutput(output)
                    didRead = true
                }

                if !didRead {
                    let eof = session.withLock { libssh2_channel_eof(channel) }
                    if eof == 1 {
                        break
                    }
                    try await session.waitForSocket(deadline: deadline)
                }
            }

            let exitStatus = session.withLock { libssh2_channel_get_exit_status(channel) }
            await closeChannelAsync(session: session, channel)
            return exitStatus
        } catch {
            await closeChannelAsync(session: session, channel)
            throw error
        }
    }

    func openShell(
        terminalType: String? = nil,
        onCreate: (() -> Void)? = nil,
        terminalSize: @Sendable () -> CGSize = { .zero },
        writeData: @Sendable () -> String? = { nil },
        onOutput: @Sendable (String) -> Void,
        shouldContinue: @Sendable () -> Bool = { true }
    ) async throws {
        guard let session else { throw RemoteShellError.disconnected }
        let channel = try await openSessionChannel(session: session)

        do {
            if let terminalType {
                let rc: Int32 = try await session.retrying(
                    timeout: configuration.timeout,
                    operation: libssh2_channel_request_pty_ex(
                        channel,
                        terminalType,
                        UInt32(terminalType.utf8.count),
                        nil, 0,
                        80, 24,
                        0, 0
                    ),
                    shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
                )
                guard rc == 0 else {
                    throw session.lastError(fallback: "Failed to request pseudo terminal")
                }
            }

            let shellName = "shell"
            let shellRc: Int32 = try await session.retrying(
                timeout: configuration.timeout,
                operation: shellName.withCString { shellPtr in
                    libssh2_channel_process_startup(
                        channel,
                        shellPtr,
                        UInt32(shellName.utf8.count),
                        nil,
                        0
                    )
                },
                shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
            )
            guard shellRc == 0 else {
                throw session.lastError(fallback: "Failed to open shell")
            }
            onCreate?()

            var lastTerminalSize = CGSize.zero
            var buffer = [UInt8](repeating: 0, count: SSHConstants.bufferSize)
            let deadline = Date().addingTimeInterval(configuration.timeout)

            while shouldContinue() {
                try Task.checkCancellation()
                let size = terminalSize()
                if size != lastTerminalSize {
                    lastTerminalSize = size
                    _ = try await session.retrying(
                        timeout: configuration.timeout,
                        operation: libssh2_channel_request_pty_size_ex(
                            channel,
                            Int32(size.width),
                            Int32(size.height),
                            0, 0
                        ),
                        shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
                    )
                }

                if let data = writeData(), !data.isEmpty {
                    try await writeChannel(channel: channel, data: data, deadline: deadline)
                }

                if let readCount = try readChannelBytesNonBlocking(
                    session: session,
                    channel: channel,
                    buffer: &buffer,
                    stderr: false
                ) {
                    if readCount > 0 {
                        let output = String(decoding: buffer.prefix(readCount), as: UTF8.self)
                        onOutput(output)
                        continue
                    }
                    // readCount == 0 means channel closed
                    break
                }

                let eof = session.withLock { libssh2_channel_eof(channel) }
                if eof == 1 {
                    break
                }

                // Short wait for interactive responsiveness — wake quickly to check
                // writeData(), terminalSize(), and shouldContinue() callbacks
                _ = try? await SocketPoller.waitAsync(
                    socket: session.socket,
                    events: [.read],
                    timeout: SSHConstants.shellPollInterval
                )
            }

            await closeChannelAsync(session: session, channel)
        } catch {
            await closeChannelAsync(session: session, channel)
            throw error
        }
    }
}

private extension NSRemoteShell {
    func openSessionChannel(session: SSHSession) async throws -> OpaquePointer {
        try await session.retryingForPointer(timeout: configuration.timeout) {
            let sessionName = "session"
            return sessionName.withCString { namePtr in
                libssh2_channel_open_ex(
                    session.session,
                    namePtr,
                    UInt32(sessionName.utf8.count),
                    SSHConstants.channelWindowSize,
                    SSHConstants.channelPacketSize,
                    nil,
                    0
                )
            }
        }
    }

    func writeChannel(channel: OpaquePointer, data: String, deadline: Date? = nil) async throws {
        guard let session else { throw RemoteShellError.disconnected }
        let buffer = Array(data.utf8)
        try await writeChannelBytes(
            session: session,
            channel: channel,
            buffer: buffer,
            count: buffer.count,
            deadline: deadline
        )
    }
}
