import HTTPCore
import HTTPTestSupport
@testable import NetworkTransport
import Testing

/// Replacing the identity of running TLS and QUIC listeners (#0140): new handshakes present
/// the new certificate, connections opened before keep working, nothing is rebound. Two test
/// identities from `scripts/make-test-identity.sh` (the default and `--name second`), imported
/// in memory only; clients pin the certificate they expect, so no keychain or trust settings
/// are involved (AGENTS.md). Loopback, port 0.
@Suite struct TLSIdentityReloadTests {
    static func identities() throws -> (first: (TLSIdentity, [UInt8]), second: (TLSIdentity, [UInt8])) {
        let first = try TestIdentity.load()
        let second = try TestIdentity.load(name: "second")
        #expect(first.certificateDER != second.certificateDER)
        return ((try TLSIdentity(pkcs12: first.pkcs12, password: TestIdentity.password), first.certificateDER),
                (try TLSIdentity(pkcs12: second.pkcs12, password: TestIdentity.password), second.certificateDER))
    }

    @Test func storeReplacesTheIdentity() throws {
        let (first, second) = try Self.identities()
        let store = TLSIdentityStore(first.0)
        var tls = TLSConfiguration(identityStore: store)
        #expect(tls.identity.certificateDER == first.1)
        store.replace(with: second.0)
        #expect(tls.identity.certificateDER == second.1)
        // Setting `identity` detaches this configuration from the shared store.
        tls.identity = first.0
        #expect(store.identity.certificateDER == second.1)
        #expect(tls.identity.certificateDER == first.1)
    }

    @Test(.timeLimit(.minutes(1)))
    func tcpListenerPresentsTheReplacedIdentityToNewHandshakes() async throws {
        let (first, second) = try Self.identities()
        let store = TLSIdentityStore(first.0)
        let listener = try TCPListener(configuration: .init(host: "127.0.0.1", port: 0), tls: TLSConfiguration(identityStore: store))
        try await listener.start()
        defer { Task { await listener.close() } }
        var connections = listener.connections.makeAsyncIterator()

        func connect(pinning certificate: [UInt8]) async throws -> TCPTransport {
            try await TCPTransport.connect(host: "127.0.0.1", port: listener.port,
                                           tls: TLSClientConfiguration(pinnedCertificate: certificate))
        }

        let oldClient = try await connect(pinning: first.1)
        let oldServer = try #require(try await connections.next())

        store.replace(with: second.0)

        // A client that still expects the old certificate is refused: the new one is presented.
        await #expect(throws: (any Error).self) { _ = try await connect(pinning: first.1) }
        let newClient = try await connect(pinning: second.1)
        let newServer = try #require(try await connections.next())
        try await newClient.send(ByteBuffer("new"), endOfStream: false)
        #expect(try await receive(newServer, exactly: 3).bytes == Array("new".utf8))

        // The connection made before the swap is still open and working.
        try await oldClient.send(ByteBuffer("old"), endOfStream: false)
        #expect(try await receive(oldServer, exactly: 3).bytes == Array("old".utf8))
        try await oldServer.send(ByteBuffer("ok"), endOfStream: false)
        #expect(try await receive(oldClient, exactly: 2).bytes == Array("ok".utf8))

        for transport in [oldClient, oldServer, newClient, newServer] { await transport.close(.normal) }
    }

    @Test(.timeLimit(.minutes(1)))
    func quicListenerPresentsTheReplacedIdentityToNewHandshakes() async throws {
        let (first, second) = try Self.identities()
        let store = TLSIdentityStore(first.0)
        let quic = testQUICConfiguration()
        let listener = try QUICListener(configuration: .init(host: "127.0.0.1", port: 0, quic: quic), identityStore: store)
        try await listener.start()
        var connections = listener.connections.makeAsyncIterator()

        func connect(pinning certificate: [UInt8]) async throws -> QUICConnection {
            try await QUICConnection.connect(
                host: "127.0.0.1", port: listener.port,
                configuration: .init(quic: quic, peerVerification: .pinnedCertificate(certificate), connectTimeout: .seconds(3)))
        }

        let oldClient = try await connect(pinning: first.1)
        let oldServer = try #require(try await connections.next())

        store.replace(with: second.0)

        await #expect(throws: (any Error).self) { _ = try await connect(pinning: first.1) }
        let newClient = try await connect(pinning: second.1)
        let newServer = try #require(try await connections.next())
        let newStream = try await newClient.openBidirectionalStream()
        try await newStream.send(ByteBuffer("new"), endOfStream: true)
        let newInbound = try await acceptStream(newServer)
        #expect(try await receiveAll(newInbound).bytes == Array("new".utf8))

        // The connection made before the swap still opens streams.
        let oldStream = try await oldClient.openBidirectionalStream()
        try await oldStream.send(ByteBuffer("old"), endOfStream: true)
        let oldInbound = try await acceptStream(oldServer)
        #expect(try await receiveAll(oldInbound).bytes == Array("old".utf8))

        await oldClient.close(applicationError: 0)
        await newClient.close(applicationError: 0)
        await listener.close()
    }
}
