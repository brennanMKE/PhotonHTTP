public import HTTPCore

/// An access log and request metrics (#0090): one line per request in Common, Combined or
/// JSON-lines format, and per-connection counters merged into ``AccessLogMetrics``.
///
/// ```swift
/// let metrics = AccessLogMetrics()
/// let server = Server(listeners: [listener], protocols: [HTTP1()]) {
///     AccessLog(format: .combined, destination: .file(path: "/var/log/sws/access.log"), metrics: metrics)
///     MetricsEndpoint(metrics: metrics)          // GET /metrics, Prometheus text
///     StaticFiles(root: publicURL)
/// }
/// ```
///
/// It is the reference component for the registration model (docs/MIDDLEWARE.md): one value
/// in the builder chain that is at once
///
/// | Role | Protocol | What the server does with it |
/// |---|---|---|
/// | the middleware that records each request | ``HTTPMiddleware`` | calls it in chain order |
/// | the reader of the request's start time | ``RequestStartTimeConsumer`` | stamps every request (one clock read) |
/// | the owner of per-connection buffers and counters | ``ConnectionObserver`` | opens and closes them with each connection |
/// | the writer | ``ServerComponent`` | runs it beside the listeners, cancels it after the last connection |
///
/// Left out of the chain (or inside an `if` that was false) it costs nothing: no clock read,
/// no connection state, no writer task.
///
/// ## Cost on the request path
///
/// No I/O, no `String`, no allocation per request. The line is formatted straight into the
/// connection's buffer (escaped, see ``AccessLogLineFormatter``) under a lock only that
/// connection and the writer's periodic collection take; a full batch is handed to the writer
/// through a ``BoundedAsyncQueue`` with `trySend`, and if the writer has fallen behind the
/// batch is dropped and counted (``AccessLogStatistics/linesDropped``) rather than wait.
/// Metrics are relaxed atomic adds on the connection's own counters. Measured cost:
/// docs/benchmarks/M6-accesslog.md.
///
/// ## What is recorded
///
/// Peer address, time the response was ready (UTC, whole seconds), method, path and query,
/// protocol (from ALPN: `HTTP/1.1`, `HTTP/2.0`, `HTTP/3.0`), status, response body bytes,
/// duration (JSON and the latency histogram), and for Combined and JSON the `Referer` and
/// `User-Agent`. The line is recorded when the handler returns its response, so the duration
/// is the time to the response, not to the last body byte, and a stream without a declared
/// length logs `-` bytes.
///
/// ## Responses the protocol writes itself (#0139)
///
/// As a ``ProtocolResponseObserver`` it also logs the responses a protocol runner writes without
/// the handler chain, with the status and body bytes actually sent: a malformed head (`400`,
/// `414`, `431`, `501`, `505`), a limit hit before the handler ran (`413`, `417`, HTTP/2 and
/// HTTP/3 field-section limits), a header or body timeout (`408`), and a handler that threw
/// (`500`, or `413`/`400` when the request body failed). When the request line is unknown (an
/// unparsable head, a timeout) the line has `-` in its place, as Apache logs a bad request:
/// `127.0.0.1 - - [10/Oct/2026:13:55:36 +0000] "-" 400 -` (JSON: empty `method`, `path` and
/// `query`). A handler that throws is therefore logged by the runner, not by this middleware,
/// so the status is the one sent. A response the runner replaces because it cannot be sent
/// as is (#0136) keeps the line this middleware logged with the handler's status; the
/// replacement is reported in the `os` log.
///
/// One `AccessLog` per chain: two would share a context key and the inner one would fall back
/// to its shared (locked) buffer.
public struct AccessLog: HTTPMiddleware, RequestStartTimeConsumer, ConnectionObserver, ServerComponent,
    ProtocolResponseObserver {
    @usableFromInline let core: AccessLogCore

    /// A log of `format` lines written to `destination`, optionally also recording `metrics`.
    public init(format: AccessLogFormat = .common, destination: AccessLogDestination,
                metrics: AccessLogMetrics? = nil, options: AccessLogOptions = AccessLogOptions()) {
        core = AccessLogCore(format: format, destination: destination, metrics: metrics, options: options)
    }

    /// Metrics only: no lines, no writer.
    public init(metrics: AccessLogMetrics) {
        core = AccessLogCore(format: .common, destination: nil, metrics: metrics, options: AccessLogOptions())
    }

    /// Lines logged, written and dropped so far.
    public var statistics: AccessLogStatistics { core.statistics }

    /// Hands every buffered line to the writer now instead of at the next batch or
    /// ``AccessLogOptions/flushInterval``. Never waits; a full queue drops and counts.
    public func flush() {
        core.collect()
    }

    /// Reopens a ``AccessLogDestination/file(path:)`` destination by its path before the next
    /// write (#0127): after a log rotator renamed the file, the next lines go to a new file at
    /// the path. Lines written before stay in the renamed file. Never waits; other
    /// destinations ignore it. A path that can no longer be opened keeps the old file and
    /// counts a write error.
    public func reopen() {
        core.requestReopen()
    }

    // MARK: HTTPMiddleware

    @inlinable
    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        // A throw is not logged here: the protocol runner logs the response it sends instead
        // (``protocolResponseWritten(status:bodyBytes:cause:request:context:)``).
        let response = try await next.handle(request, context: context)
        core.record(request, context: context, status: response.status.code, responseBytes: response.body.knownLength)
        return response
    }

    // MARK: ProtocolResponseObserver

    public func protocolResponseWritten(status: Int, bodyBytes: Int, cause: ProtocolResponseCause,
                                        request: HTTPRequest?, context: RequestContext) {
        // This middleware already logged the handler's response for this request.
        if cause == .invalidResponse { return }
        core.recordProtocolResponse(status: status, bodyBytes: bodyBytes, request: request, context: context)
    }

    // MARK: ConnectionObserver

    public func connectionWillStart(_ connection: inout ConnectionContext) {
        connection.requestContext[AccessLogConnectionKey.self] = core.openConnection(connection.info)
    }

    public func connectionDidEnd(_ connection: ConnectionContext) {
        guard let state = connection.requestContext[AccessLogConnectionKey.self],
              state.settings === core.settings else { return }
        core.closeConnection(state)
    }

    // MARK: ServerComponent

    /// The writer. Runs until cancelled, then writes everything still buffered. Throws
    /// ``AccessLogError`` when the destination cannot be opened. Run it once at a time.
    public func run(server: ServerHandle) async throws {
        try await core.runWriter()
    }
}
