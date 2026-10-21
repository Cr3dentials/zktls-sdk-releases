import Foundation
import Network
import UIKit

/// The slice of `UIApplication` the lifecycle uses. UIApplication conforms as
/// is; the package tests, which have no UIApplication, pass a stand-in.
public protocol BackgroundTaskHost: AnyObject {
    var backgroundTimeRemaining: TimeInterval { get }
    func beginBackgroundTask(withName taskName: String?, expirationHandler handler: (@MainActor @Sendable () -> Void)?) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

extension UIApplication: BackgroundTaskHost {}

/// Owns the OS-facing half of one zkTLS session on iOS.
///
/// `beginBackgroundTask` asks UIKit to keep the process alive after the user
/// leaves the app. The ceiling is roughly 25-30 s, which comfortably covers the
/// 1-2 s capture-and-prove window but is never a guarantee. The expiry handler
/// is the contract: it is the last point at which we can cancel cleanly and
/// zero the witness. `BGContinuedProcessingTask` (iOS 26) is deliberately not
/// used, and VoIP/PushKit entitlements are off limits.
public final class ZkTlsLifecycle {
    /// The underlying Rust state machine this lifecycle drives.
    public let handle: LifecycleHandle
    /// Called when the background time runs out and the session has failed, so
    /// the caller can cancel its in-flight work.
    public var onExpiry: (() -> Void)?

    private let host: BackgroundTaskHost
    private let lock = NSLock()
    private var taskId: UIBackgroundTaskIdentifier = .invalid
    private var monitor: NWPathMonitor?
    private var currentPath: String?

    /// A lifecycle for `host`'s background task API, driving `handle`: the client's
    /// `lifecycleHandle`, the machine its verbs drive.
    public init(host: BackgroundTaskHost, handle: LifecycleHandle) {
        self.host = host
        self.handle = handle
    }

    deinit {
        end()
    }

    /// Whether `begin()` has taken the background assertion and not yet been `end()`ed.
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return taskId != .invalid
    }

    /// Seconds UIKit says are left, for the per-OS-version ceiling measurement.
    /// Zero in the foreground, where UIKit reports a huge sentinel instead.
    public var backgroundCeilingSeconds: Double {
        let remaining = host.backgroundTimeRemaining
        return remaining < .greatestFiniteMagnitude ? remaining : 0
    }

    /// Takes the background assertion and starts watching the network path.
    /// Idempotent: one assertion per session.
    public func begin() {
        lock.lock()
        defer { lock.unlock() }
        guard monitor == nil else { return }
        taskId = host.beginBackgroundTask(withName: "ai.zktls.session") { [weak self] in self?.expire() }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(to: Self.networkKey(path)) }
        monitor.start(queue: DispatchQueue(label: "ai.zktls.path"))
        self.monitor = monitor
    }

    /// Idempotent, and safe to race with the expiry handler.
    public func end() {
        lock.lock()
        let id = taskId
        taskId = .invalid
        monitor?.cancel()
        monitor = nil
        lock.unlock()
        if id != .invalid {
            host.endBackgroundTask(id)
        }
    }

    /// UIKit is about to suspend us. A capture in flight is past its limit and
    /// fails; a proof is inside its idle TTL and waits, suspended, to Resume.
    private func expire() {
        if handle.onBackgroundExpiry() == "failed" {
            onExpiry?()
        }
        end()
    }

    /// Reconnect now instead of waiting out a read deadline. The first path the
    /// monitor reports is the baseline, not a change. Every report, the baseline
    /// included, gives the field telemetry its network's kind.
    func pathChanged(to key: String) {
        defer { currentPath = key }
        zktlsNoteNetwork(kind: key)
        guard let current = currentPath, current != key else { return }
        zktlsNotePathChange()
    }

    private static func networkKey(_ path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        return path.status == .satisfied ? "other" : "none"
    }
}
