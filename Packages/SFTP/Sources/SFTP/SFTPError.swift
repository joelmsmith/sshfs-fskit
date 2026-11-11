import Foundation

public enum StatusCode: UInt32, Sendable {
    case ok = 0
    case eof = 1
    case noSuchFile = 2
    case permissionDenied = 3
    case failure = 4
    case badMessage = 5
    case noConnection = 6
    case connectionLost = 7
    case operationUnsupported = 8
}

public enum SFTPError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The server answered with a non-OK STATUS.
    case status(code: UInt32, message: String)
    /// The server sent something we could not parse or did not expect.
    case badMessage(String)
    /// The transport closed or failed. All outstanding and future requests fail.
    case connectionLost(String)
    /// The server negotiated a protocol version we don't speak.
    case unsupportedVersion(UInt32)

    public var statusCode: StatusCode? {
        if case .status(let code, _) = self { return StatusCode(rawValue: code) }
        return nil
    }

    /// Best-effort POSIX errno, for handing back to the kernel.
    ///
    /// SFTP v3 collapses most failures into `SSH_FX_FAILURE`, so callers that
    /// need EEXIST / ENOTEMPTY / ENOTDIR precision must check state themselves.
    public var errno: Int32 {
        switch self {
        case .status(let code, _):
            switch StatusCode(rawValue: code) {
            case .ok: return 0
            case .eof: return EIO
            case .noSuchFile: return ENOENT
            case .permissionDenied: return EACCES
            case .operationUnsupported: return ENOTSUP
            case .noConnection, .connectionLost: return ENOTCONN
            case .badMessage: return EPROTO
            case .failure, nil: return EIO
            }
        case .badMessage: return EPROTO
        case .connectionLost: return ENOTCONN
        case .unsupportedVersion: return EPROTONOSUPPORT
        }
    }

    public var description: String {
        switch self {
        case .status(let code, let message):
            let name = StatusCode(rawValue: code).map { "\($0)" } ?? "code \(code)"
            return message.isEmpty ? "SFTP \(name)" : "SFTP \(name): \(message)"
        case .badMessage(let m): return "SFTP bad message: \(m)"
        case .connectionLost(let m): return "SFTP connection lost: \(m)"
        case .unsupportedVersion(let v): return "SFTP unsupported protocol version \(v)"
        }
    }
}
