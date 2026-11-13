#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
public import HTTPCore
import Synchronization

/// What `stat` reports about a file that tells a change apart (#0142): device and inode (an
/// atomic rename puts a new inode at the path), size and modification time.
public struct FileFingerprint: Sendable, Hashable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64

    public init(device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
    }

    /// The file at `path` (symbolic links followed), or `nil` when it does not exist or cannot
    /// be read.
    public static func of(_ path: String) -> FileFingerprint? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        #else
        let modified = info.st_mtim
        #endif
        return FileFingerprint(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino),
                               size: Int64(info.st_size), modifiedSeconds: Int64(modified.tv_sec),
                               modifiedNanoseconds: Int64(modified.tv_nsec))
    }

    /// Every path in `paths`, `nil` for a missing file.
    public static func snapshot(_ paths: [String]) -> [String: FileFingerprint?] {
        var result: [String: FileFingerprint?] = [:]
        for path in paths { result[path] = .some(of(path)) }
        return result
    }
}

/// Runs reloads of the configuration one at a time (#0142), whether `SIGHUP` asked for one
/// (``requestReload()``) or the watcher saw a file change, and stops when the server drains.
///
/// The watcher polls `stat` of the plan's files every ``Plan/interval`` (no file-system event
/// source: it is a child task of ``run(server:)``, so it ends with the server). On a change it
/// waits until two polls `settle` apart agree, so a file still being written is not read, then
/// asks for a reload. A replacement made by renaming a new file over the old one (editors,
/// `tailscale cert`, lego) shows as a new inode.
///
/// The reload itself is the closure given to the initializer: it reads and applies the
/// configuration and returns the plan to watch from then on (the files the running
/// configuration names). It runs on the reloader's task, never on the request path.
///
/// A graceful restart (#0144, ``requestRestart()``) runs on the same task, so reloads and
/// restarts never overlap.
public final class ConfigReloader: ServerComponent, Sendable {
    /// Why a reload runs.
    public enum Trigger: Sendable, Equatable {
        /// `SIGHUP`, or ``requestReload()`` from elsewhere.
        case signal
        /// The watcher saw these files change.
        case watch(changed: [String])

        /// `signal` or `watch`.
        public var name: String {
            switch self {
            case .signal: "signal"
            case .watch: "watch"
            }
        }
    }

    /// What to watch, and how often.
    public struct Plan: Sendable, Equatable {
        /// The config file first, then the files a reload reads.
        public var paths: [String]
        /// Poll at all. When false, only ``ConfigReloader/requestReload()`` reloads.
        public var watch: Bool
        /// Time between polls.
        public var interval: Duration

        public init(paths: [String], watch: Bool = true, interval: Duration = .seconds(2)) {
            self.paths = paths
            self.watch = watch
            self.interval = interval
        }
    }

    /// What the reloader's task runs next.
    enum Request: Sendable {
        case reload(Trigger)
        case restart
    }

    let reload: @Sendable (Trigger) -> Plan?
    let restart: (@Sendable () async -> Plan?)?
    let sleep: @Sendable (Duration) async throws -> Void
    let settle: Duration?
    let plan: Mutex<Plan>
    /// The files as the last reload (or the watcher's last trigger) saw them.
    let baseline: Mutex<[String: FileFingerprint?]>
    let requests: AsyncStream<Request>
    let continuation: AsyncStream<Request>.Continuation

    /// - Parameters:
    ///   - plan: what the running configuration names.
    ///   - clock: for the polls and the settle wait; a test can pass its own.
    ///   - settle: how long files must stay unchanged before a reload; `nil` is
    ///     `min(interval, 0.5 s)`.
    ///   - reload: reads and applies the configuration, returns the plan to use next (`nil`
    ///     keeps the current one, after a reload that failed or was rejected).
    ///   - restart: a graceful restart (#0144), run for ``requestRestart()``; returns the plan
    ///     like `reload`. `nil`: restart requests are ignored.
    public init<C: Clock>(plan: Plan, clock: C = ContinuousClock(), settle: Duration? = nil,
                          reload: @escaping @Sendable (Trigger) -> Plan?,
                          restart: (@Sendable () async -> Plan?)? = nil) where C.Duration == Duration {
        self.reload = reload
        self.restart = restart
        self.sleep = { try await clock.sleep(for: $0) }
        self.settle = settle
        self.plan = Mutex(plan)
        self.baseline = Mutex(FileFingerprint.snapshot(plan.paths))
        // Low-rate signals (docs/ROADMAP.md §5.4); a burst of requests needs only a few reloads.
        (requests, continuation) = AsyncStream.makeStream(of: Request.self, bufferingPolicy: .bufferingNewest(4))
    }

    /// The plan in use.
    public var currentPlan: Plan { plan.withLock { $0 } }

    /// Asks for a reload. Synchronous and non-blocking, so a signal handler can call it; the
    /// reload runs on ``run(server:)``'s task.
    public func requestReload() {
        continuation.yield(.reload(.signal))
    }

    /// Asks for a graceful restart (#0144). Synchronous and non-blocking like
    /// ``requestReload()``; the restart runs on ``run(server:)``'s task, after any reload
    /// before it.
    public func requestRestart() {
        continuation.yield(.restart)
    }

    /// Reloads on request until cancelled, with the watcher beside it. Requests that arrive
    /// once the server is draining are dropped.
    public func run(server: ServerHandle) async throws {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.watch(draining: server.draining) }
            // Ends when the task is cancelled (the server stopped).
            for await request in requests where !server.draining.isTriggered {
                switch request {
                case .reload(let trigger):
                    perform(trigger)
                case .restart:
                    guard let restart else { continue }
                    await apply { await restart() }
                }
            }
            group.cancelAll()
        }
    }

    /// One reload: the files are recorded as it reads them, so the watcher reports only later
    /// changes; files the new plan adds are recorded after it.
    func perform(_ trigger: Trigger) {
        let current = currentPlan
        let before = FileFingerprint.snapshot(current.paths)
        baseline.withLock { $0 = before }
        adopt(reload(trigger) ?? current, before: before)
    }

    /// A restart: like a reload, the files are recorded as it reads them.
    func apply(_ body: () async -> Plan?) async {
        let current = currentPlan
        let before = FileFingerprint.snapshot(current.paths)
        baseline.withLock { $0 = before }
        adopt(await body() ?? current, before: before)
    }

    /// Watches `next` from now on.
    private func adopt(_ next: Plan, before: [String: FileFingerprint?]) {
        plan.withLock { $0 = next }
        let added = next.paths.filter { before[$0] == nil }
        let snapshot = FileFingerprint.snapshot(added)
        baseline.withLock { baseline in
            baseline.merge(snapshot) { _, new in new }
            let watched = Set(next.paths)
            baseline = baseline.filter { watched.contains($0.key) }
        }
    }

    /// Polls until cancelled; yields ``Trigger/watch(changed:)`` for a settled change.
    func watch(draining: ShutdownSignal) async {
        while !Task.isCancelled {
            let interval = currentPlan.interval
            do { try await sleep(interval) } catch { return }
            let plan = currentPlan
            guard plan.watch, !draining.isTriggered else { continue }
            var current = FileFingerprint.snapshot(plan.paths)
            if unchanged(current, plan.paths) { continue }
            // Wait for the writer to finish: two polls `settle` apart must agree.
            let settle = self.settle ?? min(plan.interval, .milliseconds(500))
            while true {
                do { try await sleep(settle) } catch { return }
                let again = FileFingerprint.snapshot(plan.paths)
                if again == current { break }
                current = again
            }
            let changed = baseline.withLock { baseline -> [String] in
                let changed = plan.paths.filter { baseline[$0] != current[$0] }
                for path in plan.paths { baseline[path] = current[path]! }
                return changed
            }
            // Empty when a reload in the meantime already read these files.
            if !changed.isEmpty { continuation.yield(.reload(.watch(changed: changed))) }
        }
    }

    func unchanged(_ current: [String: FileFingerprint?], _ paths: [String]) -> Bool {
        baseline.withLock { baseline in paths.allSatisfy { baseline[$0] == current[$0] } }
    }
}

extension ServerSettings {
    /// What ``ConfigReloader`` watches for these settings: `configPath` (when the settings
    /// came from a file) and ``reloadInputs``, with the `reload` key's interval.
    public func watchPlan(configPath: String?) -> ConfigReloader.Plan {
        ConfigReloader.Plan(paths: (configPath.map { [$0] } ?? []) + reloadInputs,
                            watch: reload.watch, interval: reload.interval)
    }
}
