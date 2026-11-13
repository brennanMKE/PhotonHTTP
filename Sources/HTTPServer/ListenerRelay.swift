public import HTTPCore
import Synchronization

/// What the server needs of a relayed listener (#0144): run its pull loop and hand it to the
/// next generation.
protocol ListenerRelay: Sendable {
    /// Pulls connections from the wrapped listener for whichever accept loop is current, until
    /// the listener ends or the task is cancelled. A child task of the server's task group.
    func run() async
    /// Ends the current accept loop's iteration (its `next()` returns `nil`) without closing
    /// the listener; the next ``TransportListener/connections`` iterator continues with the
    /// connections that follow.
    func detach()
}

/// Carries one listener across generations of a graceful restart (#0144).
///
/// A Network.framework listener cannot share its port, so a restart hands the running listener
/// to the new generation instead of binding another. An accept loop cannot be stopped while it
/// waits in the listener's `next()` without cancelling its task, and cancelling it would cancel
/// the connections it serves. So the relay owns the pull, in its own task: a consumer's
/// `next()` registers demand, the relay pulls one connection for it, and ``detach()`` ends the
/// current consumer with `nil` (an epoch, so a consumer that comes back late ends too).
///
/// Demand-driven like the listener: the relay pulls only while a consumer waits, and holds at
/// most one connection (one that arrived just as its consumer detached; the next consumer gets
/// it). The cost is one hand-off per connection, on Network.framework listeners only (TLS and
/// QUIC, where the handshake costs far more).
final class AcceptRelay<Element: Sendable>: Sendable {
    struct State {
        var epoch: UInt64 = 0
        var consumer: CheckedContinuation<Element?, any Error>?
        var held: Element?
        var demand: CheckedContinuation<Bool, Never>?
        var finished = false
        var failure: (any Error)?
    }

    let state = Mutex(State())
    /// Closes a connection nobody will take (held when the relay finishes).
    let discard: @Sendable (Element) async -> Void

    init(discard: @escaping @Sendable (Element) async -> Void) {
        self.discard = discard
    }

    var epoch: UInt64 { state.withLock { $0.epoch } }

    // MARK: Consumer

    enum Step {
        case value(Element?)
        case failure(any Error)
        case wait(CheckedContinuation<Bool, Never>?)
    }

    func next(epoch: UInt64) async throws -> Element? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Element?, any Error>) in
                let step = state.withLock { state -> Step in
                    if epoch != state.epoch { return .value(nil) }
                    if let held = state.held {
                        state.held = nil
                        return .value(held)
                    }
                    if let failure = state.failure { return .failure(failure) }
                    if state.finished { return .value(nil) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    precondition(state.consumer == nil, "AcceptRelay: concurrent next() calls")
                    state.consumer = continuation
                    defer { state.demand = nil }
                    return .wait(state.demand)
                }
                switch step {
                case .value(let element): continuation.resume(returning: element)
                case .failure(let error): continuation.resume(throwing: error)
                case .wait(let demand): demand?.resume(returning: true)
                }
            }
        } onCancel: {
            let consumer = state.withLock { state in
                defer { state.consumer = nil }
                return state.consumer
            }
            consumer?.resume(throwing: CancellationError())
        }
    }

    func detach() {
        let consumer = state.withLock { state in
            state.epoch &+= 1
            defer { state.consumer = nil }
            return state.consumer
        }
        consumer?.resume(returning: nil)
    }

    // MARK: Relay

    func run<S: AsyncSequence>(_ sequence: S) async where S.Element == Element {
        var iterator = sequence.makeAsyncIterator()
        while await waitForDemand() {
            let element: Element?
            do {
                element = try await iterator.next()
            } catch {
                await finish(error is CancellationError ? nil : error)
                return
            }
            guard let element else {
                await finish(nil)
                return
            }
            let consumer = state.withLock { state -> CheckedContinuation<Element?, any Error>? in
                if let consumer = state.consumer {
                    state.consumer = nil
                    return consumer
                }
                state.held = element
                return nil
            }
            consumer?.resume(returning: element)
        }
        await finish(nil)
    }

    /// True once a consumer waits and nothing is held; false when finished or cancelled.
    private func waitForDemand() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let ready = state.withLock { state -> Bool? in
                    if state.finished || Task.isCancelled { return false }
                    if state.consumer != nil, state.held == nil { return true }
                    state.demand = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            let demand = state.withLock { state in
                defer { state.demand = nil }
                return state.demand
            }
            demand?.resume(returning: false)
        }
    }

    /// The wrapped listener ended (or failed, or the relay was cancelled): end the consumer
    /// and close a connection still held.
    func finish(_ failure: (any Error)?) async {
        let (consumer, held, demand) = state.withLock { state in
            state.finished = true
            if state.failure == nil { state.failure = failure }
            defer { state.consumer = nil; state.held = nil; state.demand = nil }
            return (state.consumer, state.held, state.demand)
        }
        if let failure { consumer?.resume(throwing: failure) } else { consumer?.resume(returning: nil) }
        demand?.resume(returning: false)
        if let held { await discard(held) }
    }

    /// The consumer side as a sequence; each iterator belongs to the epoch current when it was
    /// made.
    struct Connections: AsyncSequence, Sendable {
        typealias Failure = any Error
        let relay: AcceptRelay<Element>

        func makeAsyncIterator() -> Iterator { Iterator(relay: relay, epoch: relay.epoch) }

        struct Iterator: AsyncIteratorProtocol {
            let relay: AcceptRelay<Element>
            let epoch: UInt64

            mutating func next() async throws -> Element? {
                try await relay.next(epoch: epoch)
            }

            mutating func next(isolation actor: isolated (any Actor)?) async throws -> Element? {
                try await relay.next(epoch: epoch)
            }
        }
    }
}

/// A byte-stream listener behind an ``AcceptRelay`` (#0144).
final class RelayedListener<Base: TransportListener>: TransportListener, ListenerRelay {
    typealias Transport = Base.Transport
    let base: Base
    let relay: AcceptRelay<Base.Transport>

    init(_ base: Base) {
        self.base = base
        relay = AcceptRelay { transport in await transport.close(.shutdown) }
    }

    func listen() async throws -> TransportAddress { try await base.listen() }
    var connections: AcceptRelay<Base.Transport>.Connections { .init(relay: relay) }

    func close() async {
        await base.close()
        // The relay's pull then ends; this also covers a relay whose task never ran.
        await relay.finish(nil)
    }

    func run() async { await relay.run(base.connections) }
    func detach() { relay.detach() }
}

/// A multiplexed listener behind an ``AcceptRelay`` (#0144).
final class RelayedMultiplexedListener<Base: MultiplexedTransportListener>: MultiplexedTransportListener, ListenerRelay {
    typealias Connection = Base.Connection
    let base: Base
    let relay: AcceptRelay<Base.Connection>

    init(_ base: Base) {
        self.base = base
        relay = AcceptRelay { connection in await base.refuse(connection) }
    }

    func listen() async throws -> TransportAddress { try await base.listen() }
    var connections: AcceptRelay<Base.Connection>.Connections { .init(relay: relay) }
    func connectionInfo(_ connection: Base.Connection) -> ConnectionInfo { base.connectionInfo(connection) }
    func refuse(_ connection: Base.Connection) async { await base.refuse(connection) }

    func close() async {
        await base.close()
        await relay.finish(nil)
    }

    func run() async { await relay.run(base.connections) }
    func detach() { relay.detach() }
}
