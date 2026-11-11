import Foundation
import FSKit
import SFTP
import Synchronization

/// One live SFTP connection plus the generation it belongs to. Handles are
/// only valid within the generation that opened them.
struct Session: Sendable {
    let client: SFTPClient
    let generation: UInt64
}

/// Owns the SFTP connection and transparently re-establishes it.
///
/// When a call fails because the connection died, one reconnect runs in the
/// background (with backoff) and every caller waits for it, up to
/// `waitLimit`. Idempotent calls are then retried once on the new connection.
///
/// Reconnecting is silent. If ssh turns out to need the user (a password
/// that isn't in the keychain, a new host key), they are asked once per
/// outage; if that doesn't produce a connection, reconnecting *stops* and
/// calls fail with EAUTH until `userCheck()` (`SSHFS check`) -- rather than
/// showing dialogs in a loop or hammering the server with failed logins.
final class Remote: Sendable {
    private struct State {
        var session: Session?
        var nextGeneration: UInt64 = 1
        /// Finishes with nil if reconnecting stopped (see `blocked`).
        var reconnecting: Task<Session?, Never>?
        /// When the current outage began (nil while connected).
        var downSince: ContinuousClock.Instant?
        /// Set when reconnecting stopped because it needs the user.
        var blocked: ConnectError?
    }

    /// Makes a new connection; the argument says whether the user may be asked.
    private let connect: @Sendable (_ interactive: Bool) async throws -> SFTPClient
    private let state: Mutex<State>
    /// How long a call waits for a reconnect before failing with ENOTCONN.
    let waitLimit: Duration
    /// A call unanswered for this long triggers a health check. (Large reads
    /// and writes stay well under it on any link that's actually up.)
    static let stallThreshold: Duration = .seconds(5)
    /// Capabilities of the server, from the first connection.
    let extensions: [String: String]

    init(initial: SFTPClient, waitLimit: Duration = .seconds(20),
         connect: @escaping @Sendable (_ interactive: Bool) async throws -> SFTPClient) {
        self.connect = connect
        self.waitLimit = waitLimit
        self.extensions = initial.serverExtensions
        self.state = Mutex(State(session: Session(client: initial, generation: 0)))
    }

    func supports(_ ext: String) -> Bool { extensions[ext] != nil }

    /// Runs `op` against the current connection. If the connection is lost
    /// and `idempotent` is true, waits for a reconnect and retries once.
    func run<T: Sendable>(idempotent: Bool = true,
                          _ op: @Sendable (Session) async throws -> T) async throws -> T {
        let session = try await current()
        // Stall watchdog: if this call gets no answer for `stallThreshold`,
        // probe the connection. A dead one is dropped, which fails this call
        // with connectionLost -- and the retry below runs on a fresh one.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.stallThreshold)
            guard !Task.isCancelled else { return }
            await self?.healthCheck(reason: "stalled request")
        }
        defer { watchdog.cancel() }
        do {
            return try await op(session)
        } catch let error as SFTPError where Self.isConnectionLoss(error) {
            markDead(session)
            guard idempotent else { throw error }
            log.notice("retrying after connection loss")
            return try await op(try await current())
        }
    }

    /// The live session, waiting (bounded) for a reconnect if necessary.
    func current() async throws -> Session {
        let (session, task, longOutage, blocked) = state.withLock {
            s -> (Session?, Task<Session?, Never>?, Bool, ConnectError?) in
            if let live = s.session, live.client.failure == nil { return (live, nil, false, nil) }
            if s.session != nil { markDeadLocked(&s) }
            if let blocked = s.blocked { return (nil, nil, false, blocked) }
            let long = s.downSince.map { ContinuousClock.now - $0 > waitLimit } ?? false
            return (nil, startReconnectLocked(&s), long, nil)
        }
        if let session { return session }
        if let blocked { throw blocked }
        // Once an outage has outlasted one full wait, fail fast instead of
        // making every operation (and Finder) stall; reconnect continues.
        if longOutage { throw SFTPError.connectionLost("server unreachable; still reconnecting") }
        return try await wait(for: task!)
    }

    /// Waits for the reconnect, but no longer than `waitLimit`. (A task group
    /// can't do this: it always awaits all children, and the reconnect child
    /// doesn't finish while the server is unreachable.)
    private func wait(for task: Task<Session?, Never>) async throws -> Session {
        guard let finished = await boundedWait(task, limit: waitLimit) else {
            throw SFTPError.connectionLost("server unreachable; still reconnecting")
        }
        guard let session = finished else {
            throw state.withLock { $0.blocked } ?? ConnectError(errno: EAUTH)
        }
        return session
    }

    /// The user asked for a check (`SSHFS check`). If reconnecting had
    /// stopped to wait for them, it starts again and may ask them once more.
    func userCheck() async {
        let restarted = state.withLock { s -> Bool in
            guard s.blocked != nil, s.session == nil else { return false }
            s.blocked = nil
            _ = startReconnectLocked(&s)
            return true
        }
        if restarted {
            log.notice("reconnecting again at the user's request")
        } else {
            await healthCheck(reason: "manual")
        }
    }

    /// Probes the current connection with a cheap request. If it doesn't
    /// answer within `timeout` (e.g. a silently dead TCP connection after
    /// sleep or a network change), drops it and starts reconnecting now.
    func healthCheck(reason: String, timeout: Duration = .seconds(3)) async {
        let session = state.withLock { s -> Session? in
            guard let live = s.session, live.client.failure == nil else { return nil }
            return live
        }
        guard let session else { return }  // already reconnecting
        let probe = Task { (try? await session.client.realpath(".")) != nil }
        let ok = await boundedWait(probe, limit: timeout)
        if ok == true {
            log.info("health check (\(reason, privacy: .public)): connection OK")
        } else {
            log.notice("health check (\(reason, privacy: .public)): no answer in \(timeout); reconnecting")
            markDead(session)
        }
    }

    func disconnect() {
        let session = state.withLock { s -> Session? in
            s.reconnecting?.cancel()
            defer { s.session = nil }
            return s.session
        }
        session?.client.disconnect()
    }

    // MARK: Internals

    static func isConnectionLoss(_ e: SFTPError) -> Bool {
        if case .connectionLost = e { return true }
        return false
    }

    private func markDead(_ session: Session) {
        state.withLock { s in
            if s.session?.generation == session.generation { markDeadLocked(&s) }
        }
    }

    private func markDeadLocked(_ s: inout State) {
        guard let dead = s.session else { return }
        log.error("connection lost (generation \(dead.generation))")
        dead.client.disconnect()
        s.session = nil
        if s.downSince == nil { s.downSince = .now }
        _ = startReconnectLocked(&s)
    }

    /// Starts (or joins) the single reconnect loop. Retries with exponential
    /// backoff; callers stop waiting after `waitLimit` but the loop keeps
    /// going so the mount heals on its own. It ends only with a connection,
    /// or (with nil, and `blocked` set) when it can't go on without the user.
    private func startReconnectLocked(_ s: inout State) -> Task<Session?, Never> {
        if let t = s.reconnecting { return t }
        let generation = s.nextGeneration
        s.nextGeneration += 1
        let task = Task<Session?, Never> { [connect] in
            var delay = Duration.milliseconds(250)
            var attempt = 1
            var mayAsk = true  // one question per outage
            func connected(_ client: SFTPClient) -> Session? {
                guard !Task.isCancelled else { client.disconnect(); return nil }
                let session = Session(client: client, generation: generation)
                log.notice("reconnected (generation \(generation), attempt \(attempt))")
                self.state.withLock { $0.session = session; $0.reconnecting = nil; $0.downSince = nil }
                return session
            }
            while !Task.isCancelled {
                var failure: ConnectError?
                do {
                    return connected(try await connect(false))
                } catch {
                    failure = error as? ConnectError
                    log.error("reconnect attempt \(attempt) failed: \(String(describing: error), privacy: .public)")
                }
                if failure?.needsPrompt == true, mayAsk {
                    // The server is there and wants something only the user has.
                    log.notice("reconnecting needs the user; asking")
                    do {
                        return connected(try await connect(true))
                    } catch {
                        failure = error as? ConnectError
                        log.error("reconnect with questions failed: \(String(describing: error), privacy: .public)")
                        if failure?.asked == true { mayAsk = false }
                    }
                }
                if let failure, failure.asked || (failure.needsPrompt && !mayAsk) {
                    log.notice("reconnecting stopped: authentication needs the user. Run `SSHFS check` to be asked again, or remount.")
                    self.state.withLock {
                        $0.blocked = ConnectError(errno: failure.errno == ECANCELED ? ECANCELED : EAUTH)
                        $0.reconnecting = nil
                    }
                    return nil
                }
                try? await Task.sleep(for: delay)
                // Refused logins: go easy on the server (and its fail2ban).
                delay = min(delay * 2, .seconds(failure?.errno == EAUTH ? 60 : 10))
                attempt += 1
            }
            return nil
        }
        s.reconnecting = task
        return task
    }
}
