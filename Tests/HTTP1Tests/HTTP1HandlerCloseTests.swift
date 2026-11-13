import Testing
import HTTPCore
import HTTPTestSupport
@testable import HTTP1

/// Answers `200` with the path as the body; the query, when present, is sent as the response's
/// `connection` field (`/x?close`, `/x?Keep-Alive,%20CLOSE` is not decoded, so tests use
/// plain tokens).
struct ConnectionFieldHandler: HTTPHandler {
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        var headers = HTTPFields()
        switch request.string(of: request.query) {
        case "close": headers.append(.connection, "close")
        case "list": headers.append(.connection, "x-trace, CLOSE")
        case "keep": headers.append(.connection, "keep-alive")
        default: break
        }
        return HTTPResponse(headers: headers, body: .bytes(buffer(request.string(of: request.path))))
    }
}

/// #0138: a handler's `connection: close` closes the HTTP/1.1 connection after its response.
@Suite struct HTTP1HandlerCloseTests {
    func serve(_ text: String) async -> (responses: [WireResponse], trailing: String, closed: Bool) {
        let base = InMemoryTransport.scripted([.bytes(buffer(text)), .endOfStream])
        await HTTP1().run(base, handler: ConnectionFieldHandler(), context: ConnectionContext(info: base.info))
        let parsed = parseResponses(base.sentBytes)
        return (parsed.responses, parsed.trailing, base.isClosed)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["close", "list"])
    func handlerCloseEndsTheConnectionAndDropsPipelinedRequests(_ query: String) async {
        let result = await serve(get("/a") + get("/b?\(query)") + get("/never") + get("/never2"))
        #expect(result.responses.map(\.body) == ["/a", "/b"])
        #expect(result.responses[0].header("connection") == "keep-alive")
        #expect(result.responses[1].header("connection") == "close")
        // One `connection` field: the handler's is not written next to the serializer's.
        #expect(result.responses[1].headers.filter { $0.0 == "connection" }.count == 1)
        #expect(result.responses[1].header("content-length") == "2")
        #expect(result.trailing.isEmpty)
        #expect(result.closed)
    }

    @Test(.timeLimit(.minutes(1)))
    func handlerKeepAliveDoesNotOverrideTheClientsClose() async {
        let result = await serve(get("/a?keep", "Connection: close\r\n") + get("/never"))
        #expect(result.responses.map(\.body) == ["/a"])
        #expect(result.responses[0].header("connection") == "close")
    }

    @Test(.timeLimit(.minutes(1)))
    func otherConnectionTokensKeepTheConnection() async {
        let result = await serve(get("/a?keep") + get("/b"))
        #expect(result.responses.map(\.body) == ["/a", "/b"])
        #expect(result.responses.allSatisfy { $0.header("connection") == "keep-alive" })
    }

    @Test func stateMachineDowngradesPersistence() {
        var connection = HTTP1Connection()
        #expect(connection.handle(.head(HTTP1Connection.RequestSummary())) == .callHandler)
        #expect(connection.handle(.closeRequested) == .proceed)
        #expect(connection.handle(.response(.delimited))
                == .writeResponse(HTTP1ResponseContext(requestMethod: .get, persistence: .close)))
        #expect(connection.handle(.responseWritten) == .close(.normal))
    }
}
