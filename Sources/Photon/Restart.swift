import ConfigFile
import Dispatch
import Foundation
#if HTTP3
import HTTP3
#endif
import HTTPCore
import HTTPServer
import NetworkTransport
import Synchronization

/// What a graceful restart (#0144) replaces: the settings the listeners, protocols and limits
/// were made from (the baseline a reload's restart-only keys are compared with), and the TLS
/// identity store the secure listeners read.
final class RunningState: Sendable {
    struct Value: Sendable {
        var settings: ServerSettings
        var identity: TLSIdentityStore?
    }

    let value: Mutex<Value>

    init(settings: ServerSettings, identity: TLSIdentityStore?) {
        value = Mutex(Value(settings: settings, identity: identity))
    }

    var snapshot: Value { value.withLock { $0 } }
}

#if HTTP3
/// The Alt-Svc advertisement in the reloadable chain (#0144): reloads keep it, a restart
/// builds its chain with a new one and commits it once its UDP port is bound.
final class AltSvcSlot: Sendable {
    private let state: Mutex<(current: AltSvc, pending: AltSvc?)>

    init(_ altSvc: AltSvc) {
        state = Mutex((altSvc, nil))
    }

    var current: AltSvc { state.withLock { $0.current } }

    func prepare(_ altSvc: AltSvc) {
        state.withLock { $0.pending = altSvc }
    }

    func commit() {
        state.withLock { state in
            if let pending = state.pending { state.current = pending }
            state.pending = nil
        }
    }
}
#endif

/// The restart the reloader runs, set once the server exists.
final class RestartSlot: Sendable {
    private let body = Mutex<(@Sendable () async -> ConfigReloader.Plan?)?>(nil)

    func set(_ restart: @escaping @Sendable () async -> ConfigReloader.Plan?) {
        body.withLock { $0 = restart }
    }

    func run() async -> ConfigReloader.Plan? {
        guard let restart = body.withLock({ $0 }) else { return nil }
        return await restart()
    }
}

/// The running server's context: how it was started, and what reloads and restarts change.
struct Launch: Sendable {
    let options: ServerMain.Options
    let environment: [String: String]
    let arguments: [String]
    let configPath: String?
    let status: StatusRecorder
    let running: RunningState

    static var name: String { ServerMain.name }

    /// Runs the server until a signal stops it.
    ///
    /// - `build(settings, restart)` makes the chain for a reload (`restart` false) or a
    ///   restart.
    /// - `bound(addresses, names, restart)` runs once the listeners are bound (at startup and
    ///   after each restart), before the `listening` lines.
    func serve<Chain: HTTPHandler>(
        _ settings: ServerSettings, listeners: [ServerListener], protocols: [any ConnectionProtocol],
        handler: ReloadableHandler<Chain>, advertisesHTTP3: Bool,
        build: @escaping @Sendable (ServerSettings, Bool) throws(ConfigFileError) -> Chain,
        bound: @escaping @Sendable ([TransportAddress], [String], Bool) -> Void = { _, _, _ in }
    ) async -> Int32 {
        let name = Self.name
        let restartSlot = RestartSlot()
        // #0142: SIGHUP and the file watcher both reload through it, one at a time; #0144:
        // SIGUSR2 restarts on the same task.
        let reloader = ConfigReloader(plan: settings.watchPlan(configPath: configPath)) { trigger in
            let current = running.snapshot
            return ServerMain.reload(handler, identity: current.identity, startup: current.settings, options: options,
                                     environment: environment, trigger: trigger, status: status) { next throws(ConfigFileError) in
                try build(next, false)
            }.map { $0.watchPlan(configPath: configPath) }
        } restart: {
            await restartSlot.run()
        }
        let server = Server(configuration: settings.serverConfiguration, listeners: listeners,
                            protocols: protocols, components: [reloader], handler: handler)
        restartSlot.set {
            await restart(server, handler: handler, advertisesHTTP3: advertisesHTTP3, build: build, bound: bound)
        }

        // Ignore the default actions first, so a signal is never fatal, then route both to a
        // graceful shutdown (#0003). The sources live until the server stops. A second signal
        // during the drain is harmless (#0005).
        let queue = DispatchQueue(label: "sws.signals")
        let sources = [SIGINT, SIGTERM].map { number -> any DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                printError("\(name): signal \(number), shutting down")
                server.requestShutdown()
            }
            source.resume()
            return source
        }
        // SIGHUP (#0127): asks the reloader, which runs reloads one at a time with the file
        // watcher's (#0142). SIGUSR2 (#0144): a graceful restart, on the reloader's task too.
        // Ignored first, so the default action (terminate) never runs.
        let control = [(SIGHUP, false), (SIGUSR2, true)].map { number, restarts -> any DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                guard case .running = server.lifecycleState else { return }
                if restarts { reloader.requestRestart() } else { reloader.requestReload() }
            }
            source.resume()
            return source
        }
        defer {
            for source in sources + control { source.cancel() }
        }

        do {
            try await withThrowingDiscardingTaskGroup { group in
                group.addTask {
                    let addresses = try await server.waitUntilRunning()
                    let names = server.listenerStatistics.map(\.name)
                    bound(addresses, names, false)
                    status.running(listening: addresses.map { "\($0)" })
                    for (index, address) in addresses.enumerated() {
                        // The cleartext line stays "listening HOST:PORT" (scripts parse it).
                        let suffix = index == 0 || index >= names.count ? "" : " (\(names[index]))"
                        FileHandle.standardOutput.write(Data("listening \(address)\(suffix)\n".utf8))
                    }
                }
                group.addTask { try await server.run() }
            }
        } catch is CancellationError where server.lifecycleState == .stopped {
            // Stopped before it was running; waitUntilRunning reports that as cancellation.
        } catch {
            printError("\(name): cannot serve on \(settings.host):\(ServerMain.ports(settings)): \(ServerMain.describe(error))")
            return 1
        }
        status.stopped()
        printError("\(name): stopped")
        return 0
    }

    /// SIGUSR2 or `photon restart` (#0144): reads, validates and builds the whole
    /// configuration (same file and command-line overrides), binds new listeners beside the
    /// running ones (`SO_REUSEPORT` for BSD sockets; Network.framework TLS and QUIC listeners
    /// whose address, identity and ALPN stay the same are handed over), starts accepting on
    /// them, then drains the old ones. If anything fails nothing changes, and the running
    /// server keeps serving. The outcome goes to stderr and the status file.
    ///
    /// A port of 0 that was 0 before keeps the port the listener is bound to. Returns the
    /// watch plan of the configuration now running, or `nil` when it did not change.
    func restart<Chain: HTTPHandler>(
        _ server: Server<ServerListener, ReloadableHandler<Chain>>, handler: ReloadableHandler<Chain>,
        advertisesHTTP3: Bool,
        build: (ServerSettings, Bool) throws(ConfigFileError) -> Chain,
        bound: ([TransportAddress], [String], Bool) -> Void
    ) async -> ConfigReloader.Plan? {
        let name = Self.name
        printError("\(name): signal \(SIGUSR2), restarting")
        let current = running.snapshot
        do {
            let (next, sha256) = try ServerMain.loadSettings(options, environment: environment)
            try next.validate()
            let configuration = next.serverConfiguration
            do {
                try configuration.validate()
            } catch {
                throw ConfigFileError("\(error)")
            }
            let protocols = try ServerProtocols.make(next)
            // One identity store for every secure listener, handed over or new; the file is
            // read now, so a missing or bad file fails the restart before anything changes.
            var store = current.identity
            var identity: TLSIdentity?
            if next.tls != nil, let loaded = try ServerMain.loadIdentity(next, environment: environment) {
                if store == nil { store = TLSIdentityStore(loaded) } else { identity = loaded }
            }
            let chain = try build(next, true)
            let listening = Self.keepingBoundPorts(next, baseline: current.settings, bound: server.listenerStatistics)
            let listeners = try ServerMain.makeListeners(listening, identity: store)

            let addresses = try await server.restart(configuration: configuration, listeners: listeners,
                                                     protocols: protocols)

            // The new listeners accept; the old ones drain. Now the chain and the identity.
            handler.reopenAccessLogs()
            handler.replace(with: chain)
            if let identity, let store, identity.certificateDER != store.identity.certificateDER {
                store.replace(with: identity)
            }
            running.value.withLock { $0 = RunningState.Value(settings: next, identity: store) }
            let names = server.listenerStatistics.map(\.name)
            bound(addresses, names, true)
            if next.http3 != nil && !advertisesHTTP3 {
                printError("\(name): warning: HTTP/3 is listening but not advertised (Alt-Svc): the server started without \"http3\"; restart the process to advertise it")
            }
            let lines = addresses.enumerated().map { index, address in
                index == 0 || index >= names.count ? "\(address)" : "\(address) (\(names[index]))"
            }
            printError("\(name): restarted; listening \(lines.joined(separator: ", ")); the previous listeners drain for up to \(configuration.drainTimeout.map { "\($0)" } ?? "ever")")
            status.restarted(next: next, sha256: sha256, listening: addresses.map { "\($0)" })
            return next.watchPlan(configPath: configPath)
        } catch {
            let message = ServerMain.describe(error)
            printError("\(name): restart failed, the running server keeps serving: \(message)")
            status.restartFailed(message: message)
            return nil
        }
    }

    /// `next` with each port that is 0, and was 0 in `baseline`, set to the port its listener
    /// is bound to: a restart of a config that says 0 keeps the port it got (#0144).
    static func keepingBoundPorts(_ next: ServerSettings, baseline: ServerSettings, bound: [ListenerStatistics]) -> ServerSettings {
        func port(_ name: String) -> UInt16? {
            bound.first { $0.name == name }?.address?.port
        }
        var settings = next
        if settings.port == 0, baseline.port == 0, let port = port("http") { settings.port = port }
        if var tls = settings.tls, tls.port == 0, baseline.tls?.port == 0, let port = port("https") {
            tls.port = port
            settings.tls = tls
        }
        if var http3 = settings.http3, http3.port == 0, baseline.http3?.port == 0, let port = port("h3") {
            http3.port = port
            settings.http3 = http3
        }
        return settings
    }
}
