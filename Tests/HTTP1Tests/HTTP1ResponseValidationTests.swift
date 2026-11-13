import Testing
import HTTPCore
import HTTPTestSupport
@testable import HTTP1

/// Copies the request's query into a response field, as a handler that echoes decoded request
/// bytes might. `?crlf` puts CR LF in a value, `?name` in a field name, `?nul` a NUL byte.
struct InjectingHandler: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        var headers = HTTPFields()
        switch request.string(of: request.query) {
        case "crlf":
            headers.append(.location, string: "/next\r\nSet-Cookie: session=stolen")
        case "name":
            headers.append(name: "X-A\r\nSet-Cookie", value: "session=stolen")
        case "nul":
            headers.append(name: "X-Tag", value: "a\u{0}b")
        case "split":
            headers.append(.location, string: "/x\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        default:
            headers.append(.location, string: "/next")
        }
        return HTTPResponse(status: .found, headers: headers, body: .bytes(ByteBuffer("moved")))
    }
}

/// #0136: a response whose fields would split the head is never written, whatever the build
/// configuration: the runner answers `500` with `connection: close` instead.
@Suite struct HTTP1ResponseValidationTests {
    func serve(_ text: String) async -> (responses: [WireResponse], trailing: String, closed: Bool) {
        let base = InMemoryTransport.scripted([.bytes(buffer(text)), .endOfStream])
        await HTTP1().run(base, handler: InjectingHandler(), context: ConnectionContext(info: base.info))
        let parsed = parseResponses(base.sentBytes)
        return (parsed.responses, parsed.trailing, base.isClosed)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["crlf", "name", "nul", "split"])
    func injectedFieldBecomes500AndClose(_ query: String) async {
        let result = await serve(get("/ok") + get("/r?\(query)") + get("/never"))
        #expect(result.responses.map(\.status) == [302, 500])
        #expect(result.responses[0].header("location") == "/next")
        #expect(result.responses[1].header("connection") == "close")
        #expect(result.responses[1].header("content-length") == "0")
        #expect(result.responses[1].header("location") == nil)
        #expect(result.responses.allSatisfy { $0.header("set-cookie") == nil })
        #expect(result.trailing.isEmpty)
        #expect(result.closed)
    }

    @Test func invalidTrailersAreNotWritten() {
        var trailers = HTTPFields()
        trailers.append(name: "X-Checksum", value: "abc\r\nSet-Cookie: x")
        var out = ByteBuffer()
        HTTP1ChunkedEncoder.appendLastChunk(trailers: trailers, into: &out)
        #expect(out == ByteBuffer("0\r\n\r\n"))
    }
}
