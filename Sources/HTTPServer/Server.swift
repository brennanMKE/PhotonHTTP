public import HTTPCore
import Synchronization

/// An HTTP server: listeners, a protocol registry and a handler, driven by a
/// ``ServerLifecycle`` (#0079; replaces the legacy singleton, #0002).
///
/// ```swift
/// let server = Server(configuration: config, listeners: [try TCPListener()], protocols: [HTTP1()]) {
///     AccessLog()
///     if config.compression { Compression() }
///     StaticFiles(root: publicURL)
/// }
/// try await server.run()          // returns after a graceful shutdown
/// ```
///
/// The trailing closure is a ``MiddlewareBuilder``: `Handler` is the chain's nested generic
/// type, so components left out by an `if` are not in it (#0083). `handler: app` is the same
/// as a builder with one element.
///
/// ## Components
///
/// ``ServerComponent``s (background work: log flushing, cache eviction) come from the
/// `components:` parameter and from the builder chain (a middleware that is also a component).
/// They run as child tasks once the listeners are bound and are cancelled after the last
/// connection closes. A component that throws shuts the server down, and `run()` rethrows the
/// error after draining.
///
/// ``ConnectionObserver``s (per-connection state: an access log's buffer and counters) are
/// found the same way; each connection is opened with them before its protocol runs and
/// closed with them after its transport closed (#0090).
///
/// ## Task tree
///
/// `run()` is the root: one child task per component, one per listener, and under each listener
/// one child task per connection, all in discarding task groups (no unstructured tasks, #0029). Cancelling the
/// task that calls `run()` cancels the whole tree.
///
/// ## Connection limit
///
/// At most ``ServerConfiguration/maxConnections`` connections are served at once (#0024). With
/// ``ServerConfiguration/ConnectionLimitPolicy/backpressure`` the accept loop stops pulling from
/// the listener until a connection closes; with ``ServerConfiguration/ConnectionLimitPolicy/refuse``
/// it closes the extra connection at once. Neither starts work for a connection over the limit.
///
/// ## Shutdown
///
/// ``requestShutdown()`` (synchronous, safe from a signal handler) or ``shutdown()`` moves the
/// lifecycle to draining: listeners stop accepting, ``ConnectionContext/shutdown`` triggers on
/// every connection, and the server waits up to ``ServerConfiguration/drainTimeout`` for
/// connections to finish before cancelling them. A shutdown before or during startup is never
/// lost (#0005). Startup failures, such as a port in use, throw out of `run()` (#0004).
///
/// ## Several kinds of listener
///
/// `Server<SomeListener, Handler>` serves listeners of one byte-stream type. A
/// `Server<ServerListener, Handler>` (built from ``ServerListener`` values) serves any mix:
/// cleartext and TLS byte streams through the registry, and QUIC connections through a
/// ``MultiplexedConnectionProtocol`` such as HTTP/3 (#0089). Listeners bind in order; if one
/// fails, those already bound are closed and `run()` throws. Every listener shares the
/// connection limit, the drain and the ``ShutdownSignal``, so a shutdown also sends HTTP/3
/// GOAWAY. ``listenerStatistics`` has per-listener counts.
///
/// ## Graceful restart
///
/// ``restart(configuration:listeners:protocols:)`` replaces the listeners, the protocol
/// registry and the configuration while the server runs, in the same process (#0144). The
/// listeners and their connections form a *generation*: the new generation binds and starts
/// accepting first, then the old one stops accepting and drains up to the new
/// ``ServerConfiguration/drainTimeout`` (its connections see their ``ShutdownSignal``, so
/// HTTP/2 and HTTP/3 send GOAWAY and HTTP/1.1 closes after the response in flight). Listeners
/// marked ``ServerListener/restartable(address:identity:)`` keep their address served with no
/// gap. If a new listener cannot be made or bound, the restart throws and the running
/// generation keeps serving. The handler and the components stay: a handler that swaps its
/// chain (such as ConfigFile's `ReloadableHandler`) gives the new generation a new chain.
/// The old generation's connections go on for a short grace before they are told to drain,
/// so a connection accepted just before the swap gets its first request answered. Each
/// generation has its own connection limit, so while one drains up to twice
/// ``ServerConfiguration/maxConnections`` can be open.
public final class Server<Listener, Handler: HTTPHandler>: Sendable {
    /// The configuration of the listeners serving now: the one given at construction, or the
    /// last ``restart(configuration:listeners:protocols:)``'s.
    public var configuration: ServerConfiguration { currentSpec.configuration }
    /// The byte-stream protocols of the listeners serving now.
    public var protocols: ProtocolRegistry { currentSpec.protocols }
    let initial: GenerationSpec
    let handler: Handler
    /// Background components: the `components:` argument, then those found in the chain.
    let components: [any ServerComponent]
    /// The chain reads ``RequestContext/startTime``, so the runners stamp each request.
    let recordsRequestStartTime: Bool
    /// Elements with per-connection state (an access log): the `components:` that are
    /// observers, then those found in the chain.
    let connectionObservers: ConnectionObservers
    /// Elements that style and record the responses runners write themselves (#0139): the
    /// `components:` that are observers, then those found in the chain.
    let protocolResponseObservers: ProtocolResponseObservers

    /// Triggers when the server starts draining (components see it in ``ServerHandle``).
    /// Connections see their generation's signal, which a shutdown triggers too.
    let shutdownSignal = ShutdownSignal()
    /// Triggers when `run()` is about to return (or the server stopped before it ran).
    let finished = ShutdownSignal()

    struct State {
        var lifecycle = ServerLifecycle()
        /// The generation accepting connections (the last one, once stopped).
        var current: ListenerGeneration?
        /// Generations still serving or draining.
        var live: [ListenerGeneration] = []
        /// Counts of generations that finished.
        var finishedTotals = GenerationTotals()
        var startupError: (any Error)?
        var runError: (any Error)?
        var readyWaiters: [CheckedContinuation<[TransportAddress], any Error>] = []
        var runCalled = false
        var restarting = false
        /// Where a restart sends its new generation to be served; `nil` unless running.
        var inbox: AsyncStream<GenerationInstall>.Continuation?
        var pendingInstalls: [GenerationInstall] = []
        /// A generation's drain deadline passed with connections still open.
        var cancelledAtDeadline = false
    }

    let state = Mutex(State())

    init(
        configuration: ServerConfiguration,
        entries: [ServerListener],
        protocols: [any ConnectionProtocol],
        components: [any ServerComponent],
        handler: Handler
    ) {
        initial = GenerationSpec(configuration: configuration,
                                 protocols: ProtocolRegistry(protocols, sniffTimeout: configuration.sniffTimeout),
                                 entries: entries)
        self.handler = handler
        self.components = components + MiddlewareChainInspector.serverComponents(in: handler)
        self.recordsRequestStartTime = MiddlewareChainInspector.needsRequestStartTime(handler)
        self.connectionObservers = ConnectionObservers(
            components.compactMap { $0 as? any ConnectionObserver }
                + MiddlewareChainInspector.connectionObservers(in: handler))
        self.protocolResponseObservers = ProtocolResponseObservers(
            components.compactMap { $0 as? any ProtocolResponseObserver }
                + MiddlewareChainInspector.protocolResponseObservers(in: handler))
    }

    var currentSpec: GenerationSpec { state.withLock { $0.current?.spec } ?? initial }

    // MARK: Observation

    /// The current lifecycle state.
    public var lifecycleState: ServerLifecycle.State { state.withLock { $0.lifecycle.state } }

    /// Bound addresses of the listeners accepting now (empty until running).
    public var localAddresses: [TransportAddress] { state.withLock { $0.current }?.addresses ?? [] }

    /// Connections currently being served, by every generation.
    public var openConnectionCount: Int { totals().open }

    /// Connections admitted since start.
    public var acceptedConnectionCount: Int { totals().accepted }

    /// Connections closed unserved because of the connection limit (``ServerConfiguration/ConnectionLimitPolicy/refuse``).
    public var refusedConnectionCount: Int { totals().refused }

    /// The most connections open at once in one generation of listeners.
    public var peakConnectionCount: Int { totals().peakOpen }

    /// Per-listener counts of the listeners accepting now, in listener order (#0089). The
    /// connection limit is shared, so the `open` counts add up to ``openConnectionCount``
    /// (except while a restarted generation drains: its connections count there only).
    public var listenerStatistics: [ListenerStatistics] {
        if let current = state.withLock({ $0.current }) { return current.state.withLock { $0.perListener } }
        return initial.entries.map { ListenerStatistics(name: $0.name, kind: $0.kind) }
    }

    private func totals() -> GenerationTotals {
        let (finished, live) = state.withLock { ($0.finishedTotals, $0.live) }
        var totals = finished
        totals.open = 0
        for generation in live { totals.add(generation.state.withLock { $0.totals }) }
        return totals
    }

    /// Suspends until the server is running and returns the bound addresses. Throws the
    /// startup error if startup fails, or `CancellationError` if the server stops first.
    public func waitUntilRunning() async throws -> [TransportAddress] {
        try await withCheckedThrowingContinuation { continuation in
            let immediate = state.withLock { state -> Result<[TransportAddress], any Error>? in
                let addresses = state.current?.addresses ?? []
                switch state.lifecycle.state {
                case .running, .draining: return .success(addresses)
                case .failed: return .failure(state.startupError ?? CancellationError())
                case .stopped: return addresses.isEmpty ? .failure(CancellationError()) : .success(addresses)
                case .idle, .starting:
                    state.readyWaiters.append(continuation)
                    return nil
                }
            }
            if let immediate { continuation.resume(with: immediate) }
        }
    }

    // MARK: Shutdown

    /// Starts a graceful shutdown and returns at once. Synchronous and non-suspending, so a
    /// `DispatchSource` signal handler can call it. Repeated calls are no-ops.
    public func requestShutdown() {
        let deadline = configuration.drainTimeout.map { Deadline.after($0) } ?? .never
        let action = state.withLock { $0.lifecycle.handle(.shutdownRequested(deadline: deadline)) }
        perform(action)
    }

    /// Starts a graceful shutdown and returns when the server has stopped (immediately if it
    /// never ran).
    public func shutdown() async {
        requestShutdown()
        await finished.wait()
    }

    private func perform(_ action: ServerLifecycle.Action) {
        switch action {
        case .finish:
            // Stopped before run(): nothing to tear down.
            failReadyWaiters(CancellationError())
            finished.trigger()
        case .abandonStartup:
            // run() closes the listeners once binding returns.
            shutdownSignal.trigger()
        case .drain(let deadline):
            shutdownSignal.trigger()
            let (inbox, live) = state.withLock { state in
                defer { state.inbox = nil }
                return (state.inbox, state.live)
            }
            inbox?.finish()
            for generation in live { generation.retire(.shutdown, deadline: deadline) }
        case .none, .startListeners, .rejectStart, .acceptConnections, .failStartup, .cancelConnections:
            break
        }
    }

    // MARK: Run

    /// Binds the listeners and serves connections until a shutdown completes.
    ///
    /// Throws when the configuration is invalid, a listener cannot bind, the server already
    /// ran, or a listener fails while running (after draining). Returns normally after a
    /// graceful shutdown, including one requested before `run()` was called.
    public func run() async throws {
        let (action, firstCall) = state.withLock { state in
            defer { state.runCalled = true }
            return (state.lifecycle.handle(.start), !state.runCalled)
        }
        switch action {
        case .startListeners:
            break
        case .rejectStart where firstCall && lifecycleState == .stopped:
            return   // shutdown requested before run (#0005): return at once
        default:
            throw ServerError.alreadyStarted
        }
        defer { finished.trigger() }

        do {
            try initial.validate()
        } catch {
            _ = state.withLock { $0.lifecycle.handle(.listenerFailed) }
            failStartup(error)
            throw error
        }

        var bound: [BoundListener] = []
        var binding: ServerListener.Bound?
        do {
            let registryTokens = initial.protocols.alpnTokens
            for entry in initial.entries {
                if shutdownSignal.isTriggered { break }
                let listener = try entry.storage.resolve(boundAddresses: bound.map(\.address), registryTokens: registryTokens)
                binding = listener
                let address = try await listener.listen()
                binding = nil
                bound.append(BoundListener(listener, entry: entry, address: address,
                                           alpnTokens: entry.storage.alpnTokens ?? registryTokens))
            }
        } catch {
            for listener in bound { await listener.bound.close() }
            await binding?.close()
            let failure = state.withLock { $0.lifecycle.handle(.listenerFailed) }
            if failure == .failStartup {
                failStartup(error)
                throw error
            }
            failReadyWaiters(CancellationError())
            return   // shutdown requested while binding
        }

        let generation = ListenerGeneration(spec: initial, listeners: bound)
        let ready = state.withLock { state -> ServerLifecycle.Action in
            let action = state.lifecycle.handle(.listenerReady)
            if action == .acceptConnections {
                state.current = generation
                state.live = [generation]
            }
            return action
        }
        guard ready == .acceptConnections else {
            for listener in bound { await listener.bound.close() }
            failReadyWaiters(CancellationError())
            return   // shutdown requested while binding
        }
        let waiters = state.withLock { state in
            defer { state.readyWaiters = [] }
            return state.readyWaiters
        }
        for waiter in waiters { waiter.resume(returning: generation.addresses) }

        await serve(generation)

        if let error = state.withLock({ $0.runError }) { throw error }
    }

    private func failStartup(_ error: any Error) {
        state.withLock { $0.startupError = error }
        failReadyWaiters(error)
    }

    private func failReadyWaiters(_ error: any Error) {
        let waiters = state.withLock { state in
            defer { state.readyWaiters = [] }
            return state.readyWaiters
        }
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    /// The running phase: the components, and the generations of listeners.
    private func serve(_ first: ListenerGeneration) async {
        guard !components.isEmpty else { return await serveGenerations(first) }
        let handle = ServerHandle(localAddresses: first.addresses, draining: shutdownSignal) { [weak self] in
            self?.requestShutdown()
        }
        await withDiscardingTaskGroup { group in
            for component in components {
                group.addTask { await self.runComponent(component, handle: handle) }
            }
            await serveGenerations(first)
            // The connections are gone: stop the components (they may flush first).
            group.cancelAll()
        }
    }

    private func runComponent(_ component: any ServerComponent, handle: ServerHandle) async {
        do {
            try await component.run(server: handle)
        } catch is CancellationError {
        } catch {
            failedWhileRunning(error, generation: nil)
        }
    }

    /// Serves the first generation, and each one a restart installs, as child tasks; ends when
    /// every generation has drained. Relayed listeners' pull loops are children too.
    private func serveGenerations(_ first: ListenerGeneration) async {
        // Low rate (one element per restart, and restarts run one at a time).
        let (installs, inbox) = AsyncStream.makeStream(of: GenerationInstall.self, bufferingPolicy: .bufferingOldest(4))
        let open = state.withLock { state -> Bool in
            guard state.lifecycle.isRunning else { return false }
            state.inbox = inbox
            return true
        }
        if !open { inbox.finish() }
        await withDiscardingTaskGroup { group in
            for relay in first.listeners.compactMap(\.relay) {
                group.addTask { await relay.run() }
            }
            group.addTask { await self.serveGeneration(first) }
            for await install in installs {
                state.withLock { $0.pendingInstalls.removeAll { $0 === install } }
                guard install.settle(started: true) else { continue }
                for relay in install.relays {
                    group.addTask { await relay.run() }
                }
                group.addTask { await self.serveGeneration(install.generation) }
            }
            // Draining (the inbox finished), or run() was cancelled.
            let leftovers = state.withLock { state in
                state.inbox = nil
                defer { state.pendingInstalls = [] }
                return state.pendingInstalls
            }
            for install in leftovers { _ = install.settle(started: false) }
            if !shutdownSignal.isTriggered {
                // run() was cancelled: stop with no grace period.
                let action = state.withLock { $0.lifecycle.handle(.shutdownRequested(deadline: Deadline(.now))) }
                perform(action)
            }
        }
        let event: ServerLifecycle.Event = state.withLock { $0.cancelledAtDeadline } ? .drainDeadlineReached : .lastConnectionClosed
        _ = state.withLock { $0.lifecycle.handle(event) }
    }

    /// One generation: an accept loop per listener until the generation retires (a restart
    /// replaced it, or the server drains), then its listeners close (or pass to the next
    /// generation) and its connections drain until its deadline, when the rest are cancelled.
    private func serveGeneration(_ generation: ListenerGeneration) async {
        var cancelled = false
        await withDiscardingTaskGroup { group in
            for (index, listener) in generation.listeners.enumerated() {
                switch listener.bound {
                case .byteStream(let listener):
                    group.addTask { await self.acceptByteStreams(listener, generation: generation, index: index) }
                case .multiplexed(let listener, let proto):
                    group.addTask { await self.acceptMultiplexed(listener, protocol: proto, generation: generation, index: index) }
                }
            }

            await generation.stopAccepting.wait()
            if !generation.stopAccepting.isTriggered {
                // Cancelled: stop with no grace period.
                generation.retire(.shutdown, deadline: Deadline(.now))
            }

            let (retirement, kept) = generation.state.withLock { ($0.retirement, $0.handedOver.union($0.closedEarly)) }
            var sharing: [any PortSharingListener] = []
            for (index, listener) in generation.listeners.enumerated() where !kept.contains(index) {
                if retirement == .restart, let shared = listener.sharing {
                    sharing.append(shared)
                } else {
                    await listener.bound.close()
                }
            }
            if retirement == .restart {
                // Replaced by a restart. A sharing listener (its replacement now gets every new
                // connection) stays open for half the grace, so handshakes that reached it just
                // before the swap complete, then serves its queue and closes. The connections
                // go on for the whole grace, so one accepted moments ago gets its first request
                // in before it is told to drain (HTTP/1.1 closes a connection that is between
                // requests at once). A shutdown cuts both waits short.
                let grace = generation.state.withLock { $0.grace }
                if !sharing.isEmpty {
                    _ = await waitForAny([generation.shutdown], until: .after(grace / 2))
                    for listener in sharing { await listener.closeAfterPending() }
                }
                if !generation.shutdown.isTriggered {
                    _ = await waitForAny([generation.drained, generation.shutdown],
                                         until: .after(sharing.isEmpty ? grace : grace / 2))
                    generation.shutdown.trigger()
                }
            }
            generation.checkDrained()

            let deadline = generation.state.withLock { $0.drainDeadline } ?? .never
            if !(await waitForAny([generation.drained], until: deadline)) {
                cancelled = true
                group.cancelAll()
            }
        }
        state.withLock { state in
            state.live.removeAll { $0 === generation }
            var totals = generation.state.withLock { $0.totals }
            totals.open = 0
            state.finishedTotals.add(totals)
            if cancelled { state.cancelledAtDeadline = true }
        }
    }

    /// Waits until one of `signals` triggers (true) or `deadline` passes (false).
    private func waitForAny(_ signals: [ShutdownSignal], until deadline: Deadline) async -> Bool {
        if signals.contains(where: \.isTriggered) { return true }
        return await withTaskGroup(of: Bool.self) { race in
            for signal in signals {
                race.addTask {
                    await signal.wait()
                    return signal.isTriggered
                }
            }
            if let instant = deadline.instant {
                race.addTask {
                    try? await Task.sleep(until: instant, clock: .continuous)
                    return false
                }
            }
            let first = await race.next() ?? false
            race.cancelAll()
            return first || signals.contains(where: \.isTriggered)
        }
    }

    // MARK: Restart

    /// Replaces the listeners, protocols and configuration while running, with no gap in
    /// service (#0144). See "Graceful restart" above.
    ///
    /// 1. The new listeners are made and bound, in order. A new listener whose
    ///    ``ServerListener/restartAddress`` is the address of a running one of the same kind
    ///    binds beside it when both are ``PortSharingListener``s (`SO_REUSEPORT`), takes the
    ///    running one over when it cannot share (Network.framework) and has the same
    ///    ``ServerListener/restartIdentity`` and ALPN tokens, or else binds after the running
    ///    one closes (a brief gap, done after every other listener bound).
    /// 2. The new generation starts accepting.
    /// 3. The old generation stops accepting (a sharing listener first serves the connections
    ///    queued on it). After `grace` its connections see their ``ShutdownSignal`` and drain,
    ///    up to `configuration`'s ``ServerConfiguration/drainTimeout`` from the restart.
    ///
    /// If a listener cannot be made or bound, the listeners made for the restart close, the
    /// running generation keeps serving, and this throws ``ServerRestartError``. (A running
    /// listener closed to free its address for a replacement that then failed stays closed;
    /// the error names it.) Restarts run one at a time; another one throws
    /// ``ServerError/restartInProgress``.
    ///
    /// The `listeners` must make new listeners (the `make` forms, or new instances): a
    /// listener that is already bound cannot be bound again.
    ///
    /// - Parameters:
    ///   - configuration: the new configuration; `nil` keeps the current one.
    ///   - listeners: the new generation's listeners, in bind order (at least one).
    ///   - protocols: the new byte-stream protocols; `nil` keeps the current registry.
    ///   - grace: how long the old generation's connections go on before they are told to
    ///     drain (capped by the drain timeout), so that a connection accepted just before the
    ///     swap gets its first request served rather than closed unanswered.
    /// - Returns: the new generation's bound addresses, in listener order.
    @discardableResult
    public func restart(
        configuration: ServerConfiguration? = nil,
        listeners entries: [ServerListener],
        protocols: [any ConnectionProtocol]? = nil,
        grace: Duration = .seconds(1)
    ) async throws -> [TransportAddress] {
        let old = try state.withLock { state throws(ServerError) -> ListenerGeneration in
            guard state.lifecycle.isRunning, let current = state.current else { throw .notRunning }
            guard !state.restarting else { throw .restartInProgress }
            state.restarting = true
            return current
        }
        defer { state.withLock { $0.restarting = false } }

        let configuration = configuration ?? old.spec.configuration
        let registry = protocols.map { ProtocolRegistry($0, sniffTimeout: configuration.sniffTimeout) } ?? old.spec.protocols
        let spec = GenerationSpec(configuration: configuration, protocols: registry, entries: entries)
        try spec.validate()
        guard !entries.isEmpty else { throw ServerError.invalidConfiguration("a restart needs at least one listener") }

        var claimed = Set<Int>()
        var plans: [RestartPlan] = entries.map { entry in
            guard let address = entry.restartAddress,
                  let index = old.listeners.indices.first(where: {
                      !claimed.contains($0) && old.listeners[$0].kind == entry.kind && old.listeners[$0].address == address
                  }) else { return .fresh }
            claimed.insert(index)
            let running = old.listeners[index]
            if running.sharing != nil { return .alongside(index) }
            if running.relay != nil, running.identity == entry.restartIdentity,
               running.alpnTokens == (entry.storage.alpnTokens ?? registry.alpnTokens) {
                return .handOver(index)
            }
            return .replace(index)
        }

        old.state.withLock { $0.restartPending = true }
        var made: [ServerListener.Bound] = []
        var results: [BoundListener?] = Array(repeating: nil, count: entries.count)
        var madeByEntry: [Int: ServerListener.Bound] = [:]
        var shared: [any PortSharingListener] = []
        do {
            for (index, entry) in entries.enumerated() {
                let tokens = entry.storage.alpnTokens ?? registry.alpnTokens
                if case .handOver(let runningIndex) = plans[index] {
                    let running = old.listeners[runningIndex]
                    var bound = running.bound
                    if case .multiplexed(let listener, _) = bound, let proto = entry.storage.multiplexedProtocol {
                        bound = .multiplexed(listener, proto)
                    }
                    results[index] = BoundListener(name: entry.name, kind: entry.kind, bound: bound, address: running.address,
                                                   identity: entry.restartIdentity, alpnTokens: tokens,
                                                   relay: running.relay, sharing: nil)
                    continue
                }
                let before = (0..<index).compactMap { results[$0]?.address ?? entries[$0].restartAddress }
                let listener: ServerListener.Bound
                do {
                    listener = try entry.storage.resolve(boundAddresses: before, registryTokens: registry.alpnTokens)
                } catch {
                    throw ServerRestartError(listener: entry.name, address: entry.restartAddress, underlying: error)
                }
                made.append(listener)
                madeByEntry[index] = listener
                if case .alongside(let runningIndex) = plans[index] {
                    if let sharing = listener.portSharing, let running = old.listeners[runningIndex].sharing {
                        running.setPortSharing(true)
                        sharing.setPortSharing(true)
                        shared += [running, sharing]
                    } else {
                        plans[index] = .replace(runningIndex)
                    }
                }
                if case .replace = plans[index] { continue }   // bound after the others
                let address: TransportAddress
                do {
                    address = try await listener.listen()
                } catch {
                    throw ServerRestartError(listener: entry.name, address: entry.restartAddress, underlying: error)
                }
                results[index] = BoundListener(listener, entry: entry, address: address, alpnTokens: tokens)
            }
            // Listeners that could not share their address: the running one closes first.
            for (index, entry) in entries.enumerated() {
                guard case .replace(let runningIndex) = plans[index], let listener = madeByEntry[index] else { continue }
                let running = old.listeners[runningIndex]
                old.state.withLock { _ = $0.closedEarly.insert(runningIndex) }
                await running.bound.close()
                let address: TransportAddress
                do {
                    address = try await listener.listen()
                } catch {
                    throw ServerRestartError(listener: entry.name, address: entry.restartAddress, underlying: error,
                                             closedRunningListener: running.name)
                }
                results[index] = BoundListener(listener, entry: entry, address: address,
                                               alpnTokens: entry.storage.alpnTokens ?? registry.alpnTokens)
            }
        } catch {
            for listener in shared { listener.setPortSharing(false) }
            for listener in made { await listener.close() }
            abandonRestart(old)
            throw error
        }
        for listener in shared { listener.setPortSharing(false) }

        // Hand over: the old generation's accept loops on these listeners end (without closing
        // them) before the new generation's start.
        let generation = ListenerGeneration(spec: spec, listeners: results.map { $0! })
        var relays: [any ListenerRelay] = []
        for (index, plan) in plans.enumerated() {
            if case .handOver(let runningIndex) = plan {
                old.state.withLock { _ = $0.handedOver.insert(runningIndex) }
                old.listeners[runningIndex].relay?.detach()
            } else if let relay = generation.listeners[index].relay {
                relays.append(relay)
            }
        }
        let install = GenerationInstall(generation: generation, relays: relays)
        let sent = state.withLock { state -> Bool in
            guard state.lifecycle.isRunning, let inbox = state.inbox,
                  case .enqueued = inbox.yield(install) else { return false }
            state.pendingInstalls.append(install)
            state.current = generation
            state.live.append(generation)
            return true
        }
        if sent { await install.done.wait() }
        guard install.settle(started: false) else {
            // The server stopped meanwhile: nothing serves the new listeners.
            state.withLock { $0.live.removeAll { $0 === generation } }
            for listener in generation.listeners { await listener.bound.close() }
            throw ServerError.notRunning
        }

        old.retire(.restart, deadline: configuration.drainTimeout.map { Deadline.after($0) } ?? .never,
                   grace: configuration.drainTimeout.map { min(grace, $0) } ?? grace)
        return generation.addresses
    }

    /// A failed restart: the old generation goes on, and stops the server if none of its
    /// listeners is left.
    private func abandonRestart(_ old: ListenerGeneration) {
        let stop = old.state.withLock { state in
            state.restartPending = false
            return state.activeAcceptLoops == 0 && state.retirement == nil
        }
        if stop { requestShutdown() }
    }

    // MARK: Accept

    private func acceptByteStreams<L: TransportListener>(_ listener: L, generation: ListenerGeneration, index: Int) async {
        await acceptLoop(listener.connections, generation: generation, index: index,
                         refuse: { transport in await transport.close(.shutdown) },
                         serve: { transport in await self.serveConnection(transport, generation: generation) })
    }

    private func acceptMultiplexed<L: MultiplexedTransportListener, P: MultiplexedConnectionProtocol>(
        _ listener: L, protocol proto: P, generation: ListenerGeneration, index: Int
    ) async {
        await acceptLoop(listener.connections, generation: generation, index: index,
                         refuse: { connection in await listener.refuse(connection) },
                         serve: { connection in
                             var context = ConnectionContext(info: listener.connectionInfo(connection),
                                                             shutdown: generation.shutdown,
                                                             recordsRequestStartTime: self.recordsRequestStartTime,
                                                             protocolResponseObservers: self.protocolResponseObservers)
                             let observers = self.connectionObservers
                             if !observers.isEmpty { observers.connectionWillStart(&context) }
                             await proto.run(connection, handler: self.handler, context: context)
                             if !observers.isEmpty { observers.connectionDidEnd(context) }
                         })
    }

    /// Takes connections from one listener and serves each in a child task, within the
    /// generation's connection limit.
    private func acceptLoop<Connections: AsyncSequence>(
        _ sequence: Connections, generation: ListenerGeneration, index: Int,
        refuse: @escaping @Sendable (Connections.Element) async -> Void,
        serve: @escaping @Sendable (Connections.Element) async -> Void
    ) async where Connections.Element: Sendable, Connections.Failure == any Error {
        let limits = generation.spec.configuration
        await withDiscardingTaskGroup { connections in
            var iterator = sequence.makeAsyncIterator()
            accepting: while true {
                let reserved: Bool
                switch limits.connectionLimitPolicy {
                case .backpressure:
                    // Stop pulling from the listener while at the limit (accept backpressure).
                    guard await reserveCapacity(generation) else { break accepting }
                    reserved = true
                case .refuse:
                    reserved = false
                }

                let next: Connections.Element?
                do {
                    next = try await iterator.next()
                } catch {
                    if reserved { releaseSlot(generation, reservation: true) }
                    if !(error is CancellationError) { failedWhileRunning(error, generation: generation) }
                    break accepting
                }
                guard let connection = next else {
                    if reserved { releaseSlot(generation, reservation: true) }
                    break accepting
                }

                let admitted = generation.state.withLock { state -> Bool in
                    guard state.admitting else { return false }
                    if reserved {
                        state.reserved -= 1
                    } else {
                        guard state.open < limits.maxConnections else {
                            state.totals.refused += 1
                            state.perListener[index].refused += 1
                            return false
                        }
                        state.open += 1
                    }
                    state.totals.accepted += 1
                    state.perListener[index].accepted += 1
                    state.perListener[index].open += 1
                    state.totals.open = state.open - state.reserved
                    state.totals.peakOpen = max(state.totals.peakOpen, state.totals.open)
                    return true
                }
                guard admitted else {
                    if reserved { releaseSlot(generation, reservation: true) }
                    await refuse(connection)
                    continue
                }
                connections.addTask {
                    await serve(connection)
                    self.releaseSlot(generation, listener: index)
                }
            }
        }
        let allEnded = generation.state.withLock { state in
            state.activeAcceptLoops -= 1
            return state.activeAcceptLoops == 0 && state.retirement == nil && !state.restartPending
        }
        // Every listener stopped on its own: nothing more can be served.
        if allEnded { requestShutdown() }
        generation.checkDrained()
    }

    private func serveConnection<T: ByteStreamTransport>(_ transport: T, generation: ListenerGeneration) async {
        var context = ConnectionContext(info: transport.info, shutdown: generation.shutdown,
                                        recordsRequestStartTime: recordsRequestStartTime,
                                        protocolResponseObservers: protocolResponseObservers)
        if !connectionObservers.isEmpty { connectionObservers.connectionWillStart(&context) }
        await generation.spec.protocols.serve(transport, handler: handler, context: context)
        await transport.close(.normal)
        if !connectionObservers.isEmpty { connectionObservers.connectionDidEnd(context) }
    }

    /// A listener or component failed while running: remember the first error, then shut down.
    /// A generation that is retiring is past caring.
    private func failedWhileRunning(_ error: any Error, generation: ListenerGeneration?) {
        if let generation, generation.state.withLock({ $0.retirement != nil || $0.restartPending }) { return }
        state.withLock { state in
            if state.runError == nil { state.runError = error }
        }
        requestShutdown()
    }

    // MARK: Capacity

    /// Reserves a connection slot, waiting while ``ServerConfiguration/maxConnections`` are
    /// open in `generation`. Returns false when it stops admitting or the task is cancelled.
    private func reserveCapacity(_ generation: ListenerGeneration) async -> Bool {
        let limit = generation.spec.configuration.maxConnections
        let id = generation.state.withLock { state -> UInt64 in
            defer { state.nextWaiterID &+= 1 }
            return state.nextWaiterID
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let immediate = generation.state.withLock { state -> Bool? in
                    guard state.admitting, !Task.isCancelled else { return false }
                    if state.open < limit {
                        state.open += 1
                        state.reserved += 1
                        return true
                    }
                    state.capacityWaiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let waiter = generation.state.withLock { $0.capacityWaiters.removeValue(forKey: id) }
            waiter?.resume(returning: false)
        }
    }

    /// Frees a slot (a connection closed, or a reservation went unused) and hands it to a
    /// waiting accept loop as a reservation.
    private func releaseSlot(_ generation: ListenerGeneration, reservation: Bool = false, listener index: Int? = nil) {
        let waiter = generation.state.withLock { state -> CheckedContinuation<Bool, Never>? in
            state.open -= 1
            if reservation { state.reserved -= 1 }
            if let index { state.perListener[index].open -= 1 }
            state.totals.open = state.open - state.reserved
            guard state.admitting, let id = state.capacityWaiters.keys.first else { return nil }
            state.open += 1
            state.reserved += 1
            return state.capacityWaiters.removeValue(forKey: id)
        }
        waiter?.resume(returning: true)
        generation.checkDrained()
    }
}

// MARK: - Generations

/// How a restart's new listener gets its address (#0144); the index is the running listener's.
enum RestartPlan {
    /// Binds an address no running listener has.
    case fresh
    /// Binds beside a running listener that shares its port.
    case alongside(Int)
    /// Takes over a running listener that cannot share its port.
    case handOver(Int)
    /// Binds after the running listener on its address closes.
    case replace(Int)
}

/// What a generation of listeners is built from.
struct GenerationSpec: Sendable {
    let configuration: ServerConfiguration
    let protocols: ProtocolRegistry
    let entries: [ServerListener]

    func validate() throws {
        try configuration.validate()
        let needsRegistry = entries.contains { $0.kind == .byteStream }
        guard !needsRegistry || !protocols.protocols.isEmpty else { throw ServerError.noProtocols }
    }
}

/// Connection counts of one generation, or summed.
struct GenerationTotals: Sendable {
    var open = 0
    var accepted = 0
    var refused = 0
    var peakOpen = 0

    mutating func add(_ other: GenerationTotals) {
        open += other.open
        accepted += other.accepted
        refused += other.refused
        peakOpen = max(peakOpen, other.peakOpen)
    }
}

/// A bound listener of a generation.
struct BoundListener: Sendable {
    let name: String
    let kind: ServerListener.Kind
    /// What the accept loop takes connections from (a relay for a handed-over listener).
    let bound: ServerListener.Bound
    let address: TransportAddress
    let identity: String?
    let alpnTokens: [String]
    /// Set when the listener is relayed so it can be handed over (#0144).
    let relay: (any ListenerRelay)?
    /// Set when the listener can share its port with a replacement.
    let sharing: (any PortSharingListener)?

    init(name: String, kind: ServerListener.Kind, bound: ServerListener.Bound, address: TransportAddress,
         identity: String?, alpnTokens: [String], relay: (any ListenerRelay)?, sharing: (any PortSharingListener)?) {
        self.name = name
        self.kind = kind
        self.bound = bound
        self.address = address
        self.identity = identity
        self.alpnTokens = alpnTokens
        self.relay = relay
        self.sharing = sharing
    }

    /// A listener just bound for `entry`: relayed when the entry is restartable and the
    /// listener cannot share its port.
    init(_ listener: ServerListener.Bound, entry: ServerListener, address: TransportAddress, alpnTokens: [String]) {
        var bound = listener
        var relay: (any ListenerRelay)?
        let sharing = listener.portSharing
        if sharing == nil, entry.restartIdentity != nil {
            switch listener {
            case .byteStream(let base):
                let relayed = Self.relayed(base)
                bound = .byteStream(relayed.0)
                relay = relayed.1
            case .multiplexed(let base, let proto):
                let relayed = Self.relayedMultiplexed(base)
                bound = .multiplexed(relayed.0, proto)
                relay = relayed.1
            }
        }
        self.init(name: entry.name, kind: entry.kind, bound: bound, address: address, identity: entry.restartIdentity,
                  alpnTokens: alpnTokens, relay: relay, sharing: sharing)
    }

    private static func relayed<L: TransportListener>(_ base: L) -> (any TransportListener, any ListenerRelay) {
        let relayed = RelayedListener(base)
        return (relayed, relayed)
    }

    private static func relayedMultiplexed<L: MultiplexedTransportListener>(_ base: L) -> (any MultiplexedTransportListener, any ListenerRelay) {
        let relayed = RelayedMultiplexedListener(base)
        return (relayed, relayed)
    }
}

extension ServerListener.Bound {
    /// The listener as a ``PortSharingListener``, when it is one.
    var portSharing: (any PortSharingListener)? {
        switch self {
        case .byteStream(let listener): listener as? any PortSharingListener
        case .multiplexed(let listener, _): listener as? any PortSharingListener
        }
    }
}

/// The listeners serving under one configuration and registry, with their connections: the
/// first from `run()`, then one per restart (#0144).
final class ListenerGeneration: Sendable {
    enum Retirement: Sendable {
        /// A restart replaced it: sharing listeners serve their queue first.
        case restart
        /// The server drains: stop admitting.
        case shutdown
    }

    struct State {
        /// Connection slots in use: connections being served plus ``reserved``.
        var open = 0
        /// Slots reserved by accept loops waiting on the listener (backpressure).
        var reserved = 0
        var activeAcceptLoops = 0
        var nextWaiterID: UInt64 = 0
        var capacityWaiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
        var perListener: [ListenerStatistics]
        var totals = GenerationTotals()
        /// False once the server drains: new connections are refused.
        var admitting = true
        var retirement: Retirement?
        /// A restart is binding the next generation: accept loops that end are expected.
        var restartPending = false
        var drainDeadline: Deadline?
        /// After a restart: how long connections go on before ``ListenerGeneration/shutdown``.
        var grace: Duration = .zero
        /// Listeners handed to the next generation: not closed by this one.
        var handedOver: Set<Int> = []
        /// Listeners a restart closed to free their address.
        var closedEarly: Set<Int> = []
    }

    let spec: GenerationSpec
    let listeners: [BoundListener]
    /// Triggers when it retires: the listeners close (or pass to the next generation).
    let stopAccepting = ShutdownSignal()
    /// Handed to every connection of the generation: triggers when it retires (after the
    /// grace, for a restart).
    let shutdown = ShutdownSignal()
    /// Triggers once retired, with every accept loop ended and no connection open.
    let drained = ShutdownSignal()
    let state: Mutex<State>

    init(spec: GenerationSpec, listeners: [BoundListener]) {
        self.spec = spec
        self.listeners = listeners
        // Counted from the start, so a restart before the accept loops run sees them.
        state = Mutex(State(activeAcceptLoops: listeners.count, perListener: listeners.map {
            ListenerStatistics(name: $0.name, kind: $0.kind, address: $0.address)
        }))
    }

    var addresses: [TransportAddress] { listeners.map(\.address) }

    /// Stops accepting and starts the drain, until `deadline` (the earlier one if called
    /// again). A shutdown tells the connections at once; a restart after `grace`.
    func retire(_ retirement: Retirement, deadline: Deadline, grace: Duration = .zero) {
        let waiters = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
            if state.retirement != .shutdown { state.retirement = retirement }
            state.drainDeadline = state.drainDeadline.map { $0.earliest(deadline) } ?? deadline
            state.grace = grace
            guard retirement == .shutdown else { return [] }
            state.admitting = false
            defer { state.capacityWaiters = [:] }
            return Array(state.capacityWaiters.values)
        }
        for waiter in waiters { waiter.resume(returning: false) }
        stopAccepting.trigger()
        if retirement == .shutdown { shutdown.trigger() }
        checkDrained()
    }

    /// Triggers ``drained`` once retired with no accept loop and no connection left.
    func checkDrained() {
        let done = state.withLock { $0.retirement != nil && $0.open == 0 && $0.activeAcceptLoops == 0 }
        if done { drained.trigger() }
    }
}

/// A restart's new generation on its way to the serving task group.
final class GenerationInstall: Sendable {
    let generation: ListenerGeneration
    /// Pull loops of listeners relayed for the first time.
    let relays: [any ListenerRelay]
    private let outcome = Mutex<Bool?>(nil)
    /// Triggers once the outcome is settled.
    let done = ShutdownSignal()

    init(generation: ListenerGeneration, relays: [any ListenerRelay]) {
        self.generation = generation
        self.relays = relays
    }

    /// Settles the outcome unless it already is; returns the outcome in effect.
    func settle(started: Bool) -> Bool {
        let result = outcome.withLock { outcome -> Bool in
            if outcome == nil { outcome = started }
            return outcome!
        }
        done.trigger()
        return result
    }
}

// MARK: - Initializers

extension Server where Listener: TransportListener {
    /// - Parameters:
    ///   - configuration: captured once; validated by `run()`.
    ///   - listeners: where connections come from. `run()` binds them.
    ///   - protocols: the protocols connections may speak, in priority order.
    ///   - components: background components to run besides those found in `handler`.
    ///   - handler: answers requests; a builder chain with one element.
    public convenience init(
        configuration: ServerConfiguration = ServerConfiguration(),
        listeners: [Listener],
        protocols: [any ConnectionProtocol],
        components: [any ServerComponent] = [],
        handler: Handler
    ) {
        self.init(configuration: configuration, entries: listeners.map { .byteStream($0) },
                  protocols: protocols, components: components, handler: handler)
    }

    /// - Parameters:
    ///   - configuration: captured once; validated by `run()`.
    ///   - listeners: where connections come from. `run()` binds them.
    ///   - protocols: the protocols connections may speak, in priority order.
    ///   - components: background components to run besides those found in the chain.
    ///   - chain: the middlewares, in the order they see requests, optionally ending in a
    ///     handler (``NotFoundHandler`` otherwise). See ``MiddlewareBuilder``.
    public convenience init(
        configuration: ServerConfiguration = ServerConfiguration(),
        listeners: [Listener],
        protocols: [any ConnectionProtocol],
        components: [any ServerComponent] = [],
        @MiddlewareBuilder _ chain: () -> Handler
    ) {
        self.init(configuration: configuration, listeners: listeners, protocols: protocols,
                  components: components, handler: chain())
    }
}

extension Server where Listener == ServerListener {
    /// A server over several kinds of listener (#0089). See ``ServerListener``.
    ///
    /// - Parameters:
    ///   - configuration: captured once; validated by `run()`.
    ///   - listeners: where connections come from, bound in order by `run()`.
    ///   - protocols: the byte-stream protocols, in priority order. Multiplexed listeners
    ///     name their own protocol, so this may be empty when every listener is multiplexed.
    ///   - components: background components to run besides those found in `handler`.
    ///   - handler: answers requests from every listener.
    public convenience init(
        configuration: ServerConfiguration = ServerConfiguration(),
        listeners: [ServerListener],
        protocols: [any ConnectionProtocol],
        components: [any ServerComponent] = [],
        handler: Handler
    ) {
        self.init(configuration: configuration, entries: listeners,
                  protocols: protocols, components: components, handler: handler)
    }

    /// A server over several kinds of listener, with a middleware chain (#0089).
    public convenience init(
        configuration: ServerConfiguration = ServerConfiguration(),
        listeners: [ServerListener],
        protocols: [any ConnectionProtocol],
        components: [any ServerComponent] = [],
        @MiddlewareBuilder _ chain: () -> Handler
    ) {
        self.init(configuration: configuration, listeners: listeners, protocols: protocols,
                  components: components, handler: chain())
    }
}
