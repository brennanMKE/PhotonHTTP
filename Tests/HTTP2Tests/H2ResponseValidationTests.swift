@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Testing

/// #0136: a handler response with CR, LF or NUL in a field value (or a name that is not a
/// token) is never HPACK-encoded, in release builds too: the stream gets a bare `500`, and the
/// connection carries on.
@Suite(.timeLimit(.minutes(1)))
struct H2ResponseValidationTests {
    static let injecting = ClosureHandler { request in
        var headers = HTTPFields()
        switch request.string(of: request.path) {
        case "/crlf": headers.append(.location, string: "/next\r\nset-cookie: session=stolen")
        case "/nul": headers.append(name: "x-tag", value: "a\u{0}b")
        case "/name": headers.append(name: "x-a\r\nset-cookie", value: "stolen")
        default: headers.append(.location, string: "/next")
        }
        return HTTPResponse(status: .found, headers: headers, body: .bytes(ByteBuffer("moved")))
    }

    @Test(arguments: ["/crlf", "/nul", "/name"])
    func injectedFieldBecomes500(_ path: String) async throws {
        try await withH2Connection(handler: Self.injecting) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get(path)))
            let bad = try await client.response(on: 1)
            #expect(bad.head.first { $0.0 == ":status" }?.1 == "500")
            #expect(!bad.head.contains { $0.0 == "location" || $0.0 == "set-cookie" || $0.0 == "x-tag" }, "\(bad.head)")
            #expect(bad.body.isEmpty)
            // The connection carries on.
            try await client.send(F.headers(3, block: client.requests.get("/ok")))
            let good = try await client.response(on: 3)
            #expect(good.head.first { $0.0 == ":status" }?.1 == "302")
            #expect(good.head.first { $0.0 == "location" }?.1 == "/next")
        }
    }
}
