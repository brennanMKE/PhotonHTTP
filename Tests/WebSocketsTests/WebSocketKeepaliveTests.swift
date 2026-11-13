import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing
@testable import WebSockets

/// Ping deadlines, control frames while the handler is not reading, and automatic keepalive
/// (#0137), over in-memory transports.
@Suite struct WebSocketKeepaliveTests {
    final class Box<Value: Sendable>: Sendable {
        let value: Mutex<Value>
        init(_ value: Value) { self.value = Mutex(value) }
        var current: Value { value.withLock { $0 } }
        func set(_ newValue: Value) { value.withLock { $0 = newValue } }
    }

    func session(
        configuration: WebSocketConfiguration,
        handler: @escaping @Sendable (WebSocket) async throws -> Void,
        client: @Sendable (InMemoryTransport) async throws -> Void
    ) async throws {
        let (clientSide, serverSide) = InMemoryTransport.makePair()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await WebSocket.run(over: serverSide, configuration: configuration, handler: handler)
            }
            try await client(clientSide)
            try await group.waitForAll()
        }
        #expect(serverSide.isClosed)
    }

    func send(_ transport: InMemoryTransport, _ bytes: [UInt8]) async throws {
        try await transport.send(ByteBuffer(bytes: bytes), endOfStream: false)
    }

    /// Answers the peer's Close and expects the server's end of stream.
    func finishClose(_ client: InMemoryTransport, _ reader: inout FrameReader) async throws {
        try await send(client, clientFrame(.close, closePayload(1000)))
        #expect(try await reader.next()?.closeCode == 1000)
        #expect(try await reader.readsEndOfStream())
        await client.close(.normal)
    }

    // MARK: ping deadline

    @Test(.timeLimit(.minutes(1)))
    func pingTimesOutWithoutAPong() async throws {
        let result = Box<WebSocketError?>(nil)
        let state = Box<WSConnection.State?>(nil)
        let gaveUp = ShutdownSignal()
        try await session(configuration: WebSocketConfiguration(keepalive: nil), handler: { socket in
            do {
                try await socket.ping(ByteBuffer(bytes: [1, 2]), timeout: .milliseconds(100))
            } catch let error as WebSocketError {
                result.set(error)
            }
            state.set(socket.state)
            gaveUp.trigger()
            for await _ in socket.messages {}
        }) { (client: InMemoryTransport) async throws in
            var reader = FrameReader(client)
            #expect(try await reader.next() == ServerFrame(opcode: .ping, fin: true, payload: [1, 2]))
            // No pong: the handler's ping times out; the connection stays open until we close.
            await gaveUp.wait()
            try await send(client, clientFrame(.close, closePayload(1000)))
            #expect(try await reader.next()?.closeCode == 1000)
            #expect(try await reader.readsEndOfStream())
            await client.close(.normal)
        }
        #expect(result.current == .pingTimedOut)
        #expect(state.current == .open)
    }

    @Test(.timeLimit(.minutes(1)))
    func pingSucceedsWithinItsTimeout() async throws {
        try await session(configuration: WebSocketConfiguration(keepalive: nil), handler: { socket in
            try await socket.ping(ByteBuffer(bytes: [7]), timeout: .seconds(30))
            try await socket.close()
            for await _ in socket.messages {}
        }) { (client: InMemoryTransport) async throws in
            var reader = FrameReader(client)
            #expect(try await reader.next()?.opcode == .ping)
            try await send(client, clientFrame(.pong, [7]))
            #expect(try await reader.next()?.closeCode == 1000)
            try await send(client, clientFrame(.close, closePayload(1000)))
            #expect(try await reader.readsEndOfStream())
            await client.close(.normal)
        }
    }

    // MARK: control frames while the handler is not reading

    @Test(.timeLimit(.minutes(1)))
    func controlFramesAreHandledWhileTheHandlerIsNotReading() async throws {
        let buffered = ShutdownSignal()
        let readingStarted = Box(false)
        let pongWhileReading = Box<Bool?>(nil)
        let received = Box<[WebSocketMessage]>([])
        try await session(configuration: WebSocketConfiguration(keepalive: nil), handler: { socket in
            await buffered.wait()
            // Two messages wait unread (one queued, one pending), yet our ping's pong is seen.
            try await socket.ping(ByteBuffer(bytes: [9]), timeout: .seconds(30))
            readingStarted.set(true)
            for await message in socket.messages { received.value.withLock { $0.append(message) } }
        }) { (client: InMemoryTransport) async throws in
            var reader = FrameReader(client)
            try await send(client, clientFrame(.text, "one") + clientFrame(.text, "two") + clientFrame(.ping, [1]))
            // The peer's ping is answered although the handler has read nothing.
            #expect(try await reader.next() == ServerFrame(opcode: .pong, fin: true, payload: [1]))
            buffered.trigger()
            #expect(try await reader.next() == ServerFrame(opcode: .ping, fin: true, payload: [9]))
            // A third message is behind the unread ones: the ping after it waits for the handler.
            try await send(client, clientFrame(.pong, [9]) + clientFrame(.text, "three") + clientFrame(.ping, [2]))
            #expect(try await reader.next() == ServerFrame(opcode: .pong, fin: true, payload: [2]))
            pongWhileReading.set(readingStarted.current)
            try await send(client, clientFrame(.close, closePayload(1000)))
            #expect(try await reader.next()?.closeCode == 1000)
            #expect(try await reader.readsEndOfStream())
            await client.close(.normal)
        }
        #expect(pongWhileReading.current == true)
        #expect(received.current == [.text("one"), .text("two"), .text("three")])
    }

    @Test(.timeLimit(.minutes(1)))
    func closeBehindUnreadMessagesStillDeliversThem() async throws {
        let go = ShutdownSignal()
        let received = Box<[WebSocketMessage]>([])
        try await session(configuration: WebSocketConfiguration(keepalive: nil), handler: { socket in
            await go.wait()
            for await message in socket.messages { received.value.withLock { $0.append(message) } }
        }) { (client: InMemoryTransport) async throws in
            var reader = FrameReader(client)
            try await send(client, clientFrame(.text, "a") + clientFrame(.text, "b") + clientFrame(.close, closePayload(1000)))
            // The Close is seen and echoed before the handler reads anything.
            #expect(try await reader.next()?.closeCode == 1000)
            #expect(try await reader.readsEndOfStream())
            go.trigger()
            await client.close(.normal)
        }
        #expect(received.current == [.text("a"), .text("b")])
    }

    // MARK: keepalive

    static let fast = WebSocketConfiguration.Keepalive(interval: .milliseconds(100), timeout: .milliseconds(150))

    @Test(.timeLimit(.minutes(1)))
    func keepaliveClosesASilentPeer() async throws {
        let code = Box<WebSocketCloseCode?>(nil)
        try await session(configuration: WebSocketConfiguration(keepalive: Self.fast), handler: { socket in
            for await _ in socket.messages {}
            code.set(socket.closeCode)
        }) { (client: InMemoryTransport) async throws in
            var reader = FrameReader(client)
            // The peer is gone: it never answers. One ping, then the transport closes with no
            // close handshake.
            #expect(try await reader.next() == ServerFrame(opcode: .ping, fin: true, payload: []))
            #expect(try await reader.readsEndOfStream())
            await client.close(.normal)
        }
        #expect(code.current == .abnormalClosure)
    }

    @Test(.timeLimit(.minutes(1)))
    func keepaliveKeepsAHealthyIdlePeerOpen() async throws {
        let pings = Box(0)
        let state = Box<WSConnection.State?>(nil)
        let code = Box<WebSocketCloseCode?>(nil)
        let done = ShutdownSignal()
        try await session(configuration: WebSocketConfiguration(keepalive: Self.fast), handler: { socket in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    await done.wait()
                    state.set(socket.state)
                    try await socket.close()
                }
                for await _ in socket.messages {}
                try await group.waitForAll()
            }
            code.set(socket.closeCode)
        }) { (client: InMemoryTransport) async throws in
            var reader = FrameReader(client)
            // Answer every ping for well past interval + timeout.
            while pings.current < 4 {
                let frame = try await reader.next()
                #expect(frame?.opcode == .ping)
                guard frame?.opcode == .ping else { break }
                pings.value.withLock { $0 += 1 }
                try await send(client, clientFrame(.pong, frame!.payload))
            }
            done.trigger()
            var frame = try await reader.next()
            while frame?.opcode == .ping { frame = try await reader.next() }
            #expect(frame?.closeCode == 1000)
            try await send(client, clientFrame(.close, closePayload(1000)))
            #expect(try await reader.readsEndOfStream())
            await client.close(.normal)
        }
        #expect(pings.current == 4)
        #expect(state.current == .open)
        #expect(code.current == .normalClosure)
    }

    @Test(.timeLimit(.minutes(1)))
    func keepaliveSparesAPeerAheadOfASlowHandler() async throws {
        let go = ShutdownSignal()
        let state = Box<WSConnection.State?>(nil)
        let received = Box<[WebSocketMessage]>([])
        try await session(configuration: WebSocketConfiguration(keepalive: Self.fast), handler: { socket in
            // Busy for several keepalive periods while the peer's messages wait.
            await go.wait()
            state.set(socket.state)
            try await socket.close()
            for await message in socket.messages { received.value.withLock { $0.append(message) } }
        }) { (client: InMemoryTransport) async throws in
            var reader = FrameReader(client)
            try await send(client, clientFrame(.text, "1") + clientFrame(.text, "2") + clientFrame(.text, "3"))
            try await Task.sleep(for: .milliseconds(800))
            go.trigger()
            var frame = try await reader.next()
            while frame?.opcode == .ping {
                try await send(client, clientFrame(.pong, frame!.payload))
                frame = try await reader.next()
            }
            #expect(frame?.closeCode == 1000)
            try await send(client, clientFrame(.close, closePayload(1000)))
            #expect(try await reader.readsEndOfStream())
            await client.close(.normal)
        }
        #expect(state.current == .open)
    }

    @Test func defaults() {
        let keepalive = WebSocketConfiguration().keepalive
        #expect(keepalive == WebSocketConfiguration.Keepalive(interval: .seconds(20), timeout: .seconds(10)))
        // Below HTTP/3's 30 s QUIC idle timeout.
        #expect(keepalive!.interval < .seconds(30))
    }

    // MARK: state machine

    @Test func holdingDataFramesStopsBeforeTheNextDataFrameOnly() {
        var connection = WSConnection()
        connection.holdsDataFrames = true
        var input = ByteBuffer(bytes: clientFrame(.ping, [1]) + clientFrame(.text, "x") + clientFrame(.ping, [2]))
        #expect(connection.process(&input) == .sendPong(ByteBuffer(bytes: [1])))
        #expect(connection.process(&input) == .awaitApplication)
        #expect(connection.process(&input) == .awaitApplication)
        connection.holdsDataFrames = false
        #expect(connection.process(&input) == .deliver(.text("x")))
        #expect(connection.process(&input) == .sendPong(ByteBuffer(bytes: [2])))
        #expect(connection.process(&input) == .needMoreBytes)
    }

    @Test func pongTimeoutClosesAsAbnormal() {
        var connection = WSConnection()
        #expect(connection.handle(.pongTimedOut) == .closeTransport(.timeout))
        #expect(connection.state == .closed)
        #expect(connection.receivedCloseCode == .abnormalClosure)
        #expect(connection.handle(.pongTimedOut) == .none)
    }
}
