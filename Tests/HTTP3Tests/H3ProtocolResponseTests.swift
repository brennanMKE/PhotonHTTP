import HTTP3
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// Gives runner-written responses a body and records them (#0139).
final class H3RecordingObserver: ProtocolResponseObserver {
    let records = Mutex<[(Int, Int, ProtocolResponseCause, String?)]>([])

    func prepareProtocolResponse(_ response: inout HTTPResponse, cause: ProtocolResponseCause,
                                 request: HTTPRequest?, context: RequestContext) {
        response.body = .bytes(ByteBuffer(bytes: Array("page \(response.status.code)".utf8)))
    }

    func protocolResponseWritten(status: Int, bodyBytes: Int, cause: ProtocolResponseCause,
                                 request: HTTPRequest?, context: RequestContext) {
        let path = request.map { $0.string(of: $0.path) }
        records.withLock { $0.append((status, bodyBytes, cause, path)) }
    }
}

/// #0139: responses HTTP/3 writes instead of the handler's go through the connection's
/// protocol response observers.
@Suite(.timeLimit(.minutes(1)))
struct H3ProtocolResponseTests {
    @Test func throwingHandlerAndInvalidResponseAreStyledAndRecorded() async throws {
        let handler = ClosureHandler { request in
            switch request.string(of: request.path) {
            case "/throw":
                throw TestError()
            case "/inject":
                var headers = HTTPFields()
                headers.append(.location, string: "/a\r\nx: y")
                return HTTPResponse(status: .found, headers: headers)
            default:
                return HTTPResponse(body: .bytes(ByteBuffer(bytes: Array("ok".utf8))))
            }
        }
        let observer = H3RecordingObserver()
        let (thrown, injected, ok) = try await withH3Server(
            handler: handler, protocolResponseObservers: ProtocolResponseObservers([observer])
        ) { client, _ in
            let h3 = H3TestClient(transport: client)
            try await h3.openControlStream()
            let thrown = try await h3.send(H3Wire.request(path: "/throw"))
            let injected = try await h3.send(H3Wire.request(path: "/inject"))
            let ok = try await h3.send(H3Wire.request(path: "/ok"))
            return (thrown, injected, ok)
        }
        #expect(thrown.status == "500")
        #expect(thrown.bodyString == "page 500")
        #expect(injected.status == "500")
        #expect(ok.bodyString == "ok")
        let records = observer.records.withLock { $0 }
        #expect(records.map(\.0) == [500, 500])
        #expect(records.map(\.1) == [8, 8])
        #expect(records.map(\.2) == [.handlerFailed, .invalidResponse])
        #expect(records.map(\.3) == ["/throw", "/inject"])
    }
}
