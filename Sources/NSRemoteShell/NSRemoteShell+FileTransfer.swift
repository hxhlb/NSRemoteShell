import CSSH2
import Darwin
import Foundation

public extension NSRemoteShell {
    func connectFileTransfer() async throws {
        guard let session else { throw RemoteShellError.disconnected }
        guard isAuthenticated else { throw RemoteShellError.authenticationRequired }
        if fileTransferSession != nil {
            return
        }
        let newSession = try await openFileTransferSession(session: session)
        fileTransferSession = newSession
        isConnectedFileTransfer = true
    }

    func disconnectFileTransfer() async {
        guard let session else {
            fileTransferSession = nil
            isConnectedFileTransfer = false
            return
        }
        if let fileTransferSession {
            await session.closeFileTransferSessionAsync(fileTransferSession, timeout: SSHConstants.operationTimeout)
            self.fileTransferSession = nil
        }
        isConnectedFileTransfer = false
    }

    func listFiles(at path: String) async throws -> [RemoteFile] {
        let (session, transfer) = try requireFileTransfer()
        let handle = try await openFileTransferHandle(
            session: session,
            fileTransfer: transfer,
            path: path,
            flags: CUnsignedLong(0),
            mode: CLong(0),
            openType: CInt(LIBSSH2_SFTP_OPENDIR)
        )

        var results: [RemoteFile] = []
        var buffer = [UInt8](repeating: 0, count: 512)
        let deadline = Date().addingTimeInterval(configuration.timeout)

        do {
            while true {
                var attributes = LIBSSH2_SFTP_ATTRIBUTES()
                let readCount = buffer.withUnsafeMutableBytes { raw in
                    let ptr = raw.bindMemory(to: Int8.self).baseAddress
                    return Int(libssh2_sftp_readdir_ex(
                        handle,
                        ptr,
                        raw.count,
                        nil,
                        0,
                        &attributes
                    ))
                }
                if readCount > 0 {
                    let name = String(decoding: buffer.prefix(readCount), as: UTF8.self)
                    if name != ".", name != ".." {
                        results.append(RemoteFile(name: name, attributes: attributes))
                    }
                    continue
                }
                if readCount == 0 {
                    break
                }
                if readCount == LIBSSH2_ERROR_EAGAIN {
                    try await session.waitForSocket(deadline: deadline)
                    continue
                }
                throw session.lastError(fallback: "Failed to read directory")
            }
        } catch {
            await session.closeFileTransferHandleAsync(handle, timeout: SSHConstants.operationTimeout)
            throw error
        }

        await session.closeFileTransferHandleAsync(handle, timeout: SSHConstants.operationTimeout)
        return results.sorted { $0.name < $1.name }
    }

    func fileInfo(at path: String) async throws -> RemoteFile {
        let (session, transfer) = try requireFileTransfer()
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        let deadline = Date().addingTimeInterval(configuration.timeout)

        while true {
            try Task.checkCancellation()
            if deadline.timeIntervalSinceNow <= 0 {
                throw RemoteShellError.timeout
            }
            let rc = session.withLock {
                path.withCString { cPath in
                    libssh2_sftp_stat_ex(
                        transfer, cPath, UInt32(strlen(cPath)),
                        LIBSSH2_SFTP_STAT, &attributes
                    )
                }
            }
            if rc == 0 {
                break
            }
            if rc == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            throw session.lastError(fallback: "Failed to stat file")
        }
        return RemoteFile(name: URL(fileURLWithPath: path).lastPathComponent, attributes: attributes)
    }

    func renameFile(at path: String, to newPath: String) async throws {
        let (session, transfer) = try requireFileTransfer()
        guard path.hasPrefix("/"), newPath.hasPrefix("/") else {
            throw RemoteShellError.invalidConfiguration("File transfer rename requires absolute paths")
        }
        let flags = CLong(
            LIBSSH2_SFTP_RENAME_OVERWRITE
                | LIBSSH2_SFTP_RENAME_ATOMIC
                | LIBSSH2_SFTP_RENAME_NATIVE
        )
        _ = try await session.retrying(
            timeout: configuration.timeout,
            operation: path.withCString { source in
                newPath.withCString { destination in
                    libssh2_sftp_rename_ex(
                        transfer,
                        source, UInt32(strlen(source)),
                        destination, UInt32(strlen(destination)),
                        flags
                    )
                }
            },
            shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
        )
    }

    func createDirectory(at path: String) async throws {
        let (session, transfer) = try requireFileTransfer()
        if let info = try? await fileInfo(at: path), info.isDirectory {
            return
        }
        let mode = CLong(
            LIBSSH2_SFTP_S_IRWXU
                | LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IXGRP
                | LIBSSH2_SFTP_S_IROTH | LIBSSH2_SFTP_S_IXOTH
        )
        let rc = try await session.retrying(
            timeout: configuration.timeout,
            operation: path.withCString { cPath in
                libssh2_sftp_mkdir_ex(transfer, cPath, UInt32(strlen(cPath)), mode)
            },
            shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
        )
        guard rc == 0 else {
            throw session.lastError(fallback: "Failed to create remote directory")
        }
    }

    func deleteFile(
        at path: String,
        onProgress: @Sendable (String) -> Void,
        shouldContinue: @Sendable () -> Bool = { true }
    ) async throws {
        let (session, transfer) = try requireFileTransfer()
        try await deleteRecursively(
            session: session,
            fileTransfer: transfer,
            path: path,
            depth: 0,
            onProgress: onProgress,
            shouldContinue: shouldContinue
        )
    }

    func uploadFile(
        at localPath: String,
        to remoteDirectory: String,
        onProgress: @Sendable (Progress, Double) -> Void,
        shouldContinue: @Sendable () -> Bool = { true }
    ) async throws {
        let expandedPath = NSString(string: localPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            let remoteTarget = URL(fileURLWithPath: remoteDirectory).appendingPathComponent(url.lastPathComponent)
            try await createDirectory(at: remoteTarget.path)
            let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
            for entry in contents {
                let childLocal = url.appendingPathComponent(entry)
                try await uploadFile(
                    at: childLocal.path,
                    to: remoteTarget.path,
                    onProgress: onProgress,
                    shouldContinue: shouldContinue
                )
            }
            return
        }

        guard let session else { throw RemoteShellError.disconnected }
        let remoteFile = URL(fileURLWithPath: remoteDirectory).appendingPathComponent(url.lastPathComponent)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let channel = try await openSecureCopySend(session: session, path: remoteFile.path, mode: mode, size: size)
        let deadline = Date().addingTimeInterval(configuration.timeout)

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            await closeChannelAsync(session: session, channel)
            throw error
        }
        defer { try? handle.close() }

        let start = Date()
        var lastProgress = Date(timeIntervalSince1970: 0)
        var sent: UInt64 = 0

        while sent < size {
            if !shouldContinue() || !isConnectedFileTransfer {
                break
            }
            let data = handle.readData(ofLength: SSHConstants.fileTransferBufferSize)
            if data.isEmpty { break }
            let bytes = [UInt8](data)
            do {
                try await writeChannelBytes(
                    session: session,
                    channel: channel,
                    buffer: bytes,
                    count: bytes.count,
                    deadline: deadline
                )
            } catch {
                await closeChannelAsync(session: session, channel)
                throw error
            }
            sent += UInt64(bytes.count)
            if lastProgress.timeIntervalSinceNow < -0.2 {
                lastProgress = Date()
                let interval = max(Date().timeIntervalSince(start), 0.001)
                let speed = Double(sent) / interval
                let progress = Progress(totalUnitCount: Int64(size))
                progress.completedUnitCount = Int64(sent)
                await MainActor.run {
                    onProgress(progress, speed)
                }
            }
        }

        let interval = max(Date().timeIntervalSince(start), 0.001)
        let speed = Double(sent) / interval
        let progress = Progress(totalUnitCount: Int64(size))
        progress.completedUnitCount = Int64(sent)
        await MainActor.run {
            onProgress(progress, speed)
        }

        await closeChannelAsync(session: session, channel)

        if sent < size {
            throw RemoteShellError.libssh2Error(code: -1, message: "Upload incomplete")
        }
    }

    func downloadFile(
        at remotePath: String,
        to localPath: String,
        onProgress: @Sendable (Progress, Double) -> Void,
        shouldContinue: @Sendable () -> Bool = { true }
    ) async throws {
        let (session, _) = try requireFileTransfer()
        try await downloadRecursive(
            session: session,
            remotePath: remotePath,
            localPath: localPath,
            depth: 0,
            onProgress: onProgress,
            shouldContinue: shouldContinue
        )
    }
}

private extension NSRemoteShell {
    func requireFileTransfer() throws -> (SSHSession, OpaquePointer) {
        guard let session else { throw RemoteShellError.disconnected }
        guard let fileTransferSession else { throw RemoteShellError.fileTransferUnavailable }
        return (session, fileTransferSession)
    }

    func openFileTransferSession(session: SSHSession) async throws -> OpaquePointer {
        try await session.retryingForPointer(timeout: configuration.timeout) {
            libssh2_sftp_init(session.session)
        }
    }

    func openFileTransferHandle(
        session: SSHSession,
        fileTransfer: OpaquePointer,
        path: String,
        flags: CUnsignedLong,
        mode: CLong,
        openType: CInt
    ) async throws -> OpaquePointer {
        try await session.retryingForPointer(timeout: configuration.timeout) {
            path.withCString { cPath in
                libssh2_sftp_open_ex(
                    fileTransfer,
                    cPath,
                    UInt32(strlen(cPath)),
                    flags,
                    mode,
                    openType
                )
            }
        }
    }

    func deleteRecursively(
        session: SSHSession,
        fileTransfer: OpaquePointer,
        path: String,
        depth: Int,
        onProgress: @Sendable (String) -> Void,
        shouldContinue: @Sendable () -> Bool
    ) async throws {
        if depth > SSHConstants.fileTransferRecursiveDepth {
            throw RemoteShellError.invalidConfiguration("File transfer delete exceeded depth limit")
        }
        if !shouldContinue() {
            throw RemoteShellError.invalidConfiguration("Delete cancelled")
        }

        if let info = try? await fileInfo(at: path), info.isDirectory {
            let children = try await listFiles(at: path)
            for child in children {
                let childPath = URL(fileURLWithPath: path).appendingPathComponent(child.name).path
                try await deleteRecursively(
                    session: session,
                    fileTransfer: fileTransfer,
                    path: childPath,
                    depth: depth + 1,
                    onProgress: onProgress,
                    shouldContinue: shouldContinue
                )
            }
            await MainActor.run { onProgress(path) }
            try await removeDirectory(session: session, fileTransfer: fileTransfer, path: path)
        } else {
            await MainActor.run { onProgress(path) }
            try await unlinkFile(session: session, fileTransfer: fileTransfer, path: path)
        }
    }

    func removeDirectory(session: SSHSession, fileTransfer: OpaquePointer, path: String) async throws {
        let rc = try await session.retrying(
            timeout: configuration.timeout,
            operation: path.withCString { cPath in
                libssh2_sftp_rmdir_ex(fileTransfer, cPath, UInt32(strlen(cPath)))
            },
            shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
        )
        guard rc == 0 else {
            throw session.lastError(fallback: "Failed to remove directory")
        }
    }

    func unlinkFile(session: SSHSession, fileTransfer: OpaquePointer, path: String) async throws {
        let rc = try await session.retrying(
            timeout: configuration.timeout,
            operation: path.withCString { cPath in
                libssh2_sftp_unlink_ex(fileTransfer, cPath, UInt32(strlen(cPath)))
            },
            shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
        )
        guard rc == 0 else {
            throw session.lastError(fallback: "Failed to delete file")
        }
    }

    func openSecureCopySend(session: SSHSession, path: String, mode: Int, size: UInt64) async throws -> OpaquePointer {
        try await session.retryingForPointer(timeout: configuration.timeout) {
            path.withCString { cPath in
                libssh2_scp_send64(
                    session.session,
                    cPath,
                    Int32(mode & 0o777),
                    Int64(size),
                    0,
                    0
                )
            }
        }
    }

    func downloadRecursive(
        session: SSHSession,
        remotePath: String,
        localPath: String,
        depth: Int,
        onProgress: @Sendable (Progress, Double) -> Void,
        shouldContinue: @Sendable () -> Bool
    ) async throws {
        if depth > SSHConstants.fileTransferRecursiveDepth {
            throw RemoteShellError.invalidConfiguration("File transfer download exceeded depth limit")
        }
        if !shouldContinue() {
            throw RemoteShellError.invalidConfiguration("Download cancelled")
        }

        let info = try await fileInfo(at: remotePath)
        let remoteURL = URL(fileURLWithPath: remotePath)
        let localURL = URL(fileURLWithPath: localPath)
        let targetURL = localPath.hasSuffix("/")
            ? localURL.appendingPathComponent(remoteURL.lastPathComponent)
            : localURL

        if info.isDirectory {
            try FileManager.default.createDirectory(
                at: targetURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let children = try await listFiles(at: remotePath)
            for child in children {
                let childRemote = remoteURL.appendingPathComponent(child.name).path
                let childLocal = targetURL.appendingPathComponent(child.name).path
                try await downloadRecursive(
                    session: session,
                    remotePath: childRemote,
                    localPath: childLocal,
                    depth: depth + 1,
                    onProgress: onProgress,
                    shouldContinue: shouldContinue
                )
            }
            return
        }

        let (channel, size) = try await openSecureCopyReceive(session: session, path: remotePath)
        let deadline = Date().addingTimeInterval(configuration.timeout)

        if FileManager.default.fileExists(atPath: targetURL.path) {
            do {
                try FileManager.default.removeItem(at: targetURL)
            } catch {
                await closeChannelAsync(session: session, channel)
                throw error
            }
        }
        FileManager.default.createFile(atPath: targetURL.path, contents: nil)
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: targetURL)
        } catch {
            await closeChannelAsync(session: session, channel)
            throw error
        }
        defer { try? handle.close() }

        var buffer = [UInt8](repeating: 0, count: SSHConstants.fileTransferBufferSize)
        var received: UInt64 = 0
        let start = Date()
        var lastProgress = Date(timeIntervalSince1970: 0)

        while received < size {
            if !shouldContinue() || !isConnectedFileTransfer {
                break
            }
            let readCount: Int
            do {
                readCount = try await readChannelBytes(
                    session: session,
                    channel: channel,
                    buffer: &buffer,
                    stderr: false,
                    deadline: deadline
                )
            } catch {
                await closeChannelAsync(session: session, channel)
                throw error
            }
            if readCount > 0 {
                let remaining = size - received
                let clamped = min(UInt64(readCount), remaining)
                if clamped > 0 {
                    handle.write(Data(buffer.prefix(Int(clamped))))
                    received += clamped
                }
            }

            if lastProgress.timeIntervalSinceNow < -0.1 {
                lastProgress = Date()
                let interval = max(Date().timeIntervalSince(start), 0.001)
                let speed = Double(received) / interval
                let progress = Progress(totalUnitCount: Int64(size))
                progress.completedUnitCount = Int64(received)
                await MainActor.run {
                    onProgress(progress, speed)
                }
            }
        }

        let interval = max(Date().timeIntervalSince(start), 0.001)
        let speed = Double(received) / interval
        let progress = Progress(totalUnitCount: Int64(size))
        progress.completedUnitCount = Int64(received)
        await MainActor.run {
            onProgress(progress, speed)
        }

        await closeChannelAsync(session: session, channel)

        if received < size {
            throw RemoteShellError.libssh2Error(code: -1, message: "Download incomplete")
        }
    }

    func openSecureCopyReceive(session: SSHSession, path: String) async throws -> (OpaquePointer, UInt64) {
        let deadline = Date().addingTimeInterval(configuration.timeout)
        var info = stat()
        while true {
            try Task.checkCancellation()
            if deadline.timeIntervalSinceNow <= 0 {
                throw RemoteShellError.timeout
            }
            let channel = session.withLock {
                path.withCString { cPath in
                    libssh2_scp_recv2(session.session, cPath, &info)
                }
            }
            if let channel {
                return (channel, UInt64(info.st_size))
            }
            let lastErrno = session.withLock { libssh2_session_last_errno(session.session) }
            if lastErrno == LIBSSH2_ERROR_EAGAIN {
                try await session.waitForSocket(deadline: deadline)
                continue
            }
            throw session.lastError(fallback: "Failed to open secure copy download channel")
        }
    }
}
