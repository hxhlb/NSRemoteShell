import CSSH2
import Foundation

public extension NSRemoteShell {
    func connect() async throws {
        try LibSSH2Runtime.ensureInitialized()
        guard !configuration.host.isEmpty else {
            throw RemoteShellError.invalidConfiguration("Remote host is required")
        }
        guard configuration.timeout > 0 else {
            throw RemoteShellError.invalidConfiguration("Timeout must be positive")
        }
        guard configuration.port >= 0, configuration.port <= 65535 else {
            throw RemoteShellError.invalidConfiguration("Port must be 0-65535")
        }

        let socket = try SocketUtilities.createConnectedSocket(
            host: configuration.host,
            port: configuration.port,
            nonBlocking: true
        )

        // Wait for non-blocking connect to complete
        do {
            let connected = try await SocketUtilities.waitForConnect(socket: socket, timeout: configuration.timeout)
            guard connected else {
                SocketUtilities.closeSocket(socket)
                throw RemoteShellError.timeout
            }
        } catch {
            SocketUtilities.closeSocket(socket)
            throw error
        }

        guard let sessionPtr = libssh2_session_init_ex(nil, nil, nil, nil) else {
            SocketUtilities.closeSocket(socket)
            throw RemoteShellError.libssh2Error(code: -1, message: "Unable to initialize session")
        }

        let session = SSHSession(session: sessionPtr, socket: socket, timeout: configuration.timeout)
        libssh2_session_set_blocking(sessionPtr, 0)

        do {
            let rc: Int32 = try await session.retrying(
                timeout: configuration.timeout,
                operation: libssh2_session_handshake(sessionPtr, socket),
                shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
            )
            if rc != 0 {
                throw session.lastError(fallback: "Session handshake failed")
            }
        } catch {
            libssh2_session_free(sessionPtr)
            SocketUtilities.closeSocket(socket)
            throw error
        }

        self.session = session
        isConnected = true
        resolvedRemoteIpAddress = SocketUtilities.peerAddress(for: socket)
        remoteBanner = libssh2_session_banner_get(sessionPtr).map { String(cString: $0) }
        remoteFingerPrint = Self.formatFingerprint(session: sessionPtr)
        startKeepAlive()
    }

    func disconnect() async {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        keepAliveFailures = 0

        isConnected = false
        isAuthenticated = false
        isConnectedFileTransfer = false

        await shutdownForwards()

        if let fileTransferSession, let session {
            await session.closeFileTransferSessionAsync(fileTransferSession, timeout: SSHConstants.operationTimeout)
            self.fileTransferSession = nil
        }

        if let session {
            let message = "closed by client"
            message.withCString { cString in
                _ = libssh2_session_disconnect_ex(
                    session.session,
                    SSH_DISCONNECT_BY_APPLICATION,
                    cString,
                    ""
                )
            }
            libssh2_session_free(session.session)
            SocketUtilities.closeSocket(session.socket)
        }
        session = nil
    }

    func authenticate(username: String, password: String) async throws {
        guard let session else {
            throw RemoteShellError.disconnected
        }
        let rc: Int32 = try await session.retrying(
            timeout: configuration.timeout,
            operation: libssh2_userauth_password_ex(
                session.session,
                username,
                UInt32(username.utf8.count),
                password,
                UInt32(password.utf8.count),
                nil
            ),
            shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
        )
        guard rc == 0 else {
            throw session.lastError(fallback: "Authentication failed")
        }
        isAuthenticated = true
    }

    func authenticate(username: String, publicKey: String?, privateKey: String, password: String?) async throws {
        guard let session else {
            throw RemoteShellError.disconnected
        }
        let rc: Int32 = try await session.retrying(
            timeout: configuration.timeout,
            operation: libssh2_userauth_publickey_fromfile_ex(
                session.session,
                username,
                UInt32(username.utf8.count),
                publicKey,
                privateKey,
                password
            ),
            shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
        )
        guard rc == 0 else {
            throw session.lastError(fallback: "Authentication failed")
        }
        isAuthenticated = true
    }
}

private extension NSRemoteShell {
    func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(SSHConstants.keepAliveInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await sendKeepAlive()
            }
        }
    }

    func sendKeepAlive() async {
        guard let session, isConnected else { return }
        var nextInterval: Int32 = 0
        do {
            _ = try await session.retrying(
                timeout: configuration.timeout,
                operation: libssh2_keepalive_send(session.session, &nextInterval),
                shouldRetry: { $0 == LIBSSH2_ERROR_EAGAIN }
            )
            keepAliveFailures = 0
        } catch {
            keepAliveFailures += 1
            if keepAliveFailures > SSHConstants.keepAliveErrorTolerance {
                await disconnect()
            }
        }
    }

    static func formatFingerprint(session: OpaquePointer) -> String? {
        // Prefer SHA256, fall back to SHA1
        if let hash = libssh2_hostkey_hash(session, Int32(LIBSSH2_HOSTKEY_HASH_SHA256)) {
            var output = ""
            for index in 0 ..< 32 {
                output += String(format: "%02x", hash[index])
            }
            return output
        }
        if let hash = libssh2_hostkey_hash(session, Int32(LIBSSH2_HOSTKEY_HASH_SHA1)) {
            var output = ""
            for index in 0 ..< 20 {
                output += String(format: "%02x", hash[index])
            }
            return output
        }
        return nil
    }
}
