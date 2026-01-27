import Foundation

/// OpaquePointer's Sendable conformance is marked unavailable in Swift stdlib.
/// We override it here because libssh2 session/channel pointers are protected
/// by NSLock in SSHSession and are safe to pass across isolation boundaries.
extension OpaquePointer: @retroactive @unchecked Sendable {}
