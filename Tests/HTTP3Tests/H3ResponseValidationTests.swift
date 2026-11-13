import HTTP3
import HTTPCore
import HTTPTestSupport
import Testing

/// #0136: a handler response with CR, LF or NUL in a field value (or a name that is not a
/// token) is never QPACK-encoded, in release builds too: the stream gets a bare `500`.
@Suite(.timeLimit(.minutes(1)))
struct H3ResponseValidationTests {
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
        let (bad, good) = try await withH3Server(handler: Self.injecting) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openControlStream()
            let bad = try await h3.send(H3Wire.request(path: path))
            let good = try await h3.send(H3Wire.request(path: "/ok"))
            return (bad, good)
        }
        #expect(bad.status == "500")
        #expect(bad.header("location") == nil && bad.header("set-cookie") == nil && bad.header("x-tag") == nil)
        #expect(bad.body.isEmpty && bad.finished)
        #expect(good.status == "302")
        #expect(good.header("location") == "/next")
    }
}
