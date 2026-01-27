import CSSH2
import Foundation

enum LibSSH2Runtime {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var initialized = false
    private nonisolated(unsafe) static var activity: NSObjectProtocol?

    static func ensureInitialized() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !initialized else { return }
        let rc = libssh2_init(0)
        guard rc == 0 else {
            throw RemoteShellError.notInitialized
        }
        initialized = true
        #if os(macOS)
            activity = ProcessInfo.processInfo.beginActivity(options: [.latencyCritical], reason: "NSRemoteShell active")
        #endif
    }

    static func shutdownIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard initialized else { return }
        libssh2_exit()
        initialized = false
        #if os(macOS)
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
            }
            activity = nil
        #endif
    }
}
