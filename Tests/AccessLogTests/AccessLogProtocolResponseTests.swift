import AccessLog
import HTTP1
import HTTPCore
import HTTPServer
import HTTPTestSupport
import Testing

// #0139: responses the HTTP/1.1 runner writes itself (a malformed head, a limit, a handler that
// threw) reach the access log through the server's protocol response observers.

/// Sends `text` on a new connection, reads until the server closes, returns the response text.
private func send(_ text: String, to listener: InMemoryListener) async throws -> String {
    let connection = await listener.connect()
    try await connection.send(ByteBuffer(bytes: Array(text.utf8)), endOfStream: true)
    var received = ByteBuffer()
    while try await connection.receive(into: &received, maxLength: 64 * 1024) > 0 {}
    await connection.close(.normal)
    return received.withReadableSpan { ASCII.string(from: $0) }
}

/// Runs a server with `log` in front of ``Responder``, sends each request on its own
/// connection, shuts down and returns the logged lines and the responses.
private func serve(_ requests: [String], log: AccessLog, capture: Capture,
                   configuration: HTTP1Configuration = HTTP1Configuration()) async throws -> (lines: [String], responses: [String]) {
    let listener = InMemoryListener(pendingLimit: 16)
    let server = Server(listeners: [listener], protocols: [HTTP1(configuration: configuration)]) {
        log
        Responder()
    }
    var responses: [String] = []
    try await withThrowingTaskGroup { group in
        group.addTask { try await server.run() }
        _ = try await server.waitUntilRunning()
        for request in requests { responses.append(try await send(request, to: listener)) }
        await server.shutdown()
        try await group.waitForAll()
    }
    return (capture.lines, responses)
}

@Suite(.timeLimit(.minutes(1)))
struct AccessLogProtocolResponseTests {
    @Test func malformedRequestIsLoggedWithADash() async throws {
        let capture = Capture()
        let log = AccessLog(format: .combined, destination: capture.destination)
        let (lines, responses) = try await serve(["GET /a HTTP/1.1\r\nHost: x\r\nBad Field: y\r\n\r\n"],
                                                 log: log, capture: capture)
        #expect(responses.first?.hasPrefix("HTTP/1.1 400 ") == true)
        #expect(lines.count == 1)
        #expect(lines.first?.hasSuffix(#"] "-" 400 - "-" "-""#) == true, "\(lines)")
    }

    @Test func throwingHandlerIsLoggedOnceAs500() async throws {
        let capture = Capture()
        let log = AccessLog(format: .common, destination: capture.destination)
        let (lines, responses) = try await serve(["GET /throw HTTP/1.1\r\nHost: x\r\n\r\n"], log: log, capture: capture)
        #expect(responses.first?.hasPrefix("HTTP/1.1 500 ") == true)
        #expect(lines.count == 1, "\(lines)")
        #expect(lines.first?.hasSuffix(#""GET /throw HTTP/1.1" 500 -"#) == true, "\(lines)")
    }

    @Test func limitBeforeTheHandlerIsLoggedWithTheRequest() async throws {
        let capture = Capture()
        let log = AccessLog(format: .json, destination: capture.destination)
        var configuration = HTTP1Configuration()
        configuration.maxBodySize = 10
        let (lines, responses) = try await serve(
            ["POST /upload?x=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n"],
            log: log, capture: capture, configuration: configuration)
        #expect(responses.first?.hasPrefix("HTTP/1.1 413 ") == true)
        #expect(lines.count == 1)
        let line = lines.first ?? ""
        #expect(line.contains(#""method":"POST","path":"/upload","query":"x=1","status":413,"bytes":0"#), "\(line)")
    }

    @Test func jsonLineWithoutARequest() async throws {
        let capture = Capture()
        let log = AccessLog(format: .json, destination: capture.destination)
        let (lines, _) = try await serve(["GET /a HTTP/9.9\r\nHost: x\r\n\r\n"], log: log, capture: capture)
        #expect(lines.count == 1)
        #expect(lines.first?.contains(#""method":"","path":"","query":"","status":505,"bytes":0,"duration_us":null,"referer":null,"user_agent":null}"#) == true,
                "\(lines)")
    }

    @Test func metricsCountTheRunnersResponses() async throws {
        let capture = Capture()
        let metrics = AccessLogMetrics()
        let log = AccessLog(format: .common, destination: capture.destination, metrics: metrics)
        _ = try await serve(["BAD\r\n\r\n", "GET /throw HTTP/1.1\r\nHost: x\r\n\r\n", "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"],
                            log: log, capture: capture)
        let snapshot = metrics.snapshot()
        #expect(snapshot.requests == 3)
        #expect(snapshot.responses(statusClass: 4) == 1)
        #expect(snapshot.responses(statusClass: 5) == 1)
        #expect(snapshot.responses(statusClass: 2) == 1)
    }
}
