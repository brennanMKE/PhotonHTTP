/// Why a protocol runner answered with a response of its own instead of the handler chain's
/// (#0139).
public enum ProtocolResponseCause: Sendable, Hashable {
    /// The request head could not be parsed or broke a limit (HTTP/1.1 `400`, `414`, `431`,
    /// `501`, `505`). There is no request.
    case malformedRequest
    /// The request head or body did not arrive in time (`408`). There may be no request.
    case requestTimeout
    /// The request was refused before the handler ran: a `Content-Length` over the limit
    /// (`413`), an unsupported expectation (`417`), a field section over a limit (HTTP/2 and
    /// HTTP/3).
    case rejectedBeforeHandler
    /// The handler threw because the request body failed: too large (`413`) or malformed or
    /// truncated (`400`).
    case requestBodyFailed
    /// The handler threw (`500`).
    case handlerFailed
    /// The handler's response could not be sent as is (`500`): a field that would split the
    /// head (#0136), or a `.tunnel` body with a status that cannot carry one.
    case invalidResponse
}

/// A chain element that sees the responses a protocol runner writes without the handler chain:
/// error pages style them, an access log records them (#0139).
///
/// Protocol runners answer some requests themselves (a malformed head, a limit, a timeout, a
/// handler that threw), so middleware never sees those responses. For each one the runner
/// calls, through ``ConnectionContext/protocolResponseObservers``,
///
/// 1. ``prepareProtocolResponse(_:cause:request:context:)`` on every observer in chain order,
///    with the status and an empty body: an observer may give it a body (an error page) or
///    fields. The runner keeps the status and its own framing.
/// 2. ``protocolResponseWritten(status:bodyBytes:cause:request:context:)`` on every observer once
///    the response is serialized (or queued on its stream).
///
/// `request` is `nil` when there is none (an unparsable head, a timeout before the head was
/// complete) or the runner no longer has it; when present it is valid only during the call.
/// `context` is the connection's request context, with ``RequestContext/startTime`` set when
/// the request reached the handler chain.
///
/// The server finds observers in the chain at startup, like ``ConnectionObserver``s; with none,
/// an error response costs one empty-array check. These are error paths: no cost per request.
public protocol ProtocolResponseObserver: Sendable {
    /// Lets the observer change the response before it is written. Default: nothing.
    func prepareProtocolResponse(_ response: inout HTTPResponse, cause: ProtocolResponseCause,
                                 request: HTTPRequest?, context: RequestContext)
    /// Tells the observer the response was written, with `bodyBytes` content bytes (`0` for
    /// `HEAD`). Default: nothing.
    func protocolResponseWritten(status: Int, bodyBytes: Int, cause: ProtocolResponseCause,
                                 request: HTTPRequest?, context: RequestContext)
}

extension ProtocolResponseObserver {
    public func prepareProtocolResponse(_ response: inout HTTPResponse, cause: ProtocolResponseCause,
                                        request: HTTPRequest?, context: RequestContext) {}

    public func protocolResponseWritten(status: Int, bodyBytes: Int, cause: ProtocolResponseCause,
                                        request: HTTPRequest?, context: RequestContext) {}
}

/// The ``ProtocolResponseObserver``s of a chain, found once at startup.
public struct ProtocolResponseObservers: Sendable {
    public let observers: [any ProtocolResponseObserver]

    public init(_ observers: [any ProtocolResponseObserver] = []) {
        self.observers = observers
    }

    /// The observers in `chain`, outermost first.
    public init(chain: Any) {
        var observers: [any ProtocolResponseObserver] = []
        MiddlewareChainInspector.visit(chain) {
            if let observer = $0 as? any ProtocolResponseObserver { observers.append(observer) }
        }
        self.init(observers)
    }

    @inlinable public var isEmpty: Bool { observers.isEmpty }

    /// Builds the response a runner writes itself: `status` with an empty body, then every
    /// observer's changes, in chain order. The status is kept whatever an observer does, and
    /// fields that fail ``HTTPFieldValidation`` discard the observers' changes.
    public func response(status: HTTPStatus, cause: ProtocolResponseCause, request: HTTPRequest?,
                         context: RequestContext) -> HTTPResponse {
        var response = HTTPResponse(status: status)
        for observer in observers {
            observer.prepareProtocolResponse(&response, cause: cause, request: request, context: context)
        }
        response.status = status
        // An observer's fields go through the same check as a handler's (#0136).
        if HTTPFieldValidation.validationError(response.headers) != nil { return HTTPResponse(status: status) }
        return response
    }

    /// Tells every observer a runner's own response was written.
    public func written(status: Int, bodyBytes: Int, cause: ProtocolResponseCause, request: HTTPRequest?,
                        context: RequestContext) {
        for observer in observers {
            observer.protocolResponseWritten(status: status, bodyBytes: bodyBytes, cause: cause,
                                             request: request, context: context)
        }
    }
}
