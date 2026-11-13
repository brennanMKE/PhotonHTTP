public import HTTPCore
import Synchronization

/// Errors thrown by ``WebSocket``.
public enum WebSocketError: Error, Sendable, Hashable {
    /// The connection is closing or closed; nothing more can be sent.
    case closed
    /// The close code may not be sent (RFC 6455 §7.4).
    case invalidCloseCode(WebSocketCloseCode)
    /// A close reason longer than 123 UTF-8 bytes (a control frame holds 125).
    case closeReasonTooLong
    /// A ping payload longer than 125 bytes.
    case pingPayloadTooLong
    /// No pong answered ``WebSocket/ping(_:timeout:)`` within its timeout. The connection
    /// stays open; the application decides what to do.
    case pingTimedOut
}

/// Limits and timeouts of a WebSocket session.
public struct WebSocketConfiguration: Sendable, Hashable {
    /// Largest payload of one received frame (1009 beyond).
    public var maxFrameSize: Int
    /// Largest received message after reassembly (1009 beyond).
    public var maxMessageSize: Int
    /// How long to wait for the peer's Close after ours, or for its end of stream after the
    /// handshake, before the transport is closed anyway.
    public var closeTimeout: Duration
    /// Received messages buffered for the application before reading stops (backpressure).
    public var inboundMessageCapacity: Int
    /// Frames queued for sending before `send` suspends.
    public var outboundFrameCapacity: Int
    /// Largest single read from the transport.
    public var receiveSize: Int
    /// permessage-deflate (RFC 7692, #0110): `nil` (the default) declines the extension;
    /// otherwise ``WebSocketUpgrade`` accepts a client's offer on these terms. The inflated
    /// size of a received message is bounded by ``maxMessageSize``.
    public var compression: PerMessageDeflate.Configuration?
    /// Automatic keepalive (#0137): when nothing has arrived from the peer for
    /// ``Keepalive/interval``, the session sends a ping; when nothing arrives within
    /// ``Keepalive/timeout`` after it, the peer is presumed gone and the connection closes
    /// as 1006 (abnormal closure). `nil` turns it off. The default (20 s, 10 s) keeps a quiet
    /// HTTP/3 stream below QUIC's 30 s idle timeout and drops a vanished peer within 30 s.
    public var keepalive: Keepalive?

    /// Keepalive timing; see ``WebSocketConfiguration/keepalive``.
    public struct Keepalive: Sendable, Hashable {
        /// How long the peer may be silent before the session pings it. Keep it below any
        /// idle timeout on the path (QUIC's is 30 s by default; proxies and NATs often 60 s).
        public var interval: Duration
        /// How long after the ping something (its pong or any frame) must arrive.
        public var timeout: Duration

        public init(interval: Duration = .seconds(20), timeout: Duration = .seconds(10)) {
            precondition(interval > .zero && timeout > .zero)
            self.interval = interval
            self.timeout = timeout
        }
    }

    public init(
        maxFrameSize: Int = 16 * 1024 * 1024,
        maxMessageSize: Int = 16 * 1024 * 1024,
        closeTimeout: Duration = .seconds(5),
        inboundMessageCapacity: Int = 1,
        outboundFrameCapacity: Int = 8,
        receiveSize: Int = 64 * 1024,
        compression: PerMessageDeflate.Configuration? = nil,
        keepalive: Keepalive? = Keepalive()
    ) {
        precondition(maxFrameSize >= 125 && maxMessageSize >= 0 && inboundMessageCapacity >= 1
                     && outboundFrameCapacity >= 1 && receiveSize > 0)
        self.maxFrameSize = maxFrameSize
        self.maxMessageSize = maxMessageSize
        self.closeTimeout = closeTimeout
        self.inboundMessageCapacity = inboundMessageCapacity
        self.outboundFrameCapacity = outboundFrameCapacity
        self.receiveSize = receiveSize
        self.compression = compression
        self.keepalive = keepalive
    }
}

/// One server-side WebSocket connection (RFC 6455).
///
/// Received messages arrive through ``messages``, an `AsyncSequence` that ends when the
/// connection closes. Reading is demand-driven: the session buffers at most
/// ``WebSocketConfiguration/inboundMessageCapacity`` messages, then stops reading the
/// transport until the application takes one, so a slow reader slows the peer. ``send(_:)``
/// suspends while ``WebSocketConfiguration/outboundFrameCapacity`` frames wait for the
/// transport. Control frames do not wait for the application: while it has not taken a
/// message, the session keeps reading up to the next data frame, so pings are answered and
/// pongs and Close are seen. Pings are answered automatically; ``ping(_:timeout:)`` sends one
/// and waits for its pong; ``WebSocketConfiguration/keepalive`` pings an idle peer and drops
/// one that stopped answering.
///
/// The session runs over any ``ByteStreamTransport`` (an HTTP/1.1 connection after `101`
/// today, an HTTP/2 or HTTP/3 extended CONNECT stream later), started by
/// ``run(over:subprotocol:configuration:handler:)``.
public final class WebSocket: Sendable {
    /// The subprotocol agreed in the handshake, if any.
    public let subprotocol: String?
    /// The permessage-deflate parameters agreed in the handshake, or `nil` when messages are
    /// not compressed.
    public let compression: PerMessageDeflate.Parameters?
    /// The underlying connection's addresses.
    public let connectionInfo: ConnectionInfo
    public let configuration: WebSocketConfiguration

    struct Outbound: Sendable {
        var opcode: WSOpcode
        var payload: ByteBuffer
        /// The last frame: shut down the sending side after it.
        var endOfStream = false
    }

    struct PingWaiter: Sendable {
        var payload: ByteBuffer
        var signal: ShutdownSignal
    }

    struct Shared: Sendable {
        var connection: WSConnection
        var pingWaiters: [UInt64: PingWaiter] = [:]
        var answeredPings: Set<UInt64> = []
        var nextPingID: UInt64 = 0
        var readerFinished = false
        /// A delivered message the inbound queue had no room for; the reader stops before the
        /// next data frame until the application takes it.
        var pending: WebSocketMessage?
        /// The session ended while a message was pending: finish ``inbound`` once it is taken.
        var finishInboundAfterPending = false
        /// The application stopped reading ``messages``.
        var inboundAbandoned = false
        /// The reader waits for the application (``WSConnection/Action/awaitApplication``).
        var awaitingApplication = false
        /// When bytes last arrived from the peer (keepalive).
        var lastReceive = ContinuousClock.now
    }

    let inbound: BoundedAsyncQueue<WebSocketMessage>
    let outbound: BoundedAsyncQueue<Outbound>
    let shared: Mutex<Shared>
    /// Wakes the reader when the application takes the pending message (or abandons reading).
    let applicationTook = BoundedAsyncQueue<Void>(capacity: 1)
    /// Triggered when a Close frame is queued: starts the close timer.
    let closeStarted = ShutdownSignal()
    /// Compresses outgoing data messages; used only by the writer task.
    let deflater: PerMessageDeflate.Deflater?

    init(subprotocol: String?, connectionInfo: ConnectionInfo, configuration: WebSocketConfiguration,
         compression: PerMessageDeflate.Parameters? = nil, deflater: PerMessageDeflate.Deflater? = nil,
         inflater: PerMessageDeflate.Inflater? = nil) {
        self.subprotocol = subprotocol
        self.connectionInfo = connectionInfo
        self.configuration = configuration
        self.compression = compression
        self.deflater = deflater
        inbound = BoundedAsyncQueue(capacity: configuration.inboundMessageCapacity)
        outbound = BoundedAsyncQueue(capacity: configuration.outboundFrameCapacity)
        shared = Mutex(Shared(connection: WSConnection(configuration: .init(
            maxFrameSize: configuration.maxFrameSize, maxMessageSize: configuration.maxMessageSize),
            inflater: inflater)))
    }

    /// Compressed messages received so far.
    var compressedMessagesReceived: Int { shared.withLock { $0.connection.compressedMessages } }

    // MARK: Application API

    /// Received messages, in order. Iteration ends when the connection closes. Iterate from
    /// one task at a time.
    public var messages: Messages { Messages(socket: self) }

    public struct Messages: AsyncSequence, Sendable {
        public typealias Element = WebSocketMessage
        public typealias Failure = Never
        let socket: WebSocket

        public func makeAsyncIterator() -> Iterator { Iterator(socket: socket) }

        public struct Iterator: AsyncIteratorProtocol {
            let socket: WebSocket
            public mutating func next() async -> WebSocketMessage? {
                let message = await socket.inbound.next()
                socket.promotePending()
                return message
            }
        }
    }

    /// Moves the pending message into the room the application just made, and wakes the reader.
    func promotePending() {
        let promoted = shared.withLock { shared -> Bool in
            guard let message = shared.pending, inbound.trySend(message) else { return false }
            shared.pending = nil
            if shared.finishInboundAfterPending { inbound.finish() }
            return true
        }
        if promoted { _ = applicationTook.trySend(()) }
    }

    /// Hands a received message to the application without waiting for it: into the inbound
    /// queue, or, when that is full, into the single pending slot.
    func deliver(_ message: WebSocketMessage) {
        shared.withLock { shared in
            guard !shared.inboundAbandoned, !inbound.trySend(message) else { return }
            shared.pending = message
        }
    }

    /// The connection state.
    public var state: WSConnection.State { shared.withLock { $0.connection.state } }

    /// The code the peer closed with (``WebSocketCloseCode/noStatusReceived`` for a Close
    /// without one, ``WebSocketCloseCode/abnormalClosure`` if the stream ended without a
    /// Close), or `nil` while no Close was received.
    public var closeCode: WebSocketCloseCode? { shared.withLock { $0.connection.receivedCloseCode } }

    /// The reason in the peer's Close frame.
    public var closeReason: String { shared.withLock { $0.connection.receivedCloseReason } }

    /// The code that failed the connection when the peer violated the protocol.
    public var failureCode: WebSocketCloseCode? { shared.withLock { $0.connection.failure } }

    /// Sends a message as one frame. Suspends while the outbound queue is full.
    public func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .text(let text):
            var payload = ByteBuffer(capacity: text.utf8.count)
            payload.append(contentsOf: text.utf8)
            try await enqueue(Outbound(opcode: .text, payload: payload))
        case .binary(let bytes):
            try await enqueue(Outbound(opcode: .binary, payload: bytes))
        }
    }

    /// Sends a text message.
    public func send(text: String) async throws {
        try await send(.text(text))
    }

    /// Sends a binary message.
    public func send(binary: ByteBuffer) async throws {
        try await send(.binary(binary))
    }

    /// Sends a ping and waits up to `timeout` for a pong with the same payload.
    ///
    /// The pong is seen even while the application is not reading ``messages``, unless the
    /// peer sent a data message ahead of it that is still waiting behind an unread one.
    ///
    /// - Throws: ``WebSocketError/pingTimedOut`` when no pong arrives in time (the connection
    ///   stays open), ``WebSocketError/closed`` if the connection closes first.
    public func ping(_ payload: ByteBuffer = ByteBuffer(), timeout: Duration = .seconds(10)) async throws {
        guard payload.readableBytes <= 125 else { throw WebSocketError.pingPayloadTooLong }
        let signal = ShutdownSignal()
        let id = try shared.withLock { shared throws(WebSocketError) -> UInt64 in
            guard shared.connection.state == .open, !shared.readerFinished else { throw .closed }
            let id = shared.nextPingID
            shared.nextPingID &+= 1
            shared.pingWaiters[id] = PingWaiter(payload: payload, signal: signal)
            return id
        }
        do {
            try await enqueue(Outbound(opcode: .ping, payload: payload))
        } catch {
            _ = shared.withLock { $0.pingWaiters.removeValue(forKey: id) }
            throw error
        }
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await signal.wait(); return false }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch { return false }
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        let answered = shared.withLock { shared -> Bool in
            shared.pingWaiters.removeValue(forKey: id)
            return shared.answeredPings.remove(id) != nil
        }
        if answered { return }
        try Task.checkCancellation()
        throw timedOut ? WebSocketError.pingTimedOut : WebSocketError.closed
    }

    /// Starts the close handshake with `code` and `reason`. Returns once the Close frame is
    /// queued; ``messages`` ends when the peer answers (or the close timeout passes). Closing
    /// a connection that is already closing does nothing.
    public func close(code: WebSocketCloseCode = .normalClosure, reason: String = "") async throws {
        guard code.isValidOnTheWire else { throw WebSocketError.invalidCloseCode(code) }
        guard reason.utf8.count <= 123 else { throw WebSocketError.closeReasonTooLong }
        let action = shared.withLock { $0.connection.handle(.closeRequested(code, reason: reason)) }
        guard case .sendClose(let code, let reason, _) = action else { return }
        closeStarted.trigger()
        try? await outbound.send(Outbound(opcode: .close, payload: WSFrameWriter.closePayload(code: code, reason: reason)))
    }

    func enqueue(_ frame: Outbound) async throws {
        guard state == .open else { throw WebSocketError.closed }
        do {
            try await outbound.send(frame)
        } catch is BoundedAsyncQueueFinishedError {
            throw WebSocketError.closed
        }
    }

    // MARK: Session

    enum Role { case reader, writer, handler, timer, shutdownWatcher, keepalive }

    /// Runs a WebSocket session over `transport` (after the handshake) until the connection
    /// closes and `handler` returns, then closes the transport.
    ///
    /// When `handler` returns while the connection is open, the session closes it with 1000;
    /// when it throws, with 1011. When `shutdown` triggers (the server is draining, from the
    /// tunnel's ``TunnelContext``), the session starts the close handshake with 1001 Going
    /// Away; the handler sees ``messages`` end once the peer answers (#0116). The session
    /// reads, writes and times the close handshake in child tasks of one task group; nothing
    /// outlives this call.
    ///
    /// `compression` is the permessage-deflate agreement from the handshake
    /// (``PerMessageDeflate/negotiate(offers:configuration:)``); with it, data messages are
    /// compressed per message and RSV1 messages from the peer are inflated.
    public static func run<T: ByteStreamTransport>(
        over transport: T,
        subprotocol: String? = nil,
        configuration: WebSocketConfiguration = WebSocketConfiguration(),
        compression: PerMessageDeflate.Parameters? = nil,
        shutdown: ShutdownSignal? = nil,
        handler: @escaping @Sendable (WebSocket) async throws -> Void
    ) async {
        var deflater: PerMessageDeflate.Deflater?
        var inflater: PerMessageDeflate.Inflater?
        if let compression {
            deflater = PerMessageDeflate.Deflater(compression)
            inflater = PerMessageDeflate.Inflater(compression)
            guard deflater != nil, inflater != nil else {
                // zlib could not allocate its state: refuse the session with 1011.
                var frame = ByteBuffer()
                WSFrameWriter.appendFrame(opcode: .close, payload: WSFrameWriter.closePayload(code: .internalServerError),
                                          into: &frame)
                try? await transport.send(frame, endOfStream: true)
                await transport.close(.normal)
                return
            }
        }
        let socket = WebSocket(subprotocol: subprotocol, connectionInfo: transport.info, configuration: configuration,
                               compression: compression, deflater: deflater, inflater: inflater)
        await withTaskGroup(of: Role.self) { group in
            group.addTask { await socket.readLoop(transport); return .reader }
            group.addTask { await socket.writeLoop(transport); return .writer }
            group.addTask { await socket.closeTimer(transport); return .timer }
            if let keepalive = configuration.keepalive {
                group.addTask { await socket.keepaliveLoop(transport, keepalive); return .keepalive }
            }
            if let shutdown {
                group.addTask {
                    await shutdown.wait()
                    if shutdown.isTriggered && !Task.isCancelled {
                        try? await socket.close(code: .goingAway)
                    }
                    return .shutdownWatcher
                }
            }
            group.addTask {
                do {
                    try await handler(socket)
                    try? await socket.close(code: .normalClosure)
                } catch {
                    try? await socket.close(code: .internalServerError)
                }
                socket.abandonInbound()
                return .handler
            }
            var running = 3
            while let role = await group.next() {
                if role == .reader || role == .writer || role == .handler {
                    running -= 1
                    if running == 0 { group.cancelAll() }
                }
            }
        }
        await transport.close(.normal)
    }

    /// The application stopped reading: drop what is buffered and whatever arrives later, so
    /// the reader never waits for it.
    func abandonInbound() {
        shared.withLock { shared in
            shared.inboundAbandoned = true
            shared.pending = nil
        }
        inbound.finish()
        while inbound.tryNext() != nil {}
        _ = applicationTook.trySend(())
    }

    func readLoop<T: ByteStreamTransport>(_ transport: T) async {
        var buffer = ByteBuffer(capacity: configuration.receiveSize)
        /// After our final Close: discard input until the peer's end of stream.
        var draining = false
        var received = false
        reading: while true {
            if !draining {
                processing: while true {
                    let action = shared.withLock { shared in
                        if received { shared.lastReceive = .now }
                        shared.connection.holdsDataFrames = shared.pending != nil
                        return shared.connection.process(&buffer)
                    }
                    received = false
                    switch action {
                    case .needMoreBytes, .none:
                        break processing
                    case .deliver(let message):
                        deliver(message)
                    case .awaitApplication:
                        // The application is behind and a data frame is next: read nothing more
                        // until it takes the pending message (backpressure on the peer).
                        shared.withLock { $0.awaitingApplication = true }
                        while shared.withLock({ $0.pending != nil }) {
                            guard await applicationTook.next() != nil else {
                                shared.withLock { $0.awaitingApplication = false }
                                break reading
                            }
                        }
                        shared.withLock { $0.awaitingApplication = false }
                    case .sendPong(let payload):
                        try? await outbound.send(Outbound(opcode: .pong, payload: payload))
                    case .receivedPong(let payload):
                        answerPings(payload)
                    case .sendClose(let code, let reason, let thenCloseTransport):
                        closeStarted.trigger()
                        let payload = WSFrameWriter.closePayload(code: code, reason: reason)
                        try? await outbound.send(Outbound(opcode: .close, payload: payload, endOfStream: thenCloseTransport))
                        if thenCloseTransport {
                            endApplicationSide()
                            draining = true
                            break processing
                        }
                    case .closeTransport:
                        break reading
                    }
                }
            }
            if draining { buffer.clear() } else { buffer.discardReadBytes() }
            let count: Int
            do {
                count = try await transport.receive(into: &buffer, maxLength: configuration.receiveSize)
            } catch {
                _ = shared.withLock { $0.connection.handle(.endOfStream) }
                break reading
            }
            if count == 0 {
                _ = shared.withLock { $0.connection.handle(.endOfStream) }
                break reading
            }
            received = true
        }
        shared.withLock { $0.readerFinished = true }
        endApplicationSide()
    }

    /// Ends ``messages``, stops accepting frames once the queued ones are written, and fails
    /// waiting pings.
    func endApplicationSide() {
        shared.withLock { shared in
            // A pending message is still delivered; ``messages`` ends after it.
            if shared.pending != nil {
                shared.finishInboundAfterPending = true
            } else {
                inbound.finish()
            }
        }
        outbound.finish()
        let waiters = shared.withLock { shared -> [PingWaiter] in
            defer { shared.pingWaiters = [:] }
            return Array(shared.pingWaiters.values)
        }
        for waiter in waiters { waiter.signal.trigger() }
    }

    func answerPings(_ payload: ByteBuffer) {
        let signals = shared.withLock { shared -> [ShutdownSignal] in
            var signals: [ShutdownSignal] = []
            for (id, waiter) in shared.pingWaiters where waiter.payload == payload {
                shared.answeredPings.insert(id)
                signals.append(waiter.signal)
            }
            return signals
        }
        for signal in signals { signal.trigger() }
    }

    func writeLoop<T: ByteStreamTransport>(_ transport: T) async {
        var frame = ByteBuffer(capacity: 256)
        var compressed = ByteBuffer()
        var closeSent = false
        for await item in outbound {
            // Nothing follows a Close (RFC 6455 §5.5.1); late frames are dropped.
            if closeSent { continue }
            closeSent = item.opcode == .close
            frame.clear()
            if let deflater, !item.opcode.isControl,
               let length = deflater.compress(item.payload, into: &compressed) {
                // permessage-deflate: one frame with RSV1, the deflate data without its tail.
                WSFrameWriter.appendHeader(reservedBits: 0x40, opcode: item.opcode, payloadLength: length, into: &frame)
                frame.append(ByteView(offset: compressed.readerIndex, length: length), from: compressed)
                do {
                    try await transport.send(frame, endOfStream: item.endOfStream)
                } catch {
                    await abandonWrites(transport)
                    return
                }
                // Do not keep a large message's buffers for the rest of the connection.
                if compressed.capacity > 256 * 1024 { compressed = ByteBuffer() }
                if frame.capacity > 256 * 1024 { frame = ByteBuffer(capacity: 256) }
                continue
            }
            WSFrameWriter.appendHeader(opcode: item.opcode, payloadLength: item.payload.readableBytes, into: &frame)
            do {
                if item.payload.readableBytes <= 16 * 1024 {
                    frame.append(item.payload)
                    try await transport.send(frame, endOfStream: item.endOfStream)
                } else {
                    try await transport.send(frame, endOfStream: false)
                    try await transport.send(item.payload, endOfStream: item.endOfStream)
                }
            } catch {
                await abandonWrites(transport)
                return
            }
            if frame.capacity > 256 * 1024 { frame = ByteBuffer(capacity: 256) }
        }
    }

    /// The peer is gone: unblock the reader and drop the rest.
    func abandonWrites<T: ByteStreamTransport>(_ transport: T) async {
        outbound.finish()
        while outbound.tryNext() != nil {}
        await transport.close(.abort)
    }

    /// Automatic keepalive: pings a peer that has been silent for `keepalive.interval`, and
    /// closes the connection (1006, no close handshake) when nothing arrives within
    /// `keepalive.timeout` of the ping. A reader waiting for the application counts as
    /// activity: the peer is ahead of us, not gone. Ends when the connection leaves `open`.
    func keepaliveLoop<T: ByteStreamTransport>(_ transport: T, _ keepalive: WebSocketConfiguration.Keepalive) async {
        while !Task.isCancelled {
            let (open, lastReceive, waiting) = shared.withLock { shared in
                (shared.connection.state == .open && !shared.readerFinished, shared.lastReceive,
                 shared.awaitingApplication)
            }
            guard open else { return }
            let now = ContinuousClock.now
            let due = waiting ? now + keepalive.interval : lastReceive + keepalive.interval
            if due > now {
                do { try await Task.sleep(until: due, clock: .continuous) } catch { return }
                continue
            }
            let sentAt = ContinuousClock.now
            let deadline = sentAt + keepalive.timeout
            await sendKeepalivePing(until: deadline)
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            let timedOut = shared.withLock { shared -> Bool in
                if shared.lastReceive > sentAt || shared.awaitingApplication { return false }
                return shared.connection.handle(.pongTimedOut) != .none
            }
            if timedOut {
                endApplicationSide()
                await transport.close(.timeout)
                return
            }
        }
    }

    /// Queues an empty ping; waits for room in the outbound queue no later than `deadline`.
    func sendKeepalivePing(until deadline: ContinuousClock.Instant) async {
        guard state == .open else { return }
        let ping = Outbound(opcode: .ping, payload: ByteBuffer())
        if outbound.trySend(ping) { return }
        let outbound = outbound
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await outbound.send(ping) }
            group.addTask { try? await Task.sleep(until: deadline, clock: .continuous) }
            await group.next()
            group.cancelAll()
        }
    }

    func closeTimer<T: ByteStreamTransport>(_ transport: T) async {
        await closeStarted.wait()
        guard !Task.isCancelled else { return }
        do {
            try await Task.sleep(for: configuration.closeTimeout)
        } catch {
            return
        }
        let readerFinished = shared.withLock { shared -> Bool in
            _ = shared.connection.handle(.closeTimedOut)
            return shared.readerFinished
        }
        if !readerFinished { await transport.close(.timeout) }
    }
}
