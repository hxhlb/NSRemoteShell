import CoreGraphics
import CSSH2
import Foundation

public actor NSRemoteShell {
    public struct Configuration: Sendable {
        public var host: String
        public var port: Int
        public var timeout: TimeInterval

        public init(host: String, port: Int = 22, timeout: TimeInterval = 8) {
            self.host = host
            self.port = port
            self.timeout = timeout
        }
    }

    public internal(set) var isConnected = false
    public internal(set) var isConnectedFileTransfer = false
    public internal(set) var isAuthenticated = false

    public internal(set) var resolvedRemoteIpAddress: String?
    public internal(set) var remoteBanner: String?
    public internal(set) var remoteFingerPrint: String?

    public private(set) var configuration: Configuration

    var session: SSHSession?
    var fileTransferSession: OpaquePointer?
    var keepAliveFailures = 0
    var keepAliveTask: Task<Void, Never>?
    var forwardTasks: [UUID: Task<Void, Never>] = [:]

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public init(host: String, port: Int = 22, timeout: TimeInterval = 8) {
        configuration = Configuration(host: host, port: port, timeout: timeout)
    }

    public func updateConfiguration(_ update: (inout Configuration) -> Void) {
        update(&configuration)
    }

    /// Explicit close method for deterministic cleanup. Call this instead of relying on deinit.
    public func close() async {
        await disconnect()
    }

    deinit {
        // Best-effort cleanup only. Users should call close() explicitly for reliable cleanup.
        // The Task may never execute if the actor is being deallocated.
        keepAliveTask?.cancel()
    }
}
