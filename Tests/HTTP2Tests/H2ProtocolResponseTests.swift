@testable import HTTP2
import HTTPCore
import HTTPTestSupport
import Synchronization
import Testing

/// Gives runner-written responses a body and records them (#0139).
final class H2RecordingObserver: ProtocolResponseObserver {
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

/// #0139: responses HTTP/2 writes instead of the handler's go through the connection's
/// protocol response observers.
@Suite(.timeLimit(.minutes(1)))
struct H2ProtocolResponseTests {
    @Test func throwingHandlerAndInvalidResponseAreStyledAndRecorded() async throws {
        struct Failure: Error {}
        let handler = ClosureHandler { request in
            switch request.string(of: request.path) {
            case "/throw":
                throw Failure()
            case "/inject":
                var headers = HTTPFields()
                headers.append(.location, string: "/a\r\nx: y")
                return HTTPResponse(status: .found, headers: headers)
            default:
                return HTTPResponse(body: .bytes(ByteBuffer(bytes: Array("ok".utf8))))
            }
        }
        let observer = H2RecordingObserver()
        try await withH2Connection(handler: handler, protocolResponseObservers: ProtocolResponseObservers([observer])) { client in
            try await client.handshake()
            try await client.send(F.headers(1, block: client.requests.get("/throw")))
            let thrown = try await client.response(on: 1)
            #expect(thrown.head.first?.1 == "500")
            #expect(String(decoding: thrown.body, as: UTF8.self) == "page 500")
            try await client.send(F.headers(3, block: client.requests.get("/inject")))
            let injected = try await client.response(on: 3)
            #expect(injected.head.first?.1 == "500")
            try await client.send(F.headers(5, block: client.requests.get("/ok")))
            #expect(String(decoding: try await client.response(on: 5).body, as: UTF8.self) == "ok")
        }
        let records = observer.records.withLock { $0 }
        #expect(records.map(\.0) == [500, 500])
        #expect(records.map(\.1) == [8, 8])
        #expect(records.map(\.2) == [.handlerFailed, .invalidResponse])
        #expect(records.map(\.3) == ["/throw", "/inject"])
    }
}
