@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Testing

/// #0138: on HTTP/2 a handler's `connection: close` is a connection-specific field: it is
/// stripped (RFC 9113 §8.2.2) and changes nothing else; the connection carries on.
@Suite(.timeLimit(.minutes(1)))
struct H2ConnectionCloseFieldTests {
    @Test func handlerConnectionCloseIsStrippedAndTheConnectionCarriesOn() async throws {
        let handler = ClosureHandler { request in
            var headers = HTTPFields()
            headers.append(.connection, "close")
            return HTTPResponse(headers: headers, body: .bytes(ByteBuffer(bytes: Array(request.string(of: request.path).utf8))))
        }
        try await withH2Connection(handler: handler) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/one")))
            let first = try await client.response(on: 1)
            #expect(first.head.first?.1 == "200")
            #expect(!first.head.contains { $0.0 == "connection" })
            #expect(!first.others.contains { $0.isGoaway })
            try await client.send(F.headers(3, block: client.requests.get("/two")))
            let second = try await client.response(on: 3)
            #expect(String(decoding: second.body, as: UTF8.self) == "/two")
        }
    }
}
