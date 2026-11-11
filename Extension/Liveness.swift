import Foundation
import Network
import notify
import Synchronization

/// Notices events after which the SSH connection is probably dead -- network
/// changes, system sleep -- and asks `Remote` to check it right away, instead
/// of waiting for ssh's keepalive (ServerAliveInterval × CountMax ≈ 15 s) or a
/// user's operation to time out.
///
/// Also listens for the Darwin notification `com.joelmsmith.sshfs.check`
/// (`notifyutil -p com.joelmsmith.sshfs.check`) to trigger a check by hand.
final class Liveness: @unchecked Sendable {
    static let checkNotification = "com.joelmsmith.sshfs.check"

    private let remote: Remote
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "sshfs.liveness")
    private var lastPath: String?
    private var sleepWatcher: Task<Void, Never>?
    private var notifyToken: Int32 = NOTIFY_TOKEN_INVALID

    init(remote: Remote) { self.remote = remote }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
        monitor.start(queue: queue)

        // ContinuousClock keeps counting during sleep, SuspendingClock
        // doesn't; a gap between them means the machine slept.
        sleepWatcher = Task { [weak self] in
            var lastC = ContinuousClock.now, lastS = SuspendingClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2), clock: .suspending)
                let c = ContinuousClock.now, s = SuspendingClock.now
                let slept = (c - lastC) - (s - lastS)
                lastC = c; lastS = s
                if slept > .seconds(5) {
                    log.notice("system slept for ~\(slept.components.seconds) s; checking connection")
                    await self?.remote.healthCheck(reason: "wake")
                }
            }
        }

        notify_register_dispatch(Self.checkNotification, &notifyToken, queue) { [weak self] _ in
            guard let self else { return }
            Task { await self.remote.userCheck() }
        }
    }

    func stop() {
        monitor.cancel()
        sleepWatcher?.cancel()
        if notifyToken != NOTIFY_TOKEN_INVALID { notify_cancel(notifyToken) }
    }

    /// Called on `queue`. Only a change of usable interfaces counts; the
    /// first callback just records the starting state.
    private func pathChanged(_ path: NWPath) {
        let summary = path.status == .satisfied
            ? path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            : "unsatisfied"
        defer { lastPath = summary }
        guard let last = lastPath, last != summary else { return }
        log.notice("network changed (\(last, privacy: .public) -> \(summary, privacy: .public)); checking connection")
        guard path.status == .satisfied else { return }
        // Give routes a moment to settle before probing.
        Task { [remote] in
            try? await Task.sleep(for: .seconds(1))
            await remote.healthCheck(reason: "network change")
        }
    }
}
