import Foundation
import Synchronization

/// A raw response packet: its type and a reader positioned after the request id.
struct Response: Sendable {
    let type: PacketType
    let payload: [UInt8]
    let bodyOffset: Int

    var reader: WireReader { WireReader(payload, offset: bodyOffset) }
}

/// Frames packets over a transport and matches responses to requests by id.
///
/// A dedicated thread does blocking reads; a serial queue does writes. Any
/// number of requests may be in flight at once.
final class Connection: Sendable {
    private struct State {
        var nextID: UInt32 = 1
        var pending: [UInt32: CheckedContinuation<Response, any Error>] = [:]
        var versionWaiter: CheckedContinuation<Response, any Error>?
        var failure: SFTPError?
    }

    /// Hard cap on incoming packets; OpenSSH's own limit is 256 KiB.
    static let maxIncomingPacket = 4 * 1024 * 1024

    private let transport: SFTPTransport
    private let state = Mutex(State())
    private let writeQueue = DispatchQueue(label: "sftp.write")

    init(transport: SFTPTransport) {
        self.transport = transport
        let thread = Thread { [self] in readLoop() }
        thread.name = "sftp.read"
        thread.start()
    }

    // MARK: Sending

    /// Sends INIT and waits for VERSION (neither carries a request id).
    func handshake(version: UInt32) async throws -> Response {
        try await withCheckedThrowingContinuation { cont in
            let failure = state.withLock { s -> SFTPError? in
                if let f = s.failure { return f }
                s.versionWaiter = cont
                return nil
            }
            if let failure { cont.resume(throwing: failure); return }
            var w = WireWriter()
            w.u8(PacketType.initialize.rawValue)
            w.u32(version)
            enqueueWrite(w.bytes)
        }
    }

    /// Sends a request and waits for its response. `body` writes everything
    /// after the request id.
    func request(_ type: PacketType, _ body: (inout WireWriter) -> Void) async throws -> Response {
        var w = WireWriter()
        w.u8(type.rawValue)
        w.u32(0) // placeholder id, patched below
        body(&w)
        let packet = w.bytes
        return try await withCheckedThrowingContinuation { cont in
            let result = state.withLock { s -> Result<UInt32, SFTPError> in
                if let f = s.failure { return .failure(f) }
                let id = s.nextID
                s.nextID = s.nextID == UInt32.max ? 1 : s.nextID + 1
                s.pending[id] = cont
                return .success(id)
            }
            switch result {
            case .failure(let f):
                cont.resume(throwing: f)
            case .success(let id):
                var p = packet
                p[1] = UInt8(truncatingIfNeeded: id >> 24)
                p[2] = UInt8(truncatingIfNeeded: id >> 16)
                p[3] = UInt8(truncatingIfNeeded: id >> 8)
                p[4] = UInt8(truncatingIfNeeded: id)
                enqueueWrite(p)
            }
        }
    }

    private func enqueueWrite(_ packet: [UInt8]) {
        writeQueue.async { [self] in
            var frame = WireWriter(capacity: packet.count + 4)
            frame.u32(UInt32(packet.count))
            var bytes = frame.bytes
            bytes.append(contentsOf: packet)
            if let err = writeAll(bytes) {
                fail(.connectionLost("write failed: \(String(cString: strerror(err)))"))
            }
        }
    }

    private func writeAll(_ bytes: [UInt8]) -> Int32? {
        bytes.withUnsafeBytes { buf -> Int32? in
            var off = 0
            while off < buf.count {
                let n = write(transport.writeFD, buf.baseAddress! + off, buf.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && errno == EINTR { continue }
                return n < 0 ? errno : EPIPE
            }
            return nil
        }
    }

    // MARK: Receiving

    private func readLoop() {
        while true {
            guard let header = readExactly(4) else {
                fail(.connectionLost("server closed the connection"))
                return
            }
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= Self.maxIncomingPacket else {
                fail(.badMessage("invalid packet length \(length)"))
                return
            }
            guard let packet = readExactly(length) else {
                fail(.connectionLost("server closed the connection mid-packet"))
                return
            }
            dispatch(packet)
        }
    }

    private func readExactly(_ n: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { read(transport.readFD, $0.baseAddress! + got, n - got) }
            if r > 0 { got += r; continue }
            if r < 0 && errno == EINTR { continue }
            return nil
        }
        return buf
    }

    private func dispatch(_ packet: [UInt8]) {
        guard let type = PacketType(rawValue: packet[0]) else {
            fail(.badMessage("unknown packet type \(packet[0])"))
            return
        }
        if type == .version {
            let waiter = state.withLock { s in
                defer { s.versionWaiter = nil }
                return s.versionWaiter
            }
            waiter?.resume(returning: Response(type: type, payload: packet, bodyOffset: 1))
            return
        }
        var r = WireReader(packet, offset: 1)
        guard let id = try? r.u32() else {
            fail(.badMessage("packet without request id"))
            return
        }
        let cont = state.withLock { $0.pending.removeValue(forKey: id) }
        guard let cont else {
            fail(.badMessage("response for unknown request id \(id)"))
            return
        }
        cont.resume(returning: Response(type: type, payload: packet, bodyOffset: 5))
    }

    // MARK: Failure

    /// Fails every outstanding and future request. Idempotent.
    func fail(_ error: SFTPError) {
        let (waiters, version) = state.withLock { s -> ([CheckedContinuation<Response, any Error>], CheckedContinuation<Response, any Error>?) in
            if s.failure == nil { s.failure = error }
            let w = Array(s.pending.values)
            let v = s.versionWaiter
            s.pending.removeAll()
            s.versionWaiter = nil
            return (w, v)
        }
        let err = state.withLock { $0.failure! }
        for w in waiters { w.resume(throwing: err) }
        version?.resume(throwing: err)
        transport.close()
    }

    var failure: SFTPError? { state.withLock { $0.failure } }
}
