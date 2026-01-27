import CSSH2
import Foundation

extension NSRemoteShell {
    func readChannelBytes(
        session: SSHSession,
        channel: OpaquePointer,
        buffer: inout [UInt8],
        stderr: Bool,
        deadline: Date?
    ) async throws -> Int {
        while true {
            try Task.checkCancellation()
            let count: Int = session.withLock {
                buffer.withUnsafeMutableBytes { raw in
                    let ptr = raw.bindMemory(to: Int8.self).baseAddress
                    let streamId = stderr ? Int32(SSH_EXTENDED_DATA_STDERR) : 0
                    return Int(libssh2_channel_read_ex(
                        channel, streamId, ptr, raw.count
                    ))
                }
            }
            if count == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            if count < 0 {
                throw session.lastError(fallback: "Channel read failed")
            }
            return count
        }
    }

    func readChannelBytesNonBlocking(
        session: SSHSession,
        channel: OpaquePointer,
        buffer: inout [UInt8],
        stderr: Bool
    ) throws -> Int? {
        let count: Int = session.withLock {
            buffer.withUnsafeMutableBytes { raw in
                let ptr = raw.bindMemory(to: Int8.self).baseAddress
                let streamId = stderr ? Int32(SSH_EXTENDED_DATA_STDERR) : 0
                return Int(libssh2_channel_read_ex(
                    channel, streamId, ptr, raw.count
                ))
            }
        }
        if count == LIBSSH2_ERROR_EAGAIN {
            return nil
        }
        if count < 0 {
            throw session.lastError(fallback: "Channel read failed")
        }
        return count
    }

    func writeChannelBytes(
        session: SSHSession,
        channel: OpaquePointer,
        buffer: [UInt8],
        count: Int,
        deadline: Date? = nil
    ) async throws {
        var sent = 0
        while sent < count {
            try Task.checkCancellation()
            let written = session.withLock {
                buffer.withUnsafeBytes { raw in
                    let ptr = raw.bindMemory(to: Int8.self).baseAddress
                    return Int(libssh2_channel_write_ex(
                        channel, 0, ptr?.advanced(by: sent), count - sent
                    ))
                }
            }
            if written == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            if written < 0 {
                throw session.lastError(fallback: "Channel write failed")
            }
            sent += written
        }
    }

    func closeChannelAsync(session: SSHSession, _ channel: OpaquePointer) async {
        await session.closeChannelAsync(channel, timeout: SSHConstants.operationTimeout)
    }
}
