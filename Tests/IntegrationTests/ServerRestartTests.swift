import Foundation
import HTTP1
import HTTPCore
import HTTPServer
import HTTPTestSupport
import NetworkTransport
import Synchronization
import Testing

/// `Server.restart(...)` (#0144): a new generation of listeners, protocols and configuration
/// in the same process, with no gap. In memory for the hand-over and the failure paths; on
/// 127.0.0.1 (port 0, then that port) for BSD port sharing and the TLS hand-over, with clients
/// sending requests in a loop across several restarts.
@Suite struct ServerRestartTests {
    // MARK: In memory

    /// A listener that cannot share its port (like Network.framework's) is handed over: the
    /// new entry's listener is never made, new connections run the new protocol, and the
    /// old connection drains after the grace.
    @Test(.timeLimit(.minutes(1)))
    func aListenerThatCannotShareIsHandedOver() async throws {
        let address = TransportAddress(host: "memory", port: 1)
        let listener = InMemoryListener(address: address)
        let oldProbe = Probe()
        let newProbe = Probe()
        let made = Mutex(0)
        let server = Server(configuration: ServerConfiguration(drainTimeout: .seconds(5)),
                            listeners: [ServerListener.byteStream(listener, name: "a").restartable(address: address, identity: "a")],
                            protocols: [TestEchoProtocol(probe: oldProbe)], handler: NoContentHandler())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            _ = try await server.waitUntilRunning()
            let old = await listener.connect()
            #expect(await roundTrip(old, "one") == "one")

            let next = ServerListener.byteStream(name: "a") { _ -> InMemoryListener in
                made.withLock { $0 += 1 }
                return InMemoryListener(address: address)
            }.restartable(address: address, identity: "a")
            let addresses = try await server.restart(configuration: ServerConfiguration(maxConnections: 7, drainTimeout: .seconds(5)),
                                                     listeners: [next], protocols: [TestEchoProtocol(probe: newProbe)],
                                                     grace: .milliseconds(100))
            #expect(addresses == [address])
            #expect(made.withLock { $0 } == 0, "a handed-over listener is not made again")
            #expect(!listener.isClosed)
            #expect(server.configuration.maxConnections == 7)

            // New connections reach the new generation's protocol.
            let fresh = await listener.connect()
            #expect(await roundTrip(fresh, "two") == "two")
            #expect(newProbe.snapshot.started == 1)
            #expect(oldProbe.snapshot.started == 1)

            // The old connection is told to drain after the grace: its next answer is its last.
            #expect(oldProbe.snapshot.finished == 0)
            try await Task.sleep(for: .milliseconds(200))
            #expect(await roundTrip(old, "last") == "last")
            try await eventually { oldProbe.snapshot.finished == 1 }
            #expect(oldProbe.snapshot.sawShutdown == 1)
            #expect(newProbe.snapshot.sawShutdown == 0)
            #expect(server.listenerStatistics.map(\.accepted) == [1])

            await fresh.close(.normal)
            await server.shutdown()
            try await group.waitForAll()
        }
        #expect(listener.isClosed, "the new generation closes the listener it was handed")
        #expect(newProbe.snapshot.finished == 1)
    }

    /// A new listener that cannot bind aborts the restart: the listeners made for it close,
    /// the running ones keep serving with the running protocol and configuration.
    @Test(.timeLimit(.minutes(1)))
    func aListenerThatCannotBindAbortsTheRestart() async throws {
        let address = TransportAddress(host: "memory", port: 1)
        let listener = InMemoryListener(address: address)
        let probe = Probe()
        let server = Server(configuration: ServerConfiguration(maxConnections: 3, drainTimeout: .seconds(2)),
                            listeners: [ServerListener.byteStream(listener, name: "a").restartable(address: address, identity: "a")],
                            protocols: [TestEchoProtocol(probe: probe)], handler: NoContentHandler())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            _ = try await server.waitUntilRunning()
            let extra = InMemoryListener(address: TransportAddress(host: "memory", port: 2))
            let failing = InMemoryListener(address: TransportAddress(host: "memory", port: 3),
                                           failure: TransportError.failed(code: 48))
            let next: [ServerListener] = [
                ServerListener.byteStream(name: "a") { _ in InMemoryListener(address: address) }
                    .restartable(address: address, identity: "a"),
                .byteStream(extra, name: "b"),
                .byteStream(failing, name: "c"),
            ]
            do {
                try await server.restart(configuration: ServerConfiguration(maxConnections: 9), listeners: next,
                                         protocols: [TestEchoProtocol(probe: Probe())])
                Issue.record("the restart should fail")
            } catch let error as ServerRestartError {
                #expect(error.listener == "c")
                #expect(error.closedRunningListener == nil)
                #expect(error.underlying as? TransportError == .failed(code: 48))
            }
            #expect(extra.isClosed, "listeners bound for the failed restart close")
            #expect(!listener.isClosed)
            #expect(server.configuration.maxConnections == 3)
            #expect(server.lifecycleState == .running)

            let client = await listener.connect()
            #expect(await roundTrip(client, "still") == "still")
            #expect(probe.snapshot.started == 1)

            // Another restart works afterwards.
            try await server.restart(listeners: [ServerListener.byteStream(name: "a") { _ in InMemoryListener(address: address) }
                                        .restartable(address: address, identity: "a")])
            await server.shutdown()
            try await group.waitForAll()
        }
    }

    /// A running listener that cannot share its address and serves something else (another
    /// identity, or other ALPN tokens) is replaced: it closes first, then the new one binds
    /// the same address.
    @Test(.timeLimit(.minutes(1)))
    func aListenerThatCannotShareOrBeHandedOverIsReplaced() async throws {
        let address = TransportAddress(host: "memory", port: 1)
        let old = InMemoryListener(address: address)
        let new = InMemoryListener(address: address)
        let probe = Probe()
        let server = Server(configuration: ServerConfiguration(drainTimeout: .seconds(1)),
                            listeners: [ServerListener.byteStream(old, name: "a").restartable(address: address, identity: "a")],
                            protocols: [TestEchoProtocol(probe: probe)], handler: NoContentHandler())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            _ = try await server.waitUntilRunning()
            try await server.restart(listeners: [ServerListener.byteStream(new, name: "a").restartable(address: address, identity: "b")],
                                     grace: .zero)
            #expect(old.isClosed)
            #expect(!new.isClosed)
            let client = await new.connect()
            #expect(await roundTrip(client, "new") == "new")
            await client.close(.normal)
            await server.shutdown()
            try await group.waitForAll()
        }
        #expect(new.isClosed)
    }

    /// Restarts run one at a time, and only while running.
    @Test(.timeLimit(.minutes(1)))
    func restartNeedsARunningServer() async throws {
        let server = Server(listeners: [.byteStream(InMemoryListener(), name: "a")],
                            protocols: [TestEchoProtocol(probe: Probe())], handler: NoContentHandler())
        await #expect(throws: ServerError.notRunning) {
            try await server.restart(listeners: [.byteStream(InMemoryListener(), name: "a")])
        }
    }

    // MARK: Loopback

    /// The cleartext BSD listener restarts five times on the port it got from port 0 while
    /// clients send requests in a loop, on new connections and on keep-alive ones: no connect
    /// is refused, every request sent gets a whole response (a keep-alive connection the old
    /// generation closed between requests is reopened, as HTTP clients do), and new
    /// connections after a restart see the new limit.
    @Test(.timeLimit(.minutes(2)))
    func bsdListenerRestartsOnTheSamePortWithNoGap() async throws {
        let first = try BSDSocketListener(configuration: .init(port: 0, tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
        let server = Server(configuration: ServerConfiguration(drainTimeout: .seconds(3)),
                            listeners: [ServerListener.byteStream(first, name: "http")
                                .restartable(address: TransportAddress(host: "127.0.0.1", port: 0), identity: "http")],
                            protocols: [HTTP1()], handler: NoContentHandler())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            let port = try #require(try await server.waitUntilRunning().first?.port)
            let address = TransportAddress(host: "127.0.0.1", port: port)
            #expect(try await RestartClient.status(of: RestartClient.post(1000), port: port) == 204)

            let clients = RestartClient(port: port)
            try await clients.run(restarts: {
                for round in 1...5 {
                    try await Task.sleep(for: .milliseconds(150))
                    let listener = ServerListener.byteStream(
                        try BSDSocketListener(configuration: .init(port: port, tcp: TCPConfiguration(allowLocalEndpointReuse: false))),
                        name: "http").restartable(address: address, identity: "http")
                    let addresses = try await server.restart(
                        listeners: [listener], protocols: [HTTP1(configuration: HTTP1Configuration(maxBodySize: 500 + round))])
                    #expect(addresses == [address])
                    // A connection made now runs the new limit.
                    #expect(try await RestartClient.status(of: RestartClient.post(1000), port: port) == 413)
                }
            })
            clients.expectNoFailures()

            // A third socket cannot take the port: sharing is off outside the swap.
            let rival = try BSDSocketListener(configuration: .init(port: port, tcp: TCPConfiguration(allowLocalEndpointReuse: false)))
            await #expect(throws: TransportError.self) { _ = try await rival.listen() }

            await server.shutdown()
            try await group.waitForAll()
        }
    }

    /// A restart that moves the port: the old port drains and closes, the new one serves.
    @Test(.timeLimit(.minutes(1)))
    func aMovedPortClosesTheOldOne() async throws {
        let server = Server(configuration: ServerConfiguration(drainTimeout: .seconds(2)),
                            listeners: [ServerListener.byteStream(try BSDSocketListener(), name: "http")],
                            protocols: [HTTP1()], handler: NoContentHandler())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            let old = try #require(try await server.waitUntilRunning().first?.port)
            let addresses = try await server.restart(listeners: [.byteStream(try BSDSocketListener(), name: "http")],
                                                     grace: .milliseconds(50))
            let new = try #require(addresses.first?.port)
            #expect(new != old)
            #expect(server.localAddresses.map(\.port) == [new])
            #expect(try await RestartClient.status(of: RestartClient.get, port: new) == 204)
            var refused = false
            for _ in 0..<100 where !refused {
                do {
                    let client = try await BSDSocketTransport.connect(host: "127.0.0.1", port: old)
                    await client.close(.normal)
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    refused = true
                }
            }
            #expect(refused, "the old port closes")
            await server.shutdown()
            try await group.waitForAll()
        }
    }

    /// The Network.framework TLS listener cannot share its port, so it is handed over: TLS
    /// clients in a loop see no refused connection across three restarts, and new
    /// connections run the new protocol configuration.
    @Test(.timeLimit(.minutes(2)))
    func tlsListenerIsHandedOverWithNoGap() async throws {
        let (identity, certificate) = try TLSIntegrationTests.identity()
        let store = TLSIdentityStore(identity)
        @Sendable func tls(port: UInt16) -> ServerListener {
            ServerListener.byteStream(name: "https") { bind in
                try TCPListener(configuration: .init(host: "127.0.0.1", port: port, tcp: TCPConfiguration(allowLocalEndpointReuse: false)),
                                tls: TLSConfiguration(identityStore: store, alpn: bind.alpnTokens))
            }.restartable(address: TransportAddress(host: "127.0.0.1", port: port), identity: "https")
        }
        let server = Server(configuration: ServerConfiguration(drainTimeout: .seconds(3)),
                            listeners: [tls(port: 0)], protocols: [HTTP1()], handler: NoContentHandler())
        try await withThrowingTaskGroup { group in
            group.addTask { try await server.run() }
            let port = try #require(try await server.waitUntilRunning().first?.port)
            let clients = RestartClient(port: port, tlsCertificate: certificate)
            try await clients.run(restarts: {
                for round in 1...3 {
                    try await Task.sleep(for: .milliseconds(200))
                    try await server.restart(listeners: [tls(port: port)],
                                             protocols: [HTTP1(configuration: HTTP1Configuration(maxBodySize: 500 + round))])
                    #expect(try await RestartClient.status(of: RestartClient.post(1000), port: port, tls: certificate) == 413)
                }
            })
            clients.expectNoFailures()
            await server.shutdown()
            try await group.waitForAll()
        }
    }
}

/// HTTP/1.1 clients that send requests in a loop while restarts run (#0144): one opens a new
/// connection per request, one keeps a connection alive. Counts what an HTTP client would
/// call a failure: a refused or failed connect, or a request that got a partial or no
/// response. A reused keep-alive connection that ends before any response byte is the
/// ordinary race with a server closing an idle connection (RFC 9112 §9.3.1 lets a client
/// retry): counted apart and retried on a new connection.
final class RestartClient: Sendable {
    struct Counts: Sendable {
        var requests = 0
        var connectFailures: [String] = []
        var requestFailures: [String] = []
        var staleRetries = 0
    }

    let port: UInt16
    let tlsCertificate: [UInt8]?
    let request: String
    let expectedStatus: Int
    let counts = Mutex(Counts())

    init(port: UInt16, tlsCertificate: [UInt8]? = nil, path: String = "/", expectedStatus: Int = 204) {
        self.port = port
        self.tlsCertificate = tlsCertificate
        request = "GET \(path) HTTP/1.1\r\nHost: x\r\n\r\n"
        self.expectedStatus = expectedStatus
    }

    static let get = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"

    static func post(_ length: Int) -> String {
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n" + String(repeating: "a", count: length)
    }

    static func connect(port: UInt16, tls certificate: [UInt8]?) async throws -> any ByteStreamTransport {
        if let certificate {
            return try await TCPTransport.connect(host: "127.0.0.1", port: port,
                                                  tls: TLSClientConfiguration(pinnedCertificate: certificate))
        }
        return try await BSDSocketTransport.connect(host: "127.0.0.1", port: port)
    }

    /// The status of `request` on a new connection.
    static func status(of request: String, port: UInt16, tls certificate: [UInt8]? = nil) async throws -> Int? {
        let transport = try await connect(port: port, tls: certificate)
        let response = try? await exchange(request, on: transport)
        await transport.close(.normal)
        return response?.status
    }

    struct Response {
        /// `nil` when the connection ended before any response byte.
        var status: Int?
        var closes = false
        var complete = false
    }

    /// Sends `request` and reads one response (head and `Content-Length` body).
    static func exchange(_ request: String, on transport: some ByteStreamTransport) async throws -> Response {
        var out = ByteBuffer()
        out.append(contentsOf: Array(request.utf8))
        try await transport.send(out, endOfStream: false)
        var received: [UInt8] = []
        var buffer = ByteBuffer(capacity: 4096)
        var response = Response()
        var bodyStart: Int?
        var length = 0
        while true {
            if bodyStart == nil, let end = headEnd(received) {
                let head = String(decoding: received[..<end], as: UTF8.self).lowercased()
                let words = head.split(separator: " ", maxSplits: 2)
                response.status = words.count > 1 ? Int(words[1]) : -1
                response.closes = head.contains("\r\nconnection: close")
                for line in head.split(separator: "\r\n") where line.hasPrefix("content-length:") {
                    length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                }
                bodyStart = end + 4
            }
            if let bodyStart, received.count - bodyStart >= length {
                response.complete = true
                return response
            }
            buffer.clear()
            let count: Int
            do {
                count = try await transport.receive(into: &buffer, maxLength: 4096)
            } catch {
                count = 0
            }
            if count == 0 {
                if response.status == nil && !received.isEmpty { response.status = -1 }
                return response
            }
            buffer.withUnsafeReadableBytes { received += $0 }
        }
    }

    static func headEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index
        }
        return nil
    }

    /// Runs both client loops until `restarts` returns, then checks they kept going.
    func run(restarts: @Sendable () async throws -> Void) async throws {
        let stop = ShutdownSignal()
        try await withThrowingTaskGroup { group in
            group.addTask { await self.newConnections(until: stop) }
            group.addTask { await self.keepAlive(until: stop) }
            do {
                try await restarts()
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                stop.trigger()
                throw error
            }
            stop.trigger()
            try await group.waitForAll()
        }
    }

    func expectNoFailures(sourceLocation: SourceLocation = #_sourceLocation) {
        let counts = counts.withLock { $0 }
        #expect(counts.connectFailures.isEmpty, "refused or failed connects: \(counts.connectFailures)", sourceLocation: sourceLocation)
        #expect(counts.requestFailures.isEmpty, "requests without a whole response: \(counts.requestFailures)", sourceLocation: sourceLocation)
        #expect(counts.requests > 20, "the clients kept sending: \(counts.requests)", sourceLocation: sourceLocation)
    }

    private func newConnections(until stop: ShutdownSignal) async {
        while !stop.isTriggered {
            // Paced: every connection leaves an ephemeral port in TIME_WAIT for 30 s, and a
            // tight loop would run out of them (EADDRNOTAVAIL) over a few test runs.
            try? await Task.sleep(for: .milliseconds(3))
            let transport: any ByteStreamTransport
            do {
                transport = try await Self.connect(port: port, tls: tlsCertificate)
            } catch {
                counts.withLock { $0.connectFailures.append("\(error)") }
                continue
            }
            let response = (try? await Self.exchange(request, on: transport)) ?? Response()
            await transport.close(.normal)
            counts.withLock { counts in
                counts.requests += 1
                if !response.complete || response.status != expectedStatus {
                    counts.requestFailures.append("new connection: \(response)")
                }
            }
        }
    }

    private func keepAlive(until stop: ShutdownSignal) async {
        var transport: (any ByteStreamTransport)?
        var used = false
        while !stop.isTriggered {
            if transport == nil {
                do {
                    transport = try await Self.connect(port: port, tls: tlsCertificate)
                    used = false
                } catch {
                    counts.withLock { $0.connectFailures.append("\(error)") }
                    continue
                }
            }
            guard let current = transport else { continue }
            let response = (try? await Self.exchange(request, on: current)) ?? Response()
            if response.status == nil && used {
                counts.withLock { $0.staleRetries += 1 }
                await current.close(.normal)
                transport = nil
                continue
            }
            counts.withLock { counts in
                counts.requests += 1
                if !response.complete || response.status != expectedStatus {
                    counts.requestFailures.append("keep-alive: \(response)")
                }
            }
            used = true
            if response.closes || !response.complete {
                await current.close(.normal)
                transport = nil
            }
        }
        if let transport { await transport.close(.normal) }
    }
}
