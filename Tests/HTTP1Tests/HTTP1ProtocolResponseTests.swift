import Synchronization
import Testing
import HTTPCore
import HTTPTestSupport
@testable import HTTP1

/// Styles every response the runner writes itself with a small body and records what it saw,
/// reading the request while it is valid.
final class RecordingObserver: ProtocolResponseObserver {
    struct Record: Equatable {
        var status: Int
        var bodyBytes: Int
        var cause: ProtocolResponseCause
        var target: String?
        var hasStartTime: Bool
    }

    let records = Mutex<[Record]>([])
    let prepared = Atomic<Int>(0)

    func prepareProtocolResponse(_ response: inout HTTPResponse, cause: ProtocolResponseCause,
                                 request: HTTPRequest?, context: RequestContext) {
        prepared.add(1, ordering: .relaxed)
        guard request?.method != .head else { return }
        response.headers.append(.contentType, "text/plain")
        response.body = .bytes(buffer("page \(response.status.code)"))
        // The runner keeps its status whatever an observer does.
        response.status = .ok
    }

    func protocolResponseWritten(status: Int, bodyBytes: Int, cause: ProtocolResponseCause,
                                 request: HTTPRequest?, context: RequestContext) {
        let target = request.map { $0.string(of: $0.path) + ($0.query.isEmpty ? "" : "?" + $0.string(of: $0.query)) }
        records.withLock {
            $0.append(Record(status: status, bodyBytes: bodyBytes, cause: cause, target: target,
                             hasStartTime: context.startTime != nil))
        }
    }

    var all: [Record] { records.withLock { $0 } }
}

/// Throws for `/throw`, reads the body for `/read`, returns a `1xx` tunnel for `/bad-tunnel`
/// and an injected field for `/inject`; otherwise `200`.
struct ObservedHandler: HTTPHandler {
    struct Failure: Error {}

    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        switch request.string(of: request.path) {
        case "/throw":
            throw Failure()
        case "/read":
            _ = try await request.body.collect(upTo: 1 << 20)
            return HTTPResponse()
        case "/bad-tunnel":
            return HTTPResponse(status: .continue, body: .tunnel { _, _ in })
        case "/inject":
            var headers = HTTPFields()
            headers.append(.location, string: "/a\r\nx: y")
            return HTTPResponse(status: .found, headers: headers)
        default:
            return HTTPResponse(body: .bytes(buffer("ok")))
        }
    }
}

/// #0139: every response HTTP/1.1 writes without the handler chain goes through the connection's
/// protocol response observers (error pages, access log).
@Suite(.timeLimit(.minutes(1)))
struct HTTP1ProtocolResponseTests {
    func serve(_ events: [InMemoryTransport.Event], configuration: HTTP1Configuration = HTTP1Configuration(),
               headResponses: Set<Int> = []) async -> (responses: [WireResponse], records: [RecordingObserver.Record]) {
        let observer = RecordingObserver()
        let base = InMemoryTransport.scripted(events)
        let context = ConnectionContext(info: base.info, recordsRequestStartTime: true,
                                        protocolResponseObservers: ProtocolResponseObservers([observer]))
        await HTTP1(configuration: configuration).run(base, handler: ObservedHandler(), context: context)
        return (parseResponses(base.sentBytes, headResponses: headResponses).responses, observer.all)
    }

    @Test func malformedHeadIsStyledAndRecordedWithoutARequest() async {
        let result = await serve([.bytes(buffer("GET / HTTP/1.1\r\nHost: x\r\nBad Field: y\r\n\r\n")), .endOfStream])
        #expect(result.responses.map(\.status) == [400])
        #expect(result.responses.first?.body == "page 400")
        #expect(result.responses.first?.header("content-type") == "text/plain")
        #expect(result.responses.first?.header("connection") == "close")
        #expect(result.records == [.init(status: 400, bodyBytes: 8, cause: .malformedRequest, target: nil, hasStartTime: false)])
    }

    @Test func throwingHandlerIsRecordedWithItsRequest() async {
        let result = await serve([.bytes(buffer(get("/ok") + get("/throw?q=1") + get("/never"))), .endOfStream])
        #expect(result.responses.map(\.status) == [200, 500])
        #expect(result.responses[1].body == "page 500")
        #expect(result.records == [.init(status: 500, bodyBytes: 8, cause: .handlerFailed, target: "/throw?q=1", hasStartTime: true)])
    }

    @Test func limitBeforeTheHandlerIsRecordedWithItsRequest() async {
        var configuration = HTTP1Configuration()
        configuration.maxBodySize = 4
        let result = await serve([.bytes(buffer("POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\n")), .endOfStream],
                                 configuration: configuration)
        #expect(result.responses.map(\.status) == [413])
        #expect(result.records == [.init(status: 413, bodyBytes: 8, cause: .rejectedBeforeHandler, target: "/up", hasStartTime: false)])
    }

    @Test func failedRequestBodyIsRecorded() async {
        var configuration = HTTP1Configuration()
        configuration.maxBodySize = 4
        let chunked = "POST /read HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n0123456789abcdef\r\n0\r\n\r\n"
        let result = await serve([.bytes(buffer(chunked)), .endOfStream], configuration: configuration)
        #expect(result.responses.map(\.status) == [413])
        #expect(result.records.map(\.cause) == [.requestBodyFailed])
        #expect(result.records.first?.target == "/read")
    }

    @Test func unsendableResponsesAreRecordedAsInvalid() async {
        for path in ["/inject", "/bad-tunnel"] {
            let result = await serve([.bytes(buffer(get(path))), .endOfStream])
            #expect(result.responses.map(\.status) == [500], "\(path)")
            #expect(result.records == [.init(status: 500, bodyBytes: 8, cause: .invalidResponse, target: path, hasStartTime: true)])
        }
    }

    @Test func headRequestGetsNoBodyBytes() async {
        let result = await serve([.bytes(buffer("HEAD /throw HTTP/1.1\r\nHost: x\r\n\r\n")), .endOfStream], headResponses: [0])
        #expect(result.responses.map(\.status) == [500])
        #expect(result.records.map(\.bodyBytes) == [0])
    }

    @Test func headerTimeoutIsStyledAndRecorded() async {
        let observer = RecordingObserver()
        let base = InMemoryTransport.scripted([.bytes(buffer("GET / HTTP/1.1\r\nHost: x\r\n")), .delay(.seconds(30))])
        let context = ConnectionContext(info: base.info, protocolResponseObservers: ProtocolResponseObservers([observer]))
        await HTTP1(configuration: fastTimeouts(header: .milliseconds(100))).run(base, handler: ObservedHandler(), context: context)
        let responses = parseResponses(base.sentBytes).responses
        #expect(responses.map(\.status) == [408])
        #expect(responses.first?.body == "page 408")
        #expect(observer.all == [.init(status: 408, bodyBytes: 8, cause: .requestTimeout, target: nil, hasStartTime: false)])
    }

    @Test func observersAreNotCalledForHandlerResponses() async {
        let observer = RecordingObserver()
        let base = InMemoryTransport.scripted([.bytes(buffer(get("/a") + get("/b"))), .endOfStream])
        let context = ConnectionContext(info: base.info, protocolResponseObservers: ProtocolResponseObservers([observer]))
        await HTTP1().run(base, handler: ObservedHandler(), context: context)
        #expect(observer.prepared.load(ordering: .relaxed) == 0)
        #expect(observer.all.isEmpty)
    }
}
